#!/usr/bin/env bash
# Unit test of the heartbeat cadence of skills/mesh-on/mesh-scan-loop.sh
# (heartbeat-every-15-min R1): with MESH_HEARTBEAT_SEC set, heartbeats are one
# heartbeat interval to one interval plus one poll interval apart; by default
# (900 s) a short run pushes at most one; a commit not on origin is pushed on
# the next scan whether or not a heartbeat is due; and mc_heartbeat reads a bad
# interval as 900 s without an error. Runs under 60 s (short POLL values).
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
local_lp() { sed -n 's/^last_poll: //p' "$BUS/agents/$ID.yaml"; }
epoch() { python3 -I -c 'import sys,calendar,time;print(calendar.timegm(time.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ")))' "$1"; }
reset_lp() {
  sed -i.bak 's/^last_poll: .*/last_poll: 2026-01-01T00:00:00Z/' "$BUS/agents/$ID.yaml"
  rm -f "$BUS/agents/$ID.yaml.bak"
  bash "$MC" "$BUS" "reset n1" "agents/$ID.yaml" >/dev/null
}

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
# about 5 s pushes exactly one heartbeat, not one per scan.
reset_lp
base=$(g -C "$BUS_ORIGIN" rev-parse main)
out=$(env -u MESH_HEARTBEAT_SEC bash "$SCAN" "$BUS" build "$ID" 1 5); rc=$?
check "by default a run of about 5 s pushes at most 1 heartbeat" \
  eq "$rc:$out:$(g -C "$BUS_ORIGIN" rev-list --count "$base..main")" "5:IDLE:1"

# --- an unpushed commit goes out on the next scan, apart from the heartbeat
# gate (a lost race or a failed registration, status or result push is not
# left waiting a heartbeat interval).
mkdir -p "$BUS/status"
echo '{"state": "done"}' > "$BUS/status/P1.json"
g -C "$BUS" add -- status/P1.json
g -C "$BUS" commit -q -m "unpushed status" -- status/P1.json
check "the local commit is not on origin yet" \
  eq "$(g -C "$BUS" rev-list --count origin/main..main)" 1
base=$(g -C "$BUS_ORIGIN" rev-parse main)
out=$(env -u MESH_HEARTBEAT_SEC bash "$SCAN" "$BUS" build "$ID" 1 1); rc=$?
check "the scan ends IDLE" eq "$rc:$out" "5:IDLE"
check "an unpushed commit reaches origin within one scan" \
  eq "$(g -C "$BUS" rev-list --count origin/main..main)" 0
check "and it is the commit, with no heartbeat beside it" \
  eq "$(g -C "$BUS_ORIGIN" log --format=%s "$base..main" | tr '\n' '|')" "unpushed status|"
check "origin still pins the product at the pin after that push" \
  eq "$(g -C "$BUS_ORIGIN" rev-parse main:product)" "$PIN"

# --- a bad MESH_HEARTBEAT_SEC (empty, abc, 0, 1.5) is the 900 s default and
# raises no error: a last_poll 100 s old is not rewritten; with 50 s it is.
lp100=$(python3 -I -c 'import time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(time.time()-100)))')
for v in "" abc 0 1.5; do
  sed -i.bak "s/^last_poll: .*/last_poll: $lp100/" "$BUS/agents/$ID.yaml"
  rm -f "$BUS/agents/$ID.yaml.bak"
  err=$( ( . "$MC"; REPO="$BUS"; AGENT_ID="$ID"; MESH_HEARTBEAT_SEC="$v"; mc_heartbeat ) 2>&1 ); hrc=$?
  check "MESH_HEARTBEAT_SEC='$v' is the 900 s default: no error, no write" \
    eq "$hrc:$err:$(local_lp)" "0::$lp100"
done
( . "$MC"; REPO="$BUS"; AGENT_ID="$ID"; MESH_HEARTBEAT_SEC=50; mc_heartbeat ) >/dev/null 2>&1
check "with 50 s the same last_poll is rewritten" test "$(local_lp)" != "$lp100"

unit_done
