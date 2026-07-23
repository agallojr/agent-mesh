#!/usr/bin/env bash
# mesh-post — post ONE message into the agent mesh over the GitHub Contents API.
# Repo-neutral: no local clone, no git. For devices like a phone on claude.ai/code.
# Auth comes from $GH_PAT_RESEARCH (a PAT with Contents:read/write on the bus repo).
#
# usage:
#   mesh-post --to role:<role>|<node-id> [--type task.request|query] \
#             [--slug kebab-summary] [--priority low|normal|high] [--from op-phone] < body.md
#
#   The markdown BODY (Goal / Context / Done when / On failure) is read from stdin;
#   this script wraps it in PROTOCOL §5 frontmatter and creates the file via one PUT.
set -euo pipefail

OWNER=agallojr
REPO=agent-mesh-bus
BRANCH=main
FROM=op-phone
TYPE=task.request
PRIORITY=normal
SLUG=msg
TO=""

usage() {
  echo "usage: mesh-post --to role:<role>|<node-id> [--type task.request|query]" >&2
  echo "                 [--slug kebab] [--priority low|normal|high] [--from id] < body.md" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --to)       TO="$2"; shift 2 ;;
    --type)     TYPE="$2"; shift 2 ;;
    --slug)     SLUG="$2"; shift 2 ;;
    --priority) PRIORITY="$2"; shift 2 ;;
    --from)     FROM="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "${GH_PAT_RESEARCH:-}" ] || { echo "GH_PAT_RESEARCH not set in env" >&2; exit 1; }
[ -n "$TO" ] || usage

# resolve target directory + to-field
case "$TO" in
  role:*) ROLE="${TO#role:}"; DIR="tasks/roles/$ROLE"; TOFIELD="role:$ROLE" ;;
  *)      DIR="tasks/$TO";    TOFIELD="$TO" ;;
esac

API="https://api.github.com/repos/$OWNER/$REPO/contents"
TS="$(date -u +%Y%m%dT%H%M)"
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BODY="$(cat)"

put_once() {
  # next 4-digit seq unique within this UTC minute (0001 if dir empty/404)
  local last seq id file msg payload http
  last=$(curl -fsS -H "Authorization: Bearer $GH_PAT_RESEARCH" \
                   -H "Accept: application/vnd.github+json" \
                   "$API/$DIR?ref=$BRANCH" 2>/dev/null \
         | grep -oE "\"name\": *\"$TS-[0-9]{4}" | grep -oE '[0-9]{4}' | sort -n | tail -1 || true)
  seq=$(printf '%04d' $(( 10#${last:-0} + 1 )))
  id="$TS-$seq"
  file="$DIR/$id-$SLUG.md"

  msg="$(cat <<EOF
---
schema_version: 1
id: $id
from: $FROM
to: $TOFIELD
type: $TYPE
created: $CREATED
priority: $PRIORITY
credentials: []
depends_on: []
timeout_min: 120
---

$BODY
EOF
)"

  payload="$(MSG="$msg" ID="$id" TOFIELD="$TOFIELD" BRANCH="$BRANCH" python3 - <<'PY'
import base64, json, os
print(json.dumps({
    "message": f"post {os.environ['ID']} to {os.environ['TOFIELD']}",
    "content": base64.b64encode(os.environ["MSG"].encode()).decode(),
    "branch": os.environ["BRANCH"],
}))
PY
)"

  http=$(curl -sS -o /tmp/mesh-put.out -w '%{http_code}' -X PUT \
    -H "Authorization: Bearer $GH_PAT_RESEARCH" \
    -H "Accept: application/vnd.github+json" \
    "$API/$file" -d "$payload")

  if [ "$http" = 201 ]; then
    echo "posted: $file (id=$id) -> $TOFIELD"
    return 0
  fi
  # 409/422 => filename raced; recompute seq and retry. Others are fatal.
  if [ "$http" = 409 ] || [ "$http" = 422 ]; then
    return 42
  fi
  echo "FAILED http=$http" >&2
  cat /tmp/mesh-put.out >&2
  return 1
}

for attempt in 1 2 3; do
  if put_once; then exit 0; fi
  rc=$?
  [ "$rc" = 42 ] || exit "$rc"   # non-race failure
done
echo "FAILED: seq collision after 3 attempts" >&2
exit 1
