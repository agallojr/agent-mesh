#!/usr/bin/env bash
# mesh-scan-loop.sh — mesh poll loop, read-only but for its last_poll heartbeat
# (below). The Claude poller parks on this
# script as ONE SYNCHRONOUS Bash call and acts on its exit. It exits when there
# is real work (or a stop/layout signal), or with IDLE at MAX_WAIT_SEC — the
# poller re-launches immediately on IDLE (a token-trivial re-park).
# The deadline sits under the 5-min prompt-cache TTL, so each re-park reads the
# poller's context from cache; a longer park lets the cache expire and the
# re-park re-writes the whole context at the cache-write price. Never
# launch it as a background call: a background child is not guaranteed to
# survive the poller ending its turn, which orphans the node.
#
# Heartbeat (PROTOCOL 4.3): each scan iteration rewrites last_poll (UTC, to
# the second) in the node's own agents/<AGENT_ID>.yaml and pushes it through
# mesh-commit.sh, in a commit that holds only that file, so a node whose
# poller has stopped shows an old last_poll (mesh-check's mesh-stale.sh). A
# scan within half a poll interval of the last heartbeat writes none, so a
# re-park does not double it. A failed push neither stops nor delays the
# scan: the next nap is cut by the time the heartbeat took. Nothing here runs
# after the scanner exits, so nothing writes last_poll once the poller stops.
# A node with no agents/<AGENT_ID>.yaml gets no heartbeat. These heartbeats
# are the scanner's only git writes; mesh-commit.sh applies the git gate's
# rules to them itself. The pull and submodule updates stay read-only and
# ungated; a gitlink staged in the index is lifted out around the pull, so
# the rebase of an unpushed heartbeat cannot record it as a pin.
#
# Usage: mesh-scan-loop.sh <REPO> <ROLES_CSV> <AGENT_ID> [POLL_SEC] [MAX_WAIT_SEC]
#        MAX_WAIT_SEC defaults to $MESH_MAX_WAIT_SEC, else 240 (4 min). A call
#        lasts at most MAX_WAIT_SEC plus one pull and scan, which must stay under
#        the 5-min cache TTL. Sleeps are cut to the time left, so any POLL_SEC
#        works. 0 disables the IDLE deadline.
#        MESH_SCAN_LIST=1 mesh-scan-loop.sh <REPO> prints the submodule paths a
#        cycle would update, one per line, and exits 0 before any pull or write.
# Exit:  0 + "WORK\n<file>\n..."        -> claimable tasks, fresh replies, and/or
#                                          undrained library.submits (librarian)
#        2 + "STOP"                     -> ~/.mesh-stop present
#        3 + "UPGRADE\n<bus> <prod>"    -> BUS_LAYOUT < product LAYOUT_VERSION
#        4 + "STALE_PRODUCT\n<bus> <prod>" -> BUS_LAYOUT > product LAYOUT_VERSION
#        5 + "IDLE"                     -> no work within MAX_WAIT_SEC; re-park
#
# Submodules are read from .gitmodules. Each one not under spaces/ is updated
# as before. Pin mode (default): the update realizes the recorded pin.
# Developer mode (MESH_PRODUCT_TRACK=tip): it adds --remote to track the tip.
# A memory space (spaces/*, product/spec/memory-spaces.md §4.2) is updated only
# once this node has initialized it (<path>/.git exists), always with
# --remote --merge so it follows the space's branch tip. The scanner never
# initializes a space: mesh-load or the poller clones it on first need.
#
# Portable across macOS and Linux: verified under bash 3.2 (macOS default) as
# well as bash 4/5, and uses only POSIX-safe sed/grep/git/sleep (BSD and GNU
# userland alike). No `timeout` dependency (absent on macOS). No bashisms newer
# than 3.2.
set -uo pipefail

REPO="${1:?repo path}"
SCAN_DIR=$(cd "$(dirname "$0")" && pwd)

update_paths() {  # submodule paths a cycle updates, one per line, file order
  git config -f "$REPO/.gitmodules" --get-regexp '^submodule\..*\.path$' \
    2>/dev/null | while read -r _ p; do
      case "$p" in
        spaces/*) [ -e "$REPO/$p/.git" ] || continue ;;  # not yet cloned here
      esac
      printf '%s\n' "$p"
    done
}

# List mode: report the update set and stop, before any pull or file write.
if [ "${MESH_SCAN_LIST:-}" = 1 ]; then
  update_paths
  exit 0
fi

ROLES="${2:?roles csv}"; AGENT_ID="${3:?agent id}"
POLL="${4:-240}"
MAX_WAIT="${5:-${MESH_MAX_WAIT_SEC:-240}}"
# Wake-once ledger: one path per line for edge-triggered items that never get a
# status file (replies to our queries, and library.submits we must drain). Kept
# the historical filename for continuity. Purely a dedupe set of paths.
SEEN="${MESH_SEEN_FILE:-$HOME/.mesh-seen-replies}"
touch "$SEEN" 2>/dev/null || true

# IDLE deadline bookkeeping (bash 3.2-safe; SECONDS is builtin). MAX_WAIT=0
# disables the deadline (old block-forever behavior, for non-harness callers).
SECONDS=0

# mesh-commit.sh's functions (sourcing runs nothing): the gitlink lift
# and the heartbeat (mc_heartbeat, with REPO, AGENT_ID and POLL set).
. "$SCAN_DIR/mesh-commit.sh"
MC_PARENT=$PPID  # a heartbeat is never written once this caller is orphaned
MC_HEARTBEAT_PUSHES=1  # one push per heartbeat: the next scan's pull carries it

fm() {  # fm <key> <file> -> first frontmatter value for key
  sed -n "s/^$1:[[:space:]]*//p" "$2" | head -1
}

claimable() {  # exit 0 iff task file is claimable now (actionable + no status)
  local f="$1" id type
  id=$(fm id "$f"); [ -n "$id" ] || return 1
  type=$(fm type "$f")
  case "$type" in task.request|task.cancel|query) ;; *) return 1 ;; esac
  [ ! -f "$REPO/status/$id.json" ]
}

while :; do
  [ -f "$HOME/.mesh-stop" ] && { echo STOP; exit 2; }
  iter_start=$SECONDS

  # read-only, ungated; failures are transient -> keep looping. A staged
  # gitlink is lifted out around the pull and put back (mesh-commit.sh). A
  # rebase this pull starts and that stops on a conflict is aborted, so the
  # checkout is never left mid-rebase; the local commit stays as it was. A
  # rebase or merge already in progress (by hand, say) is left alone: no pull.
  if ! mc_in_progress; then
    mc_lift_gitlinks
    git -C "$REPO" pull --rebase --quiet >/dev/null 2>&1 || \
      git -C "$REPO" rebase --abort >/dev/null 2>&1 || true
    mc_restore_gitlinks
  fi
  # One submodule per call, so one bad path never blocks the rest. stdin is
  # /dev/null so git cannot read the path list the loop is iterating.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      spaces/*)  # initialized space: follow its branch tip, keep local commits
        git -C "$REPO" submodule update --remote --merge --quiet -- "$p" \
          </dev/null 2>/dev/null || true ;;
      *)  # pin mode by default; --remote only when MESH_PRODUCT_TRACK=tip
        if [ "${MESH_PRODUCT_TRACK:-}" = tip ]; then
          git -C "$REPO" submodule update --init --remote --recursive --quiet \
            -- "$p" </dev/null 2>/dev/null || true
        else
          git -C "$REPO" submodule update --init --recursive --quiet -- "$p" \
            </dev/null 2>/dev/null || true
        fi ;;
    esac
  done <<EOF
$(update_paths)
EOF

  # layout check: bus stamp vs product's expected layout (unstamped -> 0)
  BUS=$(cat "$REPO/BUS_LAYOUT" 2>/dev/null || echo 0)
  PROD=$(cat "$REPO/product/spec/LAYOUT_VERSION" 2>/dev/null || echo 0)
  if [ "$BUS" -lt "$PROD" ] 2>/dev/null; then
    printf 'UPGRADE\n%s %s\n' "$BUS" "$PROD"; exit 3
  fi
  if [ "$BUS" -gt "$PROD" ] 2>/dev/null; then
    printf 'STALE_PRODUCT\n%s %s\n' "$BUS" "$PROD"; exit 4
  fi

  hits=()
  IFS=',' read -ra RS <<< "$ROLES"
  for r in "${RS[@]}"; do
    for f in "$REPO/tasks/roles/$r"/*.md; do
      [ -e "$f" ] || continue
      if claimable "$f"; then
        hits+=("$f")
      elif [ "$(fm type "$f")" = library.submit ] && ! grep -qxF "$f" "$SEEN"; then
        # A library.submit is not claimable (never gets a status file) but the
        # librarian must drain it. Wake the poller ONCE per submit — the drain
        # does not delete the queue file (the archiver sweeps it), so an
        # unguarded wake would re-fire every cycle. Same seen-once guard as
        # replies. Only a librarian-holding node scans tasks/roles/librarian/,
        # so this wake is naturally scoped to the node that can drain it.
        hits+=("$f"); printf '%s\n' "$f" >> "$SEEN"   # wake once per submit
      fi
    done
  done
  for f in "$REPO/tasks/$AGENT_ID"/*.md; do
    [ -e "$f" ] || continue
    if claimable "$f"; then
      hits+=("$f")
    elif [ "$(fm type "$f")" = reply ] && ! grep -qxF "$f" "$SEEN"; then
      hits+=("$f"); printf '%s\n' "$f" >> "$SEEN"   # wake once per reply
    fi
  done

  # The scan is done: record it (the heartbeat), then act on what it found.
  # An orphaned scanner (its caller gone) writes none and ends.
  mc_heartbeat || { [ $? -eq 3 ] && { echo IDLE; exit 5; }; }

  if [ "${#hits[@]}" -gt 0 ]; then
    printf 'WORK\n'; printf '%s\n' "${hits[@]}"; exit 0
  fi

  # IDLE deadline: return before the cache TTL so the poller re-parks on a
  # cache read. The last sleep is cut to the time left, then one final scan
  # runs, so a POLL at or above MAX_WAIT still sleeps before IDLE instead of
  # returning at once and making the poller re-park every few seconds. The
  # nap is also cut by the time this iteration took, so a slow heartbeat
  # push does not delay the next scan.
  nap=$(( POLL - (SECONDS - iter_start) ))
  if [ "$MAX_WAIT" -gt 0 ] 2>/dev/null; then
    left=$(( MAX_WAIT - SECONDS ))
    [ "$left" -gt 0 ] || { echo IDLE; exit 5; }
    [ "$left" -lt "$nap" ] && nap="$left"
  fi
  [ "$nap" -gt 0 ] 2>/dev/null && sleep "$nap"
done
