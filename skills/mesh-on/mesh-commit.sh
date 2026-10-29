#!/usr/bin/env bash
# mesh-commit.sh -- the one way mesh tooling commits to the bus. It stages
# exactly the paths it is given, commits only them, never records a submodule
# pin, and pushes. Anything else modified or staged in the checkout, a
# submodule among them, stays out of the commit and stays as it was.
#
# Usage: mesh-commit.sh <REPO> <message> <path> [<path> ...]
#   <REPO>     literal absolute path of the repo (the bus), its work tree top
#   <message>  one line of plain text
#   <path>     relative to <REPO>; may name a deleted file, or a folder (such
#              as a result's <id>-files/), which stands for the files in it
#
# Output, one line each on stdout, and exit status:
#   COMMITTED <sha7> then PUSHED        0
#   NOTHING TO COMMIT                   0
#   REFUSED <reason>                    1  nothing committed, index as it was
#   COMMITTED <sha7> then PUSH FAILED   3  the commit stays local; the next
#                                          push from this checkout carries it
#   a usage line on stderr              2
#
# It refuses when no path is given; a path is absolute, holds a `..` or
# `.git` segment, or leaves <REPO> (through a link, say); a path is, holds or
# lies inside a submodule (a gitlink, git mode 160000, a `path` in
# .gitmodules, or a nested repo); a path names nothing present or tracked; or
# the git gate would deny the add, commit or push.
#
# The git gate (hooks/git-gate.py) is a PreToolUse hook: it reads the command
# an agent types and never sees the git this script runs. So the script asks
# the gate itself, with the add, commit and push it is about to run, naming
# every file the commit will hold, and fails closed: no gate, no python3, no
# allowlist, a repo off the allowlist, a blob-class file, or a path with a
# character the gate cannot check means REFUSED. Routing a commit through this
# script never loosens the gate. The gate used is the installed one
# (<config dir>/hooks/git-gate.py, the config dir resolved as the gate
# resolves it), else ~/.claude/hooks/git-gate.py, else the product's own
# hooks/git-gate.py beside this skill.
#
# After the commit it checks the commit's changed paths, gitlinks included
# (ignore = all hides them from the default view): if any is not a named path
# or is a gitlink, it undoes the commit, restores the index it saved, and
# refuses. It pushes `origin HEAD`; on a rejected push it runs
# `pull --rebase --autostash` and pushes again, 3 pushes at most. A gitlink
# staged in the index is lifted out of the index for the rebase and put back
# after it: under ignore = all, git does not see it as a local change, and the
# rebase would write it into the rebased commit. It never pushes while a
# commit not yet on origin changes a gitlink, whoever made it: it prints
# PUSH FAILED, says why on stderr, and the operator settles that commit.
#
# Sourcing this file defines its functions without running it (unit tests).
# Portable: bash 3.2+, POSIX sed/awk, git, python3 (stdlib) for the gate.
set -u

MC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MC_TMP=""
MC_SAVED_INDEX=""
MC_HAD_INDEX=0
NAMED=""
REPO="${REPO:-}"

# The gate is asked about one compound command. Paths are quoted with
# shlex.quote, as an agent would quote them; the gate splits on && first.
MC_GATE_PY='
import json, shlex, subprocess, sys
gate, repo, verbs, paths = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
q = shlex.quote
cmds = []
for v in verbs.split(","):
    if v == "add":
        cmds.append(" ".join(["git", "-C", q(repo), "add", "--"] + [q(p) for p in paths]))
    elif v == "commit":
        cmds.append(" ".join(["git", "-C", q(repo), "commit", "-m", "mesh-commit"]))
    elif v == "push":
        cmds.append(" ".join(["git", "-C", q(repo), "push", "origin", "HEAD"]))
payload = json.dumps({"tool_name": "Bash", "cwd": repo,
                      "tool_input": {"command": " && ".join(cmds)}})
try:
    r = subprocess.run([sys.executable, gate], input=payload,
                       capture_output=True, text=True, timeout=60)
except Exception as exc:
    print("the git gate could not run: " + type(exc).__name__)
    sys.exit(1)
out = r.stdout.strip()
if r.returncode != 0:
    print("the git gate exited " + str(r.returncode))
    sys.exit(1)
if not out:
    sys.exit(0)
try:
    hso = json.loads(out)["hookSpecificOutput"]
    decision = hso.get("permissionDecision")
    reason = hso.get("permissionDecisionReason") or "denied"
except Exception:
    print("the git gate gave an answer that could not be read")
    sys.exit(1)
if decision == "allow":
    sys.exit(0)
print(" ".join(str(reason).split()))
sys.exit(1)
'

mc_git() { git -C "$REPO" "$@"; }

mc_index_path() {  # absolute path of the repo's index file
  local p
  p=$(mc_git rev-parse --git-path index) || return 1
  case "$p" in /*) ;; *) p="$REPO/$p" ;; esac
  printf '%s\n' "$p"
}

mc_save_index() {  # keep a copy of the index, to put back on an undo
  local idx
  MC_SAVED_INDEX=$(mktemp "${TMPDIR:-/tmp}/mesh-commit-index.XXXXXX")
  idx=$(mc_index_path)
  if [ -f "$idx" ]; then
    cp -p "$idx" "$MC_SAVED_INDEX"; MC_HAD_INDEX=1
  else
    MC_HAD_INDEX=0
  fi
}

mc_restore_index() {
  local idx
  [ -n "$MC_SAVED_INDEX" ] || return 0
  idx=$(mc_index_path)
  if [ "$MC_HAD_INDEX" = 1 ]; then cp -p "$MC_SAVED_INDEX" "$idx"; else rm -f "$idx"; fi
}

mc_is_named() {  # mc_is_named <path>: it is a named path or lies under one
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$1" = "$n" ] && return 0
    case "$1" in "$n"/*) return 0 ;; esac
  done <<EOF
$NAMED
EOF
  return 1
}

mc_commit_ok() {  # mc_commit_ok <rev>: every changed path is named, no gitlink
  local listing line meta path omode nmode
  listing=$(mc_git -c core.quotePath=false diff-tree -r --root --no-commit-id \
    --raw --no-renames --ignore-submodules=none "$1" 2>/dev/null) || return 1
  [ -n "$listing" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    meta=${line%%	*}
    path=${line#*	}
    omode=$(printf '%s\n' "$meta" | awk '{sub(/^:/, "", $1); print $1}')
    nmode=$(printf '%s\n' "$meta" | awk '{print $2}')
    if [ "$omode" = 160000 ] || [ "$nmode" = 160000 ]; then return 1; fi
    mc_is_named "$path" || return 1
  done <<EOF
$listing
EOF
  return 0
}

mc_verify_or_undo() {  # mc_verify_or_undo <HEAD before the commit, or empty>
  if mc_commit_ok HEAD; then return 0; fi
  if [ -n "$1" ]; then
    mc_git update-ref -m "mesh-commit: undo" HEAD "$1" >/dev/null 2>&1
  else
    mc_git update-ref -d HEAD >/dev/null 2>&1
  fi
  mc_restore_index
  return 1
}

mc_cleanup() {
  [ -n "$MC_SAVED_INDEX" ] && rm -f "$MC_SAVED_INDEX"
  [ -n "$MC_TMP" ] && rm -rf "$MC_TMP"
  return 0
}

mc_refuse() {  # one line, then exit 1
  printf 'REFUSED %s\n' "$(printf '%s' "$*" | tr '\n\r\t' '   ')"
  mc_cleanup
  exit 1
}

mc_first_line() { sed -n '/[^[:space:]]/{p;q;}' "$1" 2>/dev/null; }

mc_plain_chars() {  # the gate checks only paths of these characters
  case "$1" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./+@=\ -]*)
      return 1 ;;
  esac
  return 0
}

mc_find_gate() {
  local cfg c
  cfg="${CLAUDE_CODE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
  for c in "$cfg/hooks/git-gate.py" "$HOME/.claude/hooks/git-gate.py" \
           "$MC_DIR/../../hooks/git-gate.py"; do
    [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

mc_gate() {  # mc_gate <verbs csv> [<path> ...]: return 0 if the gate allows
  local verbs="$1"; shift
  MC_GATE_REASON=$("$MC_PY" -I -c "$MC_GATE_PY" "$MC_GATE" "$REPO" "$verbs" "$@" \
    2>/dev/null)
}

mc_submodule_paths() {  # every submodule path: .gitmodules, index, HEAD
  {
    git config -f "$REPO/.gitmodules" --get-regexp '^submodule\..*\.path$' \
      2>/dev/null | awk '{print $2}'
    mc_git config --blob HEAD:.gitmodules --get-regexp '^submodule\..*\.path$' \
      2>/dev/null | awk '{print $2}'
    mc_git ls-files -s 2>/dev/null | awk '$1 == "160000" {sub(/^[^\t]*\t/, ""); print}'
    mc_git ls-tree -r HEAD 2>/dev/null | awk '$1 == "160000" {sub(/^[^\t]*\t/, ""); print}'
  } | sed 's#/*$##' | LC_ALL=C sort -u
}

mc_check_path() {  # mc_check_path <raw path>: prints the normalized path
  local raw="$1" p d rd s anc
  case "$raw" in /*) mc_refuse "absolute path: $raw" ;; esac
  p="$raw"
  while :; do case "$p" in ./*) p=${p#./} ;; *) break ;; esac; done
  p=$(printf '%s' "$p" | sed -e 's#//*#/#g' -e 's#/*$##')
  [ -n "$p" ] && [ "$p" != "." ] || mc_refuse "empty path: '$raw'"
  case "/$p/" in
    */../*) mc_refuse "path holds a .. segment: $raw" ;;
    */./*)  mc_refuse "path holds a . segment: $raw" ;;
    */.git/*) mc_refuse "path holds a .git segment: $raw" ;;
  esac
  mc_plain_chars "$p" || mc_refuse "path has a character the git gate cannot check: $raw"
  # It must stay inside the repo: resolve its nearest existing folder.
  d=$(dirname "$REPO/$p")
  while [ ! -d "$d" ]; do d=$(dirname "$d"); done
  rd=$(cd "$d" 2>/dev/null && pwd -P) || mc_refuse "cannot resolve the folder of: $raw"
  case "$rd/" in "$MC_REAL_REPO"/*) ;; *) mc_refuse "path leaves the repo: $raw" ;; esac
  # Never a submodule: not one, not inside one, not holding one.
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if [ "$p" = "$s" ]; then mc_refuse "path is a submodule: $raw"; fi
    case "$p" in "$s"/*) mc_refuse "path lies inside submodule $s: $raw" ;; esac
    case "$s" in "$p"/*) mc_refuse "path holds submodule $s: $raw" ;; esac
  done <<EOF
$MC_SUBS
EOF
  anc=$(dirname "$p")
  while [ "$anc" != "." ] && [ "$anc" != "/" ]; do
    [ -e "$REPO/$anc/.git" ] && mc_refuse "path lies inside a nested repo $anc: $raw"
    anc=$(dirname "$anc")
  done
  if [ -d "$REPO/$p" ] && [ ! -L "$REPO/$p" ]; then
    if [ -n "$(find "$REPO/$p" -name .git -print 2>/dev/null | head -1)" ]; then
      mc_refuse "path holds a nested repo: $raw"
    fi
  fi
  # It must name something present or tracked (a deleted file is tracked).
  if [ ! -e "$REPO/$p" ] && [ ! -L "$REPO/$p" ] \
     && [ -z "$(mc_git ls-files -- "$p" 2>/dev/null | head -1)" ] \
     && [ -z "$(mc_git ls-tree -r --name-only HEAD -- "$p" 2>/dev/null | head -1)" ]; then
    mc_refuse "path names nothing present or tracked: $raw"
  fi
  printf '%s\n' "$p"
}

# Lift every staged gitlink (index differs from HEAD) out of the index, so a
# rebase cannot write it into a commit, and keep it to put back afterwards.
mc_lift_gitlinks() {
  # One pass over the index and one over HEAD, then work on gitlinks only:
  # a bus index holds thousands of entries and a handful of gitlinks.
  local sha path hs heads
  MC_LIFTED=""
  heads=$(mc_git ls-tree -r HEAD 2>/dev/null \
    | awk -F'\t' '{split($1, m, " "); if (m[1] == "160000") print m[3] "\t" $2}')
  while IFS='	' read -r sha path; do
    [ -n "$sha" ] && [ -n "$path" ] || continue
    hs=$(printf '%s\n' "$heads" | awk -F'\t' -v p="$path" '$2 == p {print $1; exit}')
    [ "$hs" = "$sha" ] && continue
    MC_LIFTED="$MC_LIFTED$sha $path
"
    if [ -n "$hs" ]; then
      mc_git update-index --cacheinfo "160000,$hs,$path" >/dev/null 2>&1
    else
      mc_git update-index --force-remove -- "$path" >/dev/null 2>&1
    fi
  done <<EOF
$(mc_git ls-files -s 2>/dev/null \
  | awk -F'\t' '{split($1, m, " "); if (m[1] == "160000") print m[2] "\t" $2}')
EOF
}

mc_restore_gitlinks() {
  local sha path
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sha=${line%% *}; path=${line#* }
    mc_git update-index --add --cacheinfo "160000,$sha,$path" >/dev/null 2>&1
  done <<EOF
$MC_LIFTED
EOF
}

mc_outgoing_gitlink() {  # 0 if a commit not yet on origin changes a gitlink
  local up
  [ -n "$1" ] || return 1
  up="refs/remotes/origin/$1"
  mc_git rev-parse -q --verify "$up" >/dev/null 2>&1 || return 1
  mc_git log --raw --no-renames --ignore-submodules=none --format= "$up..HEAD" \
    2>/dev/null | grep -qE '^:(160000 [0-7]+|[0-7]+ 160000) '
}

mc_epoch() {  # whole s since 1970-01-01T00:00:00Z of YYYY-MM-DDTHH:MM:SSZ, or -1
  printf '%s\n' "$1" | awk -F'[-T:Z]' '
    function days(y, m, d,   era, yoe, doy, doe) {
      y -= (m <= 2)
      era = int((y >= 0 ? y : y - 399) / 400)
      yoe = y - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe - 719468
    }
    NF >= 6 && $1 ~ /^[0-9][0-9][0-9][0-9]$/ {
      printf "%d\n", days($1 + 0, $2 + 0, $3 + 0) * 86400 + $4 * 3600 + $5 * 60 + $6
      next
    }
    { print -1 }'
}

mc_orphaned() {  # 0 if MC_PARENT is set and this process has lost that parent
  [ -n "${MC_PARENT:-}" ] || return 1
  [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != "$MC_PARENT" ]
}

# mc_heartbeat: rewrite last_poll (UTC, to the second) in the node's own
# agents/<AGENT_ID>.yaml and push it through this script, in a commit that
# holds only that file. Uses REPO, AGENT_ID and POLL (s). Writes nothing when
# the node has no record, its id is not plain, or a heartbeat within half a
# poll interval already stands. Returns 3, writing nothing, when the caller
# set MC_PARENT and has been orphaned, so no process that outlives the poller
# writes last_poll. A failed push is not an error here: returns 0. It makes
# one push attempt (the next scan pulls and carries an unpushed one), and
# puts the record back as it was if the commit is refused.
mc_heartbeat() {
  local file f now last tmp
  case "${AGENT_ID:-}" in
    ""|.|..|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*)
      return 0 ;;
  esac
  mc_orphaned && return 3
  file="agents/$AGENT_ID.yaml"
  f="$REPO/$file"
  [ -f "$f" ] || return 0
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  last=$(sed -n 's/^last_poll:[[:space:]]*//p' "$f" | head -1)
  last=$(mc_epoch "$last")
  if [ "$last" -ge 0 ] 2>/dev/null && \
     [ $(( $(mc_epoch "$now") - last )) -lt $(( ${POLL:-60} / 2 )) ] 2>/dev/null; then
    return 0  # a heartbeat this recent already stands
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/mesh-heartbeat.XXXXXX") || return 0
  if grep -q '^last_poll:' "$f"; then
    sed "s/^last_poll:.*/last_poll: $now/" "$f" > "$tmp"
  else
    cat "$f" > "$tmp"; printf 'last_poll: %s\n' "$now" >> "$tmp"
  fi
  cp -p "$f" "$tmp.orig" 2>/dev/null || { rm -f "$tmp"; return 0; }
  cat "$tmp" > "$f"
  rm -f "$tmp"
  MESH_COMMIT_PUSHES=1 bash "$MC_DIR/mesh-commit.sh" "$REPO" "heartbeat $AGENT_ID" \
    "$file" >/dev/null 2>&1 </dev/null
  case $? in
    1|2) cat "$tmp.orig" > "$f" ;;  # refused: leave the record as it was
  esac
  rm -f "$tmp.orig"
  return 0
}

mc_main() {
  local raw p head_before branch attempt pushed pushes files err sha
  if [ $# -lt 2 ]; then
    echo "usage: mesh-commit.sh <REPO> <message> <path> [<path> ...]" >&2
    exit 2
  fi
  REPO="$1"; MSG="$2"; shift 2
  MC_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mesh-commit.XXXXXX")
  err="$MC_TMP/err"

  case "$REPO" in /*) ;; *) mc_refuse "repo path is not absolute: $REPO" ;; esac
  [ -d "$REPO" ] || mc_refuse "no such folder: $REPO"
  MC_REAL_REPO=$(cd "$REPO" && pwd -P)
  p=$(mc_git rev-parse --show-toplevel 2>/dev/null) || mc_refuse "not a git repo: $REPO"
  [ "$(cd "$p" && pwd -P)" = "$MC_REAL_REPO" ] || \
    mc_refuse "not the top of its work tree: $REPO"
  [ -n "$MSG" ] || mc_refuse "empty message"
  case "$MSG" in *$'\n'*|*$'\r'*) mc_refuse "message is not one line" ;; esac
  [ $# -gt 0 ] || mc_refuse "no path given"

  MC_GATE=$(mc_find_gate) || mc_refuse "no git gate found to apply"
  if [ -x /usr/bin/python3 ]; then MC_PY=/usr/bin/python3
  else MC_PY=$(command -v python3) || mc_refuse "no python3 to run the git gate"; fi
  mc_gate commit,push || mc_refuse "git gate: $MC_GATE_REASON"

  MC_SUBS=$(mc_submodule_paths)
  NAMED=""
  for raw in "$@"; do
    p=$(mc_check_path "$raw") || { printf '%s\n' "$p"; mc_cleanup; exit 1; }
    NAMED="$NAMED$p
"
  done
  set --
  while IFS= read -r p; do [ -n "$p" ] && set -- "$@" "$p"; done <<EOF
$NAMED
EOF

  # The files the commit will hold: worktree changes and staged changes.
  files="$MC_TMP/files"
  { mc_git ls-files -z --others --modified --deleted --exclude-standard -- "$@"
    mc_git diff -z --cached --name-only --ignore-submodules=none -- "$@"
  } 2>/dev/null | tr '\0' '\n' | LC_ALL=C sort -u > "$files"
  if [ ! -s "$files" ]; then
    echo "NOTHING TO COMMIT"; mc_cleanup; exit 0
  fi
  while IFS= read -r p; do
    mc_plain_chars "$p" || mc_refuse "file has a character the git gate cannot check: $p"
  done < "$files"
  set --
  while IFS= read -r p; do set -- "$@" "$p"; done < "$files"
  mc_gate add "$@" || mc_refuse "git gate: $MC_GATE_REASON"
  set --
  while IFS= read -r p; do [ -n "$p" ] && set -- "$@" "$p"; done <<EOF
$NAMED
EOF

  head_before=$(mc_git rev-parse -q --verify HEAD 2>/dev/null || true)
  mc_save_index
  if ! mc_git add -- "$@" >/dev/null 2>"$err"; then
    mc_restore_index
    mc_refuse "git add failed: $(mc_first_line "$err")"
  fi
  if mc_git diff --cached --quiet --ignore-submodules=none -- "$@" 2>/dev/null; then
    echo "NOTHING TO COMMIT"; mc_cleanup; exit 0
  fi
  if ! mc_git commit -q -m "$MSG" -- "$@" >/dev/null 2>"$err"; then
    mc_restore_index
    mc_refuse "git commit failed: $(mc_first_line "$err")"
  fi
  mc_verify_or_undo "$head_before" || \
    mc_refuse "the commit held a path not named or a gitlink; undone"

  branch=$(mc_git symbolic-ref -q --short HEAD 2>/dev/null || true)
  # At most 3 pushes; MESH_COMMIT_PUSHES=1 (the heartbeat's) makes one and
  # leaves the retry to the next scan's pull.
  pushes=3
  case "${MESH_COMMIT_PUSHES:-}" in 1|2) pushes=$MESH_COMMIT_PUSHES ;; esac
  attempt=1; pushed=0
  while :; do
    if mc_outgoing_gitlink "$branch"; then
      echo "mesh-commit: a commit not yet on origin changes a submodule pin;" \
        "not pushing" >&2
      break
    fi
    if mc_git push -q origin HEAD >/dev/null 2>&1; then pushed=1; break; fi
    [ "$attempt" -ge "$pushes" ] && break
    mc_lift_gitlinks
    if [ -n "$branch" ]; then
      mc_git pull -q --rebase --autostash origin "$branch" >/dev/null 2>&1 || \
        mc_git rebase --abort >/dev/null 2>&1
    else
      mc_git pull -q --rebase --autostash >/dev/null 2>&1 || \
        mc_git rebase --abort >/dev/null 2>&1
    fi
    mc_restore_gitlinks
    if [ -n "$branch" ] && \
       mc_git merge-base --is-ancestor HEAD "refs/remotes/origin/$branch" 2>/dev/null; then
      attempt=$((attempt + 1)); continue  # nothing local left to push
    fi
    if ! mc_commit_ok HEAD; then
      # Unreachable in practice; never push a commit that fails the check.
      mc_git update-ref -m "mesh-commit: drop" HEAD HEAD^ >/dev/null 2>&1
      mc_git reset -q -- "$@" >/dev/null 2>&1
      mc_refuse "the rebased commit held a path not named or a gitlink; dropped"
    fi
    attempt=$((attempt + 1))
  done
  sha=$(mc_git rev-parse HEAD | cut -c1-7)
  echo "COMMITTED $sha"
  if [ "$pushed" = 1 ]; then
    echo "PUSHED"; mc_cleanup; exit 0
  fi
  echo "PUSH FAILED"; mc_cleanup; exit 3
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  mc_main "$@"
fi
