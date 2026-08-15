#!/usr/bin/env bash
# mesh-post.sh — turnkey SEND for the agent mesh. Writes one correctly-formed
# message file per target into the coordination repo and pushes it. Owns every
# mechanical part so the caller only supplies intent + body: resolves identity,
# pulls, assigns a GLOBALLY-UNIQUE id per message, emits schema-correct
# frontmatter, places the file in the right queue, then scope-commits (only the
# files it wrote — never `git add -A`) and pushes with pull-rebase retry.
#
# Usage:
#   mesh-post.sh --type <type> --title <slug> --body-file <path> \
#                --to <target> [--to <target> ...] \
#                [--priority low|normal|high] [--timeout-min N] \
#                [--credentials K1,K2] [--depends-on id1,id2] \
#                [--from <id>] [--repo <path>] [--dry-run]
#
#   <target>  role:<role>  -> tasks/roles/<role>/   (any holder claims it)
#             <agent_id>   -> tasks/<agent_id>/     (direct inbox: reply / pin)
#   --type    task.request | task.cancel | query | reply | library.submit | ...
#   --dry-run write files + stage, but do NOT commit or push (prints what it did)
#
# Identity: --from wins; else AGENT_ID from ~/.agent-identity.env; else op-main.
# Repo:     --repo wins; else REPO_PATH from ~/.agent-identity.env; else error.
#
# id uniqueness: id is <UTC-YYYYMMDDTHHMM>-<seq>. status files are keyed by id
# in ONE global namespace (status/<id>.json), so two messages must never share
# an id — even across different queues. This allocates each message the smallest
# <seq> not already used this minute by any target queue, by status/, or earlier
# in this same run. Posting one task to N roles therefore yields N distinct ids.
#
# Git gate: gated ops use the literal `-C <repo>` form and plain-text commit
# messages (no ; & | $() backticks), and stage only the exact new files.
#
# Portable: bash 3.2 (macOS default) and bash 4/5; BSD and GNU userland. UTC via
# `date -u`. No associative arrays, no `timeout`, no GNU-only flags.
set -uo pipefail

die() { echo "mesh-post: $*" >&2; exit 1; }

TYPE=""; TITLE=""; BODY_FILE=""; PRIORITY="normal"; TIMEOUT_MIN="120"
CREDS=""; DEPENDS=""; FROM=""; REPO=""; DRYRUN=0
TARGETS=""   # newline-separated

while [ $# -gt 0 ]; do
  case "$1" in
    --to)          TARGETS="$TARGETS${TARGETS:+$'\n'}$2"; shift 2 ;;
    --type)        TYPE="$2"; shift 2 ;;
    --title)       TITLE="$2"; shift 2 ;;
    --body-file)   BODY_FILE="$2"; shift 2 ;;
    --priority)    PRIORITY="$2"; shift 2 ;;
    --timeout-min) TIMEOUT_MIN="$2"; shift 2 ;;
    --credentials) CREDS="$2"; shift 2 ;;
    --depends-on)  DEPENDS="$2"; shift 2 ;;
    --from)        FROM="$2"; shift 2 ;;
    --repo)        REPO="$2"; shift 2 ;;
    --dry-run)     DRYRUN=1; shift ;;
    *)             die "unknown arg: $1" ;;
  esac
done

[ -n "$TYPE" ]      || die "--type required"
[ -n "$TITLE" ]     || die "--title required (kebab-case slug)"
[ -n "$BODY_FILE" ] || die "--body-file required"
[ -f "$BODY_FILE" ] || die "body file not found: $BODY_FILE"
[ -n "$TARGETS" ]   || die "at least one --to required"

# --- identity + repo ---
IDENT="$HOME/.agent-identity.env"
if [ -z "$FROM" ]; then
  if [ -f "$IDENT" ]; then
    FROM=$(sed -n 's/^AGENT_ID=//p' "$IDENT" | head -1)
  fi
  [ -n "$FROM" ] || FROM="op-main"
fi
if [ -z "$REPO" ]; then
  if [ -f "$IDENT" ]; then
    REPO=$(sed -n 's/^REPO_PATH=//p' "$IDENT" | head -1)
  fi
  [ -n "$REPO" ] || die "--repo required (no REPO_PATH in $IDENT)"
fi
[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || die "not a git repo: $REPO"

# normalize slug: lowercase, non-alnum -> '-', collapse, trim
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//'
}
SLUG=$(slugify "$TITLE")
[ -n "$SLUG" ] || die "--title produced an empty slug"

# --- pull first (ungated) so seq/id scan sees the latest queues ---
git -C "$REPO" pull --rebase --quiet 2>/dev/null || \
  echo "mesh-post: warning: pull --rebase failed; continuing on local view" >&2

STAMP=$(date -u +%Y%m%dT%H%M)
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# seqs already taken for this STAMP, anywhere: every target queue, status/, and
# ids allocated earlier in this run. Space-wrapped string used as a set.
USED=" "
scan_dir_for_stamp() {  # collect existing <STAMP>-NNNN seqs under a dir
  local d="$1" f base seq
  [ -d "$d" ] || return 0
  for f in "$d/$STAMP"-*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    seq=$(echo "$base" | sed -n "s/^$STAMP-\([0-9][0-9]*\).*/\1/p")
    [ -n "$seq" ] && USED="$USED$seq "
  done
}

target_dir() {  # target -> queue dir (absolute)
  case "$1" in
    role:*) echo "$REPO/tasks/roles/${1#role:}" ;;
    *)      echo "$REPO/tasks/$1" ;;
  esac
}

# pre-scan status/ (global id namespace) and every target queue
scan_dir_for_stamp "$REPO/status"
while IFS= read -r t; do
  [ -n "$t" ] || continue
  scan_dir_for_stamp "$(target_dir "$t")"
done <<EOF
$TARGETS
EOF

# Sets global SEQ to the smallest 4-digit seq not in USED, and marks it used.
# NOT called via $(...) — command substitution would run in a subshell and lose
# the USED update, which is exactly how every message would collide on 0001.
next_seq() {
  local n=1 s
  while :; do
    s=$(printf '%04d' "$n")
    case "$USED" in *" $s "*) n=$((n+1)); continue ;; esac
    USED="$USED$s "
    SEQ="$s"
    return 0
  done
}

# yaml list literal from CSV: "a,b" -> [a, b]; empty -> []
yaml_list() {
  local csv="$1"
  [ -n "$csv" ] || { echo "[]"; return; }
  echo "[$(echo "$csv" | sed 's/,/, /g')]"
}
CRED_YAML=$(yaml_list "$CREDS")
DEP_YAML=$(yaml_list "$DEPENDS")

WRITTEN=""      # newline: "<target>\t<id>\t<path>"
STAGE=""        # space-separated paths for one scoped git add

while IFS= read -r TARGET; do
  [ -n "$TARGET" ] || continue
  DIR=$(target_dir "$TARGET")
  mkdir -p "$DIR"
  case "$TARGET" in
    role:*) TO="role:${TARGET#role:}" ;;
    *)      TO="$TARGET" ;;
  esac
  next_seq
  ID="$STAMP-$SEQ"
  FILE="$DIR/$ID-$SLUG.md"
  [ -e "$FILE" ] && die "target file already exists (unexpected): $FILE"

  {
    echo "---"
    echo "schema_version: 1"
    echo "id: $ID"
    echo "from: $FROM"
    echo "to: $TO"
    echo "type: $TYPE"
    echo "created: $CREATED"
    echo "priority: $PRIORITY"
    echo "credentials: $CRED_YAML"
    echo "depends_on: $DEP_YAML"
    echo "timeout_min: $TIMEOUT_MIN"
    echo "---"
    echo ""
    cat "$BODY_FILE"
  } > "$FILE"

  WRITTEN="$WRITTEN$TARGET	$ID	$FILE
"
  STAGE="$STAGE $FILE"
done <<EOF
$TARGETS
EOF

echo "mesh-post: wrote message file(s):"
printf '%s' "$WRITTEN" | while IFS=$'\t' read -r t id p; do
  [ -n "$t" ] || continue
  echo "  $t  id=$id  $p"
done

if [ "$DRYRUN" -eq 1 ]; then
  git -C "$REPO" add $STAGE
  echo "mesh-post: --dry-run: staged but did not commit/push."
  exit 0
fi

# --- gated: scoped add, plain-text commit, push with pull-rebase retry ---
git -C "$REPO" add $STAGE || die "git add failed"

IDS=$(printf '%s' "$WRITTEN" | awk -F'\t' 'NF{printf "%s%s",sep,$2; sep=","}')
TOS=$(printf '%s' "$WRITTEN" | awk -F'\t' 'NF{printf "%s%s",sep,$1; sep=","}')
MSG="post $TYPE to $TOS ids $IDS"
git -C "$REPO" commit -m "$MSG" || die "git commit failed"

PUSHED=0
i=1
while [ "$i" -le 3 ]; do
  if git -C "$REPO" push origin HEAD 2>/dev/null; then
    PUSHED=1; break
  fi
  echo "mesh-post: push rejected (attempt $i); pull --rebase and retry" >&2
  git -C "$REPO" pull --rebase --quiet 2>/dev/null || true
  i=$((i+1))
done
[ "$PUSHED" -eq 1 ] || die "push failed after 3 attempts; commit is local at $REPO"

echo "mesh-post: committed and pushed ($MSG)"
