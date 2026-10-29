#!/usr/bin/env bash
# mesh-register.sh -- write this node's record, agents/<AGENT_ID>.yaml
# (PROTOCOL 4.3), and commit that one file through mesh-commit.sh. Step 4 of
# the mesh-on skill runs it; it replaces the hand-written file and the
# stage-everything commit that once recorded a stale submodule pin.
#
# Usage: mesh-register.sh <REPO>
#   Reads $HOME/.agent-identity.env (AGENT_ID, AGENT_NAME, AGENT_CONTEXT,
#   POLL_INTERVAL_SEC, AGENT_ROLES or a legacy AGENT_ROLE), and only the key
#   names, never the values, of $HOME/.agent-credentials.env when it exists.
#   MESH_SESSION_MODEL, if set in the environment, is written as `model:`
#   (the model id of the session that runs /mesh-on).
# Output and exit status: those of mesh-commit.sh (COMMITTED <sha7> and
# PUSHED, NOTHING TO COMMIT, REFUSED <reason>, or COMMITTED <sha7> and
# PUSH FAILED); REFUSED and 1 if the identity file is missing or its AGENT_ID
# is not a plain id; 2 for a usage error.
#
# The record's last_poll is the registration time; from then on the scanner
# (mesh-scan-loop.sh) rewrites it once per poll interval while the poller is
# live. Portable: bash 3.2+, POSIX sed, uname, date -u.
set -u

DIR=$(cd "$(dirname "$0")" && pwd)

if [ $# -ne 1 ]; then
  echo "usage: mesh-register.sh <REPO>" >&2
  exit 2
fi
REPO="$1"
IDENT="$HOME/.agent-identity.env"
CREDS="$HOME/.agent-credentials.env"

refuse() { printf 'REFUSED %s\n' "$*"; exit 1; }

[ -f "$IDENT" ] || refuse "no identity file at $IDENT"

idv() {  # idv <KEY>: value from the identity file, comment and quotes off
  sed -n "s/^[[:space:]]*$1=//p" "$IDENT" | head -1 \
    | sed -e 's/[[:space:]][[:space:]]*#.*$//' -e 's/^[[:space:]]*//' \
          -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

yval() {  # a YAML scalar: plain when safe, else double-quoted
  case "$1" in
    ""|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/@+-]*)
      printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" ;;
    *) printf '%s' "$1" ;;
  esac
}

ylist() {  # ylist <csv>: [a, b] with blanks dropped
  [ -n "$1" ] || { printf '[]'; return 0; }
  printf '%s\n' "$1" | awk -F',' '{
    out = ""
    for (i = 1; i <= NF; i++) {
      v = $i; gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v != "") out = out (out == "" ? "" : ", ") v
    }
    printf "[%s]", out
  }'
}

AGENT_ID=$(idv AGENT_ID)
case "$AGENT_ID" in
  ""|.|..|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*)
    refuse "AGENT_ID in $IDENT is not a plain id" ;;
esac
AGENT_NAME=$(idv AGENT_NAME)
AGENT_CONTEXT=$(idv AGENT_CONTEXT)
POLL=$(idv POLL_INTERVAL_SEC)
ROLES=$(idv AGENT_ROLES)
[ -n "$ROLES" ] || ROLES=$(idv AGENT_ROLE)

[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || refuse "not a git repo: $REPO"

KEYS=""
if [ -f "$CREDS" ]; then
  # Key names only: the expression captures the name and drops the rest.
  KEYS=$(sed -n \
    's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=.*$/\2/p' \
    "$CREDS" | tr '\n' ',')
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COMMIT=$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)
mkdir -p "$REPO/agents"
TMP=$(mktemp "${TMPDIR:-/tmp}/mesh-register.XXXXXX")
{
  echo "schema_version: 1"
  echo "agent_id: $AGENT_ID"
  echo "agent_name: $(yval "$AGENT_NAME")"
  echo "context: $(yval "$AGENT_CONTEXT")"
  echo "roles: $(ylist "$ROLES")"
  echo "hostname: $(yval "$(uname -n)")"
  echo "platform: $(yval "$(uname -sr)")"
  echo "cwd: $(yval "$REPO")"
  echo "repo_commit: $(yval "$COMMIT")"
  if [ -n "${MESH_SESSION_MODEL:-}" ]; then
    echo "model: $(yval "$MESH_SESSION_MODEL")"
  fi
  case "$POLL" in
    ""|*[!0123456789]*) ;;
    *) echo "poll_interval_sec: $POLL" ;;
  esac
  echo "credentials_available: $(ylist "$KEYS")"
  echo "registered_at: $NOW"
  echo "session_started: $NOW"
  echo "last_poll: $NOW"
} > "$TMP"
cat "$TMP" > "$REPO/agents/$AGENT_ID.yaml"
rm -f "$TMP"

exec bash "$DIR/mesh-commit.sh" "$REPO" "register $AGENT_NAME ($AGENT_ID)" \
  "agents/$AGENT_ID.yaml"
