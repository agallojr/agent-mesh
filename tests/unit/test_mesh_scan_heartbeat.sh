#!/usr/bin/env bash
# Unit test of the heartbeat in skills/mesh-on/mesh-scan-loop.sh (plan
# sections 2.2 and 2.6, R2; heartbeat-every-15-min R1): a scan rewrites
# last_poll in the node's own agents/<id>.yaml and pushes it through
# mesh-commit.sh, in a commit that holds only that file and no gitlink, once
# per heartbeat interval (MESH_HEARTBEAT_SEC, 900 s by default) and not on
# every scan; a failed push never stops or delays the scan; the scanner's
# output words and exit codes are as before. Runs under 60 s (short POLL,
# MAX_WAIT and heartbeat values).
set -u
. "$(dirname "$0")/lib.sh"
unit_setup
SCAN="$SKILLS/mesh-on/mesh-scan-loop.sh"
MC="$SKILLS/mesh-on/mesh-commit.sh"

mk_product product
mk_bus bus
allow_repo "$BUS"
ID=n1
printf 'schema_version: 1\nagent_id: n1\nagent_name: node-one\npoll_interval_sec: 1\nlast_poll: 2026-01-01T00:00:00Z\n' \
  > "$BUS/agents/$ID.yaml"
bash "$MC" "$BUS" "register n1" "agents/$ID.yaml" >/dev/null
stale_product
origin_lp() { g -C "$BUS_ORIGIN" show "main:agents/$ID.yaml" | sed -n 's/^last_poll: //p'; }
local_lp() { sed -n 's/^last_poll: //p' "$BUS/agents/$ID.yaml"; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch() { python3 -I -c 'import sys,calendar,time;print(calendar.timegm(time.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ")))' "$1"; }
reset_lp() {
  sed -i.bak 's/^last_poll: .*/last_poll: 2026-01-01T00:00:00Z/' "$BUS/agents/$ID.yaml"
  rm -f "$BUS/agents/$ID.yaml.bak"
  bash "$MC" "$BUS" "reset n1" "agents/$ID.yaml" >/dev/null
}
# The sections below that are not about the cadence heartbeat on every scan.
export MESH_HEARTBEAT_SEC=1

# --- idle: IDLE at the deadline, a heartbeat on the scans, each commit only
# the node's own file, the pin unmoved, the staged gitlink still staged.
base=$(g -C "$BUS_ORIGIN" rev-parse main)
t0=$(utc_now); SECONDS=0
out=$(bash "$SCAN" "$BUS" build "$ID" 1 3); rc=$?
el=$SECONDS; t1=$(utc_now)
check "idle run prints IDLE and exits 5" eq "$rc:$out" "5:IDLE"
check "idle run returns by its deadline (3 s, slack 4 s)" test "$el" -le 7
n=$(g -C "$BUS_ORIGIN" rev-list --count "$base..main")
check "idle run pushed at least 2 heartbeats" test "$n" -ge 2
bad=0
for c in $(g -C "$BUS_ORIGIN" rev-list "$base..main"); do
  [ "$(changed_paths "$BUS_ORIGIN" "$c")" = "agents/$ID.yaml" ] || bad=$((bad + 1))
done
check "every heartbeat commit holds only agents/$ID.yaml" eq "$bad" 0
lp=$(origin_lp)
check "origin last_poll is from this run" \
  test "$(printf '%s\n%s\n%s\n' "$t0" "$lp" "$t1" | LC_ALL=C sort | sed -n 2p)" = "$lp"
check "origin still pins the product at the pin" \
  eq "$(g -C "$BUS_ORIGIN" rev-parse main:product)" "$PIN"
check "the stale gitlink is still staged" \
  eq "$(g -C "$BUS" ls-files -s product | awk '{print $2}')" "$PROD_OLD"
check "the record is otherwise unchanged" \
  eq "$(grep -v '^last_poll:' "$BUS/agents/$ID.yaml" | tr '\n' '|')" \
  "schema_version: 1|agent_id: n1|agent_name: node-one|poll_interval_sec: 1|"

# --- the cadence: with a 1 s poll and MESH_HEARTBEAT_SEC=5, a run of about
# 12 s pushes 2 or 3 heartbeats, each at least 5 s and at most 6 s after the
# one before.
reset_lp
base=$(g -C "$BUS_ORIGIN" rev-parse main)
out=$(MESH_HEARTBEAT_SEC=5 bash "$SCAN" "$BUS" build "$ID" 1 12); rc=$?
check "the cadence run ends IDLE" eq "$rc:$out" "5:IDLE"
n=$(g -C "$BUS_ORIGIN" rev-list --count "$base..main")
check "2 or 3 heartbeats in about 12 s at 5 s ($n)" test "$n" -ge 2 -a "$n" -le 3
prev=""; gaps=""; bad=0
for c in $(g -C "$BUS_ORIGIN" rev-list --reverse "$base..main"); do
  e=$(epoch "$(g -C "$BUS_ORIGIN" show "$c:agents/$ID.yaml" | sed -n 's/^last_poll: //p')")
  if [ -n "$prev" ]; then
    d=$((e - prev)); gaps="$gaps $d"
    [ "$d" -ge 5 ] && [ "$d" -le 6 ] || bad=$((bad + 1))
  fi
  prev=$e
done
check "consecutive heartbeats are 5 to 6 s apart (gaps:$gaps s)" eq "$bad" 0

# --- the default (unset) interval is 900 s: from an old last_poll, a run of
# about 10 s pushes exactly one heartbeat, then a second run right after it
# pushes none (the fresh heartbeat stands).
reset_lp
base=$(g -C "$BUS_ORIGIN" rev-parse main)
out=$(env -u MESH_HEARTBEAT_SEC bash "$SCAN" "$BUS" build "$ID" 1 10); rc=$?
check "by default a run of about 10 s pushes at most 1 heartbeat" \
  eq "$rc:$out:$(g -C "$BUS_ORIGIN" rev-list --count "$base..main")" "5:IDLE:1"
out=$(env -u MESH_HEARTBEAT_SEC bash "$SCAN" "$BUS" build "$ID" 1 1); rc=$?
check "a fresh heartbeat is not repeated by default" \
  eq "$rc:$out:$(g -C "$BUS_ORIGIN" rev-list --count "$base..main")" "5:IDLE:1"

# --- work: the scan that finds work writes its heartbeat, then WORK.
OTHER="$T/other"
g clone -q "$BUS_ORIGIN" "$OTHER" 2>/dev/null
mkdir -p "$OTHER/tasks/roles/build"
TASK="tasks/roles/build/20261029T1500-0001-unit.md"
printf -- '---\nid: 20261029T1500-0001\ntype: task.request\n---\nbody\n' > "$OTHER/$TASK"
g -C "$OTHER" add "$TASK"
g -C "$OTHER" commit -q -m "post task"
g -C "$OTHER" push -q origin main 2>/dev/null
sed -i.bak 's/^last_poll: .*/last_poll: 2026-01-01T00:00:00Z/' "$BUS/agents/$ID.yaml"
rm -f "$BUS/agents/$ID.yaml.bak"
bash "$MC" "$BUS" "reset n1" "agents/$ID.yaml" >/dev/null
out=$(bash "$SCAN" "$BUS" build "$ID" 1 10); rc=$?
check "a queued task gives WORK and the path, exit 0" \
  eq "$rc:$out" "0:$(printf 'WORK\n%s' "$BUS/$TASK")"
check "the scan that found work wrote a heartbeat" \
  test "$(origin_lp)" != "2026-01-01T00:00:00Z"
check "the work heartbeat holds only agents/$ID.yaml" \
  eq "$(changed_paths "$BUS_ORIGIN" main)" "agents/$ID.yaml"
mkdir -p "$BUS/status"
echo '{"state": "done"}' > "$BUS/status/20261029T1500-0001.json"

# --- a failed push neither stops nor delays the scan.
g -C "$BUS" remote set-url origin "$T/no-such-origin.git"
sed -i.bak 's/^last_poll: .*/last_poll: 2026-01-01T00:00:00Z/' "$BUS/agents/$ID.yaml"
rm -f "$BUS/agents/$ID.yaml.bak"
SECONDS=0
out=$(bash "$SCAN" "$BUS" build "$ID" 1 3); rc=$?
el=$SECONDS
check "with origin unreachable the scan still ends IDLE, exit 5" eq "$rc:$out" "5:IDLE"
check "with origin unreachable it returns by its deadline (2 s) plus one heartbeat ($el s)" test "$el" -le 10
check "with origin unreachable last_poll is still rewritten" \
  test "$(local_lp)" != "2026-01-01T00:00:00Z"
TASK2="tasks/roles/build/20261029T1501-0002-unit.md"
printf -- '---\nid: 20261029T1501-0002\ntype: task.request\n---\nbody\n' > "$BUS/$TASK2"
out=$(bash "$SCAN" "$BUS" build "$ID" 1 5); rc=$?
check "with origin unreachable work is still found" \
  eq "$rc:$out" "0:$(printf 'WORK\n%s' "$BUS/$TASK2")"
rm -f "$BUS/$TASK2"

# --- origin back: the scanner's pull rebases the unpushed heartbeats and the
# next heartbeat pushes them; no commit on origin moves the pin, although the
# stale gitlink stays staged through every pull.
g -C "$BUS" remote set-url origin "$BUS_ORIGIN"
echo "other two" > "$OTHER/other2.txt"
g -C "$OTHER" pull -q --rebase 2>/dev/null
g -C "$OTHER" add other2.txt
g -C "$OTHER" commit -q -m "other node two"
g -C "$OTHER" push -q origin main 2>/dev/null
base=$(g -C "$BUS_ORIGIN" rev-parse main)
out=$(bash "$SCAN" "$BUS" build "$ID" 1 2); rc=$?
check "after origin returns the scan ends IDLE" eq "$rc:$out" "5:IDLE"
check "the unpushed heartbeats reached origin" \
  eq "$(g -C "$BUS" rev-list --count main..origin/main):$(g -C "$BUS" rev-list --count origin/main..main)" "0:0"
pins=0
for c in $(g -C "$BUS_ORIGIN" rev-list "$base..main"); do
  if g -C "$BUS_ORIGIN" diff-tree -r --no-commit-id --raw --ignore-submodules=none "$c" \
     | grep -qE '(^:160000| 160000 )'; then pins=$((pins + 1)); fi
done
check "no pushed commit changes a gitlink" eq "$pins" 0
check "origin still pins the product at the pin after the rebase" \
  eq "$(g -C "$BUS_ORIGIN" rev-parse main:product)" "$PIN"
check "the stale gitlink is still staged after the rebase" \
  eq "$(g -C "$BUS" ls-files -s product | awk '{print $2}')" "$PROD_OLD"

# --- STOP: no heartbeat once the stop sentinel is up.
base=$(g -C "$BUS_ORIGIN" rev-parse main)
before=$(local_lp)
touch "$HOME/.mesh-stop"
sleep 1
out=$(bash "$SCAN" "$BUS" build "$ID" 1 6); rc=$?
check "the stop sentinel gives STOP, exit 2" eq "$rc:$out" "2:STOP"
check "no heartbeat after STOP" \
  eq "$(local_lp):$(g -C "$BUS_ORIGIN" rev-list --count "$base..main")" "$before:0"
rm -f "$HOME/.mesh-stop"

# --- a node with no record, or an id that is not a plain id, writes nothing.
base=$(g -C "$BUS_ORIGIN" rev-parse main)
out=$(bash "$SCAN" "$BUS" build n9 1 1); rc=$?
check "an unregistered node still scans" eq "$rc:$out" "5:IDLE"
check "an unregistered node writes no record" test ! -e "$BUS/agents/n9.yaml"
out=$(bash "$SCAN" "$BUS" build "../agents/n1" 1 1); rc=$?
check "an id that is not plain writes no heartbeat" \
  eq "$rc:$(g -C "$BUS_ORIGIN" rev-list --count "$base..main")" "5:0"

# --- fix round 1: a local commit that conflicts with origin (a lost claim)
# never leaves the checkout mid-rebase after the scanner's pull.
g -C "$OTHER" pull -q --rebase 2>/dev/null
echo '{"agent_id": "other"}' > "$OTHER/status/C1.json"
g -C "$OTHER" add status/C1.json
g -C "$OTHER" commit -q -m "other claims C1"
g -C "$OTHER" push -q origin main 2>/dev/null
echo '{"agent_id": "n1"}' > "$BUS/status/C1.json"
g -C "$BUS" add -- status/C1.json
g -C "$BUS" commit -q -m "n1 claims C1" -- status/C1.json
out=$(bash "$SCAN" "$BUS" build "$ID" 1 1); rc=$?
check "with a conflicting local commit the scan still ends IDLE" eq "$rc:$out" "5:IDLE"
check "the scanner's pull leaves no rebase in progress" \
  test ! -d "$BUS/.git/rebase-merge" -a ! -d "$BUS/.git/rebase-apply"
check "and the local commit is still on the branch, under its heartbeat" \
  eq "$(g -C "$BUS" log -2 --format=%s HEAD | tr '\n' '|')" "heartbeat n1|n1 claims C1|"

# --- fix round 2: a rebase someone started by hand is left alone. The scan
# does not abort it, and no heartbeat is committed in the middle of it.
g -C "$BUS" fetch -q origin 2>/dev/null
g -C "$BUS" rebase -q origin/main >/dev/null 2>&1
check "a hand-started rebase stopped on its conflict" test -d "$BUS/.git/rebase-merge"
rhead=$(g -C "$BUS" rev-parse HEAD)
out=$(bash "$SCAN" "$BUS" build "$ID" 1 1); rc=$?
check "during a rebase by hand the scan still ends IDLE" eq "$rc:$out" "5:IDLE"
check "the scan leaves the rebase by hand in progress" test -d "$BUS/.git/rebase-merge"
check "no heartbeat is committed in the middle of it" eq "$(g -C "$BUS" rev-parse HEAD)" "$rhead"
g -C "$BUS" rebase --abort >/dev/null 2>&1

unit_done
