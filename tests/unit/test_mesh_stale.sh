#!/usr/bin/env bash
# Unit test of skills/mesh-check/mesh-stale.sh (plan section 2.5, R2): with
# --now fixed, a node whose last poll is older than 3 poll intervals is named
# NOT POLLING with its age in s and the accepted and running tasks it holds;
# a node at 1 or exactly 3 intervals prints nothing; a node with no last_poll
# is named NO LAST POLL. It is read-only.
set -u
. "$(dirname "$0")/lib.sh"
unit_setup
MS="$SKILLS/mesh-check/mesh-stale.sh"

R="$T/bus"
mkdir -p "$R/agents" "$R/status"
node() {  # node <id> <name> <interval or -> <last_poll or ->
  {
    echo "schema_version: 1"
    echo "agent_id: $1"
    echo "agent_name: $2"
    [ "$3" = - ] || echo "poll_interval_sec: $3"
    [ "$4" = - ] || echo "last_poll: $4"
  } > "$R/agents/$1.yaml"
}
status() {  # status <task id> <agent id> <state>
  cat > "$R/status/$1.json" <<EOF
{
  "schema_version": 1,
  "task_id": "$1",
  "agent_id": "$2",
  "agent_name": "whoever",
  "state": "$3",
  "error": null
}
EOF
}
NOW=2026-10-29T15:04:00Z
node n1 node-one 60 2026-10-29T15:03:00Z     # 1 interval, 60 s
node n3 node-three 60 2026-10-29T15:01:00Z   # 3 intervals, 180 s
node n4 node-four 60 2026-10-29T15:00:00Z    # 4 intervals, 240 s
node nn node-none 60 -                       # no last_poll
: > "$R/agents/.gitkeep"
status 20261029T1400-0001 n4 running
status 20261029T1300-0002 n4 accepted
status 20261029T1200-0003 n4 done
status 20261029T1100-0004 n4 failed
status 20261029T1401-0005 n1 running
status 20261029T1402-0006 n3 accepted
printf '{"task_id": "20261029T1403-0007", "agent_id": "nn", "state": "running"}\n' \
  > "$R/status/20261029T1403-0007.json"
: > "$R/status/.gitkeep"

snap() { (cd "$R" && find . -type f -exec cksum {} \; | LC_ALL=C sort); }
before=$(snap)
out=$(bash "$MS" "$R" --now "$NOW"); rc=$?
expected="NOT POLLING n4 node-four: last poll 240 s ago at 2026-10-29T15:00:00Z, interval 60 s; holds 20261029T1300-0002 accepted, 20261029T1400-0001 running
NO LAST POLL nn node-none; holds 20261029T1403-0007 running"
check "exit 0" eq "$rc" 0
check "exactly the 4-interval node and the node with no last_poll" eq "$out" "$expected"
check "the 3-interval node (180 s) prints nothing" eq "$(printf '%s\n' "$out" | grep -c ' n3 ')" 0
check "the 1-interval node prints nothing" eq "$(printf '%s\n' "$out" | grep -c ' n1 ')" 0
check "done and failed tasks are not held" \
  eq "$(printf '%s\n' "$out" | grep -c -e 1200-0003 -e 1100-0004)" 0
check "read-only" eq "$(snap)" "$before"

# Intervals other than 60 s, an absent interval, quoting, and a node that
# holds nothing.
R="$T/bus2"
mkdir -p "$R/agents" "$R/status"
node a5 slow-ok 300 2026-10-29T14:54:00Z      # 600 s at 300 s: fine
node a6 slow-late 300 2026-10-29T14:48:59Z    # 901 s at 300 s: flagged
node a7 no-interval - 2026-10-29T15:00:59Z    # 181 s at the 60 s default
printf 'agent_id: a8\nagent_name: "quoted name"  # a comment\nlast_poll: "2026-10-29T14:00:00Z"\n' \
  > "$R/agents/a8.yaml"
out=$(bash "$MS" "$R" --now "$NOW"); rc=$?
expected="NOT POLLING a6 slow-late: last poll 901 s ago at 2026-10-29T14:48:59Z, interval 300 s; holds nothing
NOT POLLING a7 no-interval: last poll 181 s ago at 2026-10-29T15:00:59Z, interval 60 s; holds nothing
NOT POLLING a8 quoted name: last poll 3840 s ago at 2026-10-29T14:00:00Z, interval 60 s; holds nothing"
check "other intervals, the default interval and quoted values" eq "$out" "$expected"

# Ages across a day, a month, a year and a leap day.
R="$T/bus3"
mkdir -p "$R/agents"
node b1 year-end 60 2026-12-31T23:59:00Z
out=$(bash "$MS" "$R" --now 2027-01-01T00:04:00Z)
check "age across a year end" \
  eq "$out" "NOT POLLING b1 year-end: last poll 300 s ago at 2026-12-31T23:59:00Z, interval 60 s; holds nothing"
node b1 leap 60 2028-02-28T23:59:00Z
out=$(bash "$MS" "$R" --now 2028-03-01T00:00:00Z)
check "age across a leap day" \
  eq "$out" "NOT POLLING b1 leap: last poll 86460 s ago at 2028-02-28T23:59:00Z, interval 60 s; holds nothing"
node b1 fresh 60 2026-10-29T15:04:30Z
out=$(bash "$MS" "$R" --now "$NOW")
check "a last_poll after now prints nothing" eq "$out" ""
rm -f "$R/agents/b1.yaml"
out=$(bash "$MS" "$R" --now "$NOW"); rc=$?
check "no node files prints nothing and exits 0" eq "$rc:$out" "0:"

# The default now is the current UTC time.
node b2 just-now 60 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out=$(bash "$MS" "$R"); rc=$?
check "without --now a fresh node prints nothing" eq "$rc:$out" "0:"

# Usage errors.
bash "$MS" >/dev/null 2>&1; rc=$?
check "no repo is a usage error" eq "$rc" 2
bash "$MS" "$R" --now 2026-10-29 >/dev/null 2>&1; rc=$?
check "a malformed --now is a usage error" eq "$rc" 2
bash "$MS" "$T/no-such-bus" >/dev/null 2>&1; rc=$?
check "a missing repo is a usage error" eq "$rc" 2

unit_done
