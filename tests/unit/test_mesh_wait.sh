#!/usr/bin/env bash
# Unit test of skills/mesh-on/mesh-wait.sh (R1 and R2, plan section 2.2,
# Ruling 2026-10-29T16:34Z): the poller parks on it, synchronously, while a
# background executor runs. It returns DONE when the executor's done file
# appears, WAITING at its deadline, STOP when the stop sentinel is up; it
# keeps the last_poll heartbeat going through mesh-commit.sh while it waits;
# a failed push does not stop it; and it leaves no process behind. Runs about
# 30 s.
set -u
. "$(dirname "$0")/lib.sh"
unit_setup
MW="$SKILLS/mesh-on/mesh-wait.sh"

mk_product product
mk_bus bus
allow_repo "$BUS"
ID=n1
printf 'schema_version: 1\nagent_id: n1\nagent_name: node-one\npoll_interval_sec: 1\nlast_poll: 2026-01-01T00:00:00Z\n' \
  > "$BUS/agents/$ID.yaml"
bash "$SKILLS/mesh-on/mesh-commit.sh" "$BUS" "register n1" "agents/$ID.yaml" >/dev/null
stale_product
origin_lp() { g -C "$BUS_ORIGIN" show "main:agents/$ID.yaml" | sed -n 's/^last_poll: //p'; }
STAGE="$T/staging"
mkdir -p "$STAGE"

# --- the executor finishes while the poller waits: DONE soon after, with
# heartbeats pushed meanwhile, each holding only the node's own record.
base=$(g -C "$BUS_ORIGIN" rev-parse main)
( sleep 4; : > "$STAGE/.done" ) &
SECONDS=0
out=$(bash "$MW" "$BUS" "$ID" 1 "$STAGE/.done" 30); rc=$?
el=$SECONDS
wait
check "the done file gives DONE, exit 0" eq "$rc:$out" "0:DONE"
check "DONE comes within 3 s of the done file (4 s)" test "$el" -le 7
check "the done file is not consumed" test -e "$STAGE/.done"
n=$(g -C "$BUS_ORIGIN" rev-list --count "$base..main")
check "heartbeats were pushed while waiting" test "$n" -ge 1
bad=0
for c in $(g -C "$BUS_ORIGIN" rev-list "$base..main"); do
  [ "$(changed_paths "$BUS_ORIGIN" "$c")" = "agents/$ID.yaml" ] || bad=$((bad + 1))
done
check "every heartbeat holds only agents/$ID.yaml" eq "$bad" 0
check "last_poll on origin moved" test "$(origin_lp)" != "2026-01-01T00:00:00Z"
check "origin still pins the product at the pin" \
  eq "$(g -C "$BUS_ORIGIN" rev-parse main:product)" "$PIN"

# --- a done file already there: DONE at once, no heartbeat needed.
out=$(bash "$MW" "$BUS" "$ID" 1 "$STAGE/.done" 30); rc=$?
check "an existing done file gives DONE at once" eq "$rc:$out" "0:DONE"
rm -f "$STAGE/.done"

# --- no done file: WAITING at the deadline, exit 5, heartbeat still going.
sed -i.bak 's/^last_poll: .*/last_poll: 2026-01-01T00:00:00Z/' "$BUS/agents/$ID.yaml"
rm -f "$BUS/agents/$ID.yaml.bak"
SECONDS=0
out=$(bash "$MW" "$BUS" "$ID" 1 "$STAGE/.done" 3); rc=$?
el=$SECONDS
check "no done file gives WAITING at the deadline, exit 5" eq "$rc:$out" "5:WAITING"
check "WAITING comes by the deadline (3 s) plus one heartbeat" test "$el" -le 9
check "the wait rewrote last_poll" \
  test "$(sed -n 's/^last_poll: //p' "$BUS/agents/$ID.yaml")" != "2026-01-01T00:00:00Z"

# --- a failed push neither stops the wait nor keeps it from DONE.
g -C "$BUS" remote set-url origin "$T/no-such-origin.git"
( sleep 2; : > "$STAGE/.done" ) &
out=$(bash "$MW" "$BUS" "$ID" 1 "$STAGE/.done" 30); rc=$?
wait
check "with origin unreachable the wait still ends DONE" eq "$rc:$out" "0:DONE"
g -C "$BUS" remote set-url origin "$BUS_ORIGIN"
rm -f "$STAGE/.done"

# --- STOP: the stop sentinel ends the wait at once, with no heartbeat.
before=$(sed -n 's/^last_poll: //p' "$BUS/agents/$ID.yaml")
sleep 1
touch "$HOME/.mesh-stop"
out=$(bash "$MW" "$BUS" "$ID" 1 "$STAGE/.done" 30); rc=$?
check "the stop sentinel gives STOP, exit 2" eq "$rc:$out" "2:STOP"
check "no heartbeat on STOP" eq "$(sed -n 's/^last_poll: //p' "$BUS/agents/$ID.yaml")" "$before"
rm -f "$HOME/.mesh-stop"

# --- it leaves no process behind once it returns.
bash "$MW" "$BUS" "$ID" 1 "$STAGE/.done" 2 >/dev/null & wpid=$!
wait "$wpid"
check "no child of the wait outlives it" test -z "$(pgrep -P "$wpid" 2>/dev/null)"
check "no wait process remains" \
  test -z "$(pgrep -f "mesh-wait.sh $BUS" 2>/dev/null)"

# --- an orphaned caller writes no heartbeat (white-box: the shared heartbeat
# with a parent that is not this process's parent).
. "$SKILLS/mesh-on/mesh-commit.sh"
REPO="$BUS"; AGENT_ID="$ID"; POLL=1; MC_PARENT=1
sed -i.bak 's/^last_poll: .*/last_poll: 2026-01-01T00:00:00Z/' "$BUS/agents/$ID.yaml"
rm -f "$BUS/agents/$ID.yaml.bak"
mc_heartbeat; hrc=$?
check "an orphaned caller's heartbeat returns 3" eq "$hrc" 3
check "and writes nothing" \
  eq "$(sed -n 's/^last_poll: //p' "$BUS/agents/$ID.yaml")" "2026-01-01T00:00:00Z"
MC_PARENT=""

# --- usage errors
bash "$MW" >/dev/null 2>&1; rc=$?
check "no arguments is a usage error" eq "$rc" 2
bash "$MW" "$BUS" "$ID" 1 relative/.done >/dev/null 2>&1; rc=$?
check "a relative done file is a usage error" eq "$rc" 2
bash "$MW" "$BUS" "$ID" x "$STAGE/.done" >/dev/null 2>&1; rc=$?
check "a poll interval that is not a number is a usage error" eq "$rc" 2

unit_done
