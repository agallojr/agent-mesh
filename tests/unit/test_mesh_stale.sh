#!/usr/bin/env bash
# Unit test of skills/mesh-check/mesh-stale.sh (R2): with --now fixed, a node
# whose last poll is strictly older than 3 of its heartbeat intervals
# (heartbeat_sec from its record, 900 s when absent or not a number; 2700 s by
# default) is named NOT POLLING with its age in s and the accepted and running
# tasks it holds; a node at 1 or exactly 3 intervals prints nothing; a node
# with no last_poll is named NO LAST POLL. poll_interval_sec plays no part. It
# is read-only.
set -u
. "$(dirname "$0")/lib.sh"
unit_setup
MS="$SKILLS/mesh-check/mesh-stale.sh"

R="$T/bus"
mkdir -p "$R/agents" "$R/status"
node() {  # node <id> <name> <heartbeat_sec or -> <last_poll or ->
  {
    echo "schema_version: 1"
    echo "agent_id: $1"
    echo "agent_name: $2"
    echo "poll_interval_sec: 60"
    [ "$3" = - ] || echo "heartbeat_sec: $3"
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
node n1 node-one - 2026-10-29T15:04:00Z      # 0 s
node n2 node-two - 2026-10-29T14:49:00Z      # 900 s, 1 interval
node n3 node-three - 2026-10-29T14:19:00Z    # 2700 s, exactly 3 intervals
node n4 node-four - 2026-10-29T14:18:59Z     # 2701 s
node nn node-none - -                        # no last_poll
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
expected="NOT POLLING n4 node-four: last poll 2701 s ago at 2026-10-29T14:18:59Z, interval 900 s; holds 20261029T1300-0002 accepted, 20261029T1400-0001 running
NO LAST POLL nn node-none; holds 20261029T1403-0007 running"
check "exit 0" eq "$rc" 0
check "exactly the 2701 s node and the node with no last_poll" eq "$out" "$expected"
check "the 2700 s node prints nothing" eq "$(printf '%s\n' "$out" | grep -c ' n3 ')" 0
check "the 900 s node prints nothing" eq "$(printf '%s\n' "$out" | grep -c ' n2 ')" 0
check "done and failed tasks are not held" \
  eq "$(printf '%s\n' "$out" | grep -c -e 1200-0003 -e 1100-0004)" 0
check "read-only" eq "$(snap)" "$before"

# A node's own heartbeat_sec sets its threshold; poll_interval_sec (60 s in
# every record here) does not; a non-number heartbeat_sec is 900 s; quoting.
R="$T/bus2"
mkdir -p "$R/agents" "$R/status"
node a5 hb-120-ok 120 2026-10-29T14:58:00Z     # 360 s at 120 s: not flagged
node a6 hb-120-late 120 2026-10-29T14:57:59Z   # 361 s at 120 s: flagged
node a7 hb-absent - 2026-10-29T15:00:59Z       # 181 s: not flagged at the 900 s default
node a9 hb-junk abc 2026-10-29T14:18:59Z       # 2701 s, non-number: 900 s default
printf 'agent_id: a8\nagent_name: "quoted name"  # a comment\nheartbeat_sec: "900"\nlast_poll: "2026-10-29T14:00:00Z"\n' \
  > "$R/agents/a8.yaml"
node c1 lead-zero-08 08 2026-10-29T15:03:35Z   # 25 s at 8 s (not octal): flagged
node c2 lead-zero-09 09 2026-10-29T15:03:50Z   # 10 s at 9 s: not flagged
node c3 lead-zero-0900 0900 2026-10-29T14:48:00Z   # 960 s at 900 s: not flagged
node c4 lead-zero-0100 0100 2026-10-29T14:58:59Z   # 301 s at 100 s: flagged
node c5 zero-00 00 2026-10-29T14:18:59Z        # 00 is 900 s: 2701 s flagged
out=$(bash "$MS" "$R" --now "$NOW"); rc=$?
expected="NOT POLLING a6 hb-120-late: last poll 361 s ago at 2026-10-29T14:57:59Z, interval 120 s; holds nothing
NOT POLLING a8 quoted name: last poll 3840 s ago at 2026-10-29T14:00:00Z, interval 900 s; holds nothing
NOT POLLING a9 hb-junk: last poll 2701 s ago at 2026-10-29T14:18:59Z, interval 900 s; holds nothing
NOT POLLING c1 lead-zero-08: last poll 25 s ago at 2026-10-29T15:03:35Z, interval 8 s; holds nothing
NOT POLLING c4 lead-zero-0100: last poll 301 s ago at 2026-10-29T14:58:59Z, interval 100 s; holds nothing
NOT POLLING c5 zero-00: last poll 2701 s ago at 2026-10-29T14:18:59Z, interval 900 s; holds nothing"
check "own interval, absent interval, non-number, leading zeros and quoted values" eq "$out" "$expected"

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
