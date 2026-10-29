#!/usr/bin/env bash
# Unit test of skills/mesh-on/mesh-register.sh (plan sections 2.2 and 2.4,
# R4.S1): the node record has the PROTOCOL 4.3 fields plus poll_interval_sec
# and last_poll, holds no credential value, and its commit holds only
# agents/<id>.yaml while a stale product checkout leaves the pin unmoved.
set -u
. "$(dirname "$0")/lib.sh"
unit_setup
MR="$SKILLS/mesh-on/mesh-register.sh"

mk_product product
mk_bus bus
allow_repo "$BUS"
stale_product
echo "operator edit" >> "$BUS/README.md"

cat > "$HOME/.agent-identity.env" <<EOF
# identity for the unit test
AGENT_ID=a1b2c3
AGENT_NAME=unit-node
AGENT_CONTEXT=macos-laptop          # frontier-login | macos-laptop
POLL_INTERVAL_SEC=60
AGENT_ROLES=build, swe.build
REPO_PATH=$BUS
#MESH_POLLER_MODEL=sonnet
EOF
cat > "$HOME/.agent-credentials.env" <<'EOF'
# never committed
GH_PAT_RESEARCH=ghp_unitsecretvalue0001
export OLCF_PROJECT_ID=unit-secret-project-0002
EMPTY_ONE=
EOF
before=$(g -C "$BUS" rev-parse HEAD)
bus_commit=$(g -C "$BUS" rev-parse HEAD | cut -c1-7)

out=$(bash "$MR" "$BUS"); rc=$?
check "registration exits 0" eq "$rc" 0
check "registration prints COMMITTED then PUSHED" \
  eq "$(printf '%s\n' "$out" | sed 's/^COMMITTED [0-9a-f]\{7\}$/COMMITTED sha/')" \
  "$(printf 'COMMITTED sha\nPUSHED')"
F="$BUS/agents/a1b2c3.yaml"
check "the node record exists" test -f "$F"
field() { sed -n "s/^$1: //p" "$F"; }
check "schema_version" eq "$(field schema_version)" 1
check "agent_id" eq "$(field agent_id)" a1b2c3
check "agent_name" eq "$(field agent_name)" unit-node
check "context" eq "$(field context)" macos-laptop
check "roles" eq "$(field roles)" "[build, swe.build]"
check "hostname is set" test -n "$(field hostname)"
check "platform is set" test -n "$(field platform)"
check "cwd is the repo" eq "$(field cwd)" "$BUS"
check "repo_commit is the bus commit it registered at" eq "$(field repo_commit)" "$bus_commit"
check "poll_interval_sec" eq "$(field poll_interval_sec)" 60
check "heartbeat_sec is 900 when MESH_HEARTBEAT_SEC is unset" \
  eq "$(field heartbeat_sec)" 900
check "credentials_available lists key names" \
  eq "$(field credentials_available)" "[GH_PAT_RESEARCH, OLCF_PROJECT_ID, EMPTY_ONE]"
utc='^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$'
check "registered_at is UTC to the second" test -n "$(field registered_at | grep "$utc")"
check "session_started is UTC to the second" test -n "$(field session_started | grep "$utc")"
check "last_poll is UTC to the second" test -n "$(field last_poll | grep "$utc")"
check "last_poll is the registration time" eq "$(field last_poll)" "$(field registered_at)"
check "no model line without MESH_SESSION_MODEL" eq "$(grep -c '^model:' "$F")" 0
check "no credential value in the record" \
  eq "$(grep -c -e unitsecretvalue -e unit-secret-project "$F")" 0
check "no credential value in the commit" \
  eq "$(g -C "$BUS" show HEAD | grep -c -e unitsecretvalue -e unit-secret-project)" 0
check "one commit" eq "$(g -C "$BUS" rev-list --count "$before..HEAD")" 1
check "the commit holds only agents/a1b2c3.yaml" \
  eq "$(changed_paths "$BUS" HEAD)" "agents/a1b2c3.yaml"
check "the commit message" eq "$(g -C "$BUS" log -1 --format=%s)" "register unit-node (a1b2c3)"
check "the bus still pins the product at the pin" eq "$(g -C "$BUS" rev-parse HEAD:product)" "$PIN"
check "origin still pins the product at the pin" \
  eq "$(g -C "$BUS_ORIGIN" rev-parse main:product)" "$PIN"
check "the stale gitlink is still staged, not committed" \
  eq "$(g -C "$BUS" ls-files -s product | awk '{print $2}')" "$PROD_OLD"
check "origin has the registration" \
  eq "$(g -C "$BUS_ORIGIN" rev-parse main)" "$(g -C "$BUS" rev-parse HEAD)"

# A model id passed by the session is recorded; a legacy AGENT_ROLE is a
# one-role list; no credentials file gives an empty list.
sed -i.bak -e 's/^AGENT_ROLES=.*/AGENT_ROLE=install/' "$HOME/.agent-identity.env"
rm -f "$HOME/.agent-identity.env.bak" "$HOME/.agent-credentials.env"
sleep 1
out=$(MESH_SESSION_MODEL=claude-opus-5-5 bash "$MR" "$BUS"); rc=$?
check "a second registration exits 0" eq "$rc" 0
check "model from MESH_SESSION_MODEL" eq "$(field model)" claude-opus-5-5
check "legacy AGENT_ROLE" eq "$(field roles)" "[install]"
check "no credentials file" eq "$(field credentials_available)" "[]"
check "the second commit holds only the record" \
  eq "$(changed_paths "$BUS" HEAD)" "agents/a1b2c3.yaml"

# heartbeat_sec follows MESH_HEARTBEAT_SEC: the set value, 900 for a
# non-number, empty or zero.
echo "MESH_HEARTBEAT_SEC=120   # s" >> "$HOME/.agent-identity.env"
bash "$MR" "$BUS" >/dev/null
check "heartbeat_sec is the set value" eq "$(field heartbeat_sec)" 120
for bad in abc "" 0 -5 1.5; do
  sed -i.bak -e "s/^MESH_HEARTBEAT_SEC=.*/MESH_HEARTBEAT_SEC=$bad/" "$HOME/.agent-identity.env"
  rm -f "$HOME/.agent-identity.env.bak"
  bash "$MR" "$BUS" >/dev/null
  check "heartbeat_sec is 900 for the value '$bad'" eq "$(field heartbeat_sec)" 900
done

# Leading zeros are decimal, and 00 is the default.
for pair in 08:8 09:9 0900:900 0100:100 00:900 007:7; do
  sed -i.bak -e "s/^MESH_HEARTBEAT_SEC=.*/MESH_HEARTBEAT_SEC=${pair%%:*}/" \
    "$HOME/.agent-identity.env"
  rm -f "$HOME/.agent-identity.env.bak"
  bash "$MR" "$BUS" >/dev/null
  check "heartbeat_sec for ${pair%%:*} is ${pair##*:}" \
    eq "$(field heartbeat_sec)" "${pair##*:}"
done

# Refusals write nothing.
head=$(g -C "$BUS" rev-parse HEAD)
sed -i.bak -e 's/^AGENT_ID=.*/AGENT_ID=..\/evil/' "$HOME/.agent-identity.env"
rm -f "$HOME/.agent-identity.env.bak"
out=$(bash "$MR" "$BUS"); rc=$?
check "an unsafe AGENT_ID is refused" eq "$rc:${out%% *}" "1:REFUSED"
check "nothing written outside agents/" test ! -e "$BUS/evil.yaml"
rm -f "$HOME/.agent-identity.env"
out=$(bash "$MR" "$BUS"); rc=$?
check "a missing identity file is refused" eq "$rc:${out%% *}" "1:REFUSED"
check "refusals commit nothing" eq "$(g -C "$BUS" rev-parse HEAD)" "$head"
out=$(bash "$MR" 2>/dev/null); rc=$?
check "no repo argument is a usage error" eq "$rc" 2

unit_done
