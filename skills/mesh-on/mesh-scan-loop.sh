#!/usr/bin/env bash
# mesh-scan-loop.sh — read-only mesh poll loop. The Claude poller parks on this
# script as ONE SYNCHRONOUS Bash call and acts on its exit. It exits when there
# is real work (or a stop/layout signal), or with IDLE at MAX_WAIT_SEC so the
# call always returns before the harness's hard tool timeout — the poller
# re-launches immediately on IDLE (a token-trivial re-park, no commits). Never
# launch it as a background call: a background child is not guaranteed to
# survive the poller ending its turn, which orphans the node. Does NO gated
# git — add/commit/push stay inside Claude; the read-only pull/submodule-update
# here were never gated, so a variable REPO path is fine (the literal-path rule
# only guards the gate).
#
# Usage: mesh-scan-loop.sh <REPO> <ROLES_CSV> <AGENT_ID> [POLL_SEC] [MAX_WAIT_SEC]
#        MAX_WAIT_SEC defaults to $MESH_MAX_WAIT_SEC, else 540 (9 min — safely
#        under the 10-min Bash tool ceiling). 0 disables the IDLE deadline.
# Exit:  0 + "WORK\n<file>\n..."        -> claimable tasks and/or fresh replies
#        2 + "STOP"                     -> ~/.mesh-stop present
#        3 + "UPGRADE\n<bus> <prod>"    -> BUS_LAYOUT < product LAYOUT_VERSION
#        4 + "STALE_PRODUCT\n<bus> <prod>" -> BUS_LAYOUT > product LAYOUT_VERSION
#        5 + "IDLE"                     -> no work within MAX_WAIT_SEC; re-park
#
# Pin mode (default): the submodule update realizes the recorded product pin.
# Developer mode (MESH_PRODUCT_TRACK=tip): it adds --remote to track product tip.
#
# Portable across macOS and Linux: verified under bash 3.2 (macOS default) as
# well as bash 4/5, and uses only POSIX-safe sed/grep/git/sleep (BSD and GNU
# userland alike). No `timeout` dependency (absent on macOS). No bashisms newer
# than 3.2.
set -uo pipefail

REPO="${1:?repo path}"; ROLES="${2:?roles csv}"; AGENT_ID="${3:?agent id}"
POLL="${4:-240}"
MAX_WAIT="${5:-${MESH_MAX_WAIT_SEC:-540}}"
SEEN="${MESH_SEEN_FILE:-$HOME/.mesh-seen-replies}"
touch "$SEEN" 2>/dev/null || true

# IDLE deadline bookkeeping (bash 3.2-safe; SECONDS is builtin). MAX_WAIT=0
# disables the deadline (old block-forever behavior, for non-harness callers).
SECONDS=0

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

  # read-only, ungated; failures are transient -> keep looping
  git -C "$REPO" pull --rebase --quiet 2>/dev/null || true
  # pin mode by default; --remote only in developer mode (MESH_PRODUCT_TRACK=tip)
  if [ "${MESH_PRODUCT_TRACK:-}" = tip ]; then
    git -C "$REPO" submodule update --init --remote --recursive --quiet \
      2>/dev/null || true
  else
    git -C "$REPO" submodule update --init --recursive --quiet 2>/dev/null || true
  fi

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
      [ -e "$f" ] && claimable "$f" && hits+=("$f")
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

  if [ "${#hits[@]}" -gt 0 ]; then
    printf 'WORK\n'; printf '%s\n' "${hits[@]}"; exit 0
  fi

  # IDLE deadline: return before the harness tool timeout so the poller can
  # re-park. Checked before sleeping so we never overshoot by a full POLL.
  if [ "$MAX_WAIT" -gt 0 ] 2>/dev/null && \
     [ $(( SECONDS + POLL )) -ge "$MAX_WAIT" ]; then
    echo IDLE; exit 5
  fi
  sleep "$POLL"
done
