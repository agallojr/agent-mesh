#!/usr/bin/env bash
# Unit test of worker mode in skills/mesh-on/mesh-scan-loop.sh
# (poll-while-workers-run plan section 2.4). With no MESH_WORKERS_DIR the
# scanner is as at base: every claimable task.request listed, STOP at once on
# the sentinel. With one, it counts the worker subfolders against the cap
# from MESH_MAX_WORKERS (3 when unset or not usable), lists the oldest
# task.requests by id up to the room left, and none at the cap or on the stop
# sentinel; it lists cancels, queries, replies and library submissions at any
# load, after the worker lines FINISHED and TIMEOUT; it checks the workers
# folder between scans and gives STOP only once no worker is left; and it
# writes nothing there. A throwaway bus, POLL 1 s or 30 s, short MAX_WAIT.
# Runs about 45 s.
set -u
. "$(dirname "$0")/lib.sh"
unit_setup
SCAN="$SKILLS/mesh-on/mesh-scan-loop.sh"
unset MESH_WORKERS_DIR MESH_MAX_WORKERS MESH_HEARTBEAT_SEC

mk_product product
mk_bus bus
allow_repo "$BUS"
ID=n1
W="$T/workers"
SEEN="$HOME/.mesh-seen-replies"

msg() {  # msg <queue dir under tasks/> <file stem> <id> <type>: print its path
  local d="$BUS/tasks/$1" f
  mkdir -p "$d"
  f="$d/$2.md"
  printf -- '---\nid: %s\ntype: %s\n---\nbody\n' "$3" "$4" > "$f"
  printf '%s\n' "$f"
}
clear_queues() { rm -rf "$BUS/tasks" "$BUS/status/"*.json "$W"; : > "$SEEN"; }
worker() { mkdir -p "$W/$1"; }  # worker <task id>: a running worker
scan() { out=$(bash "$SCAN" "$BUS" "$@" 2>&1); rc=$?; }
work() { printf 'WORK\n'; printf '%s\n' "$@"; }  # the expected WORK output
nl() { printf '%s\n' "$@"; }

# --- base: no MESH_WORKERS_DIR. Three queued task.requests, all listed.
clear_queues
r1=$(msg roles/build 20261107T1501-0001-a 20261107T1501-0001 task.request)
r2=$(msg roles/build 20261107T1502-0001-b 20261107T1502-0001 task.request)
r3=$(msg roles/build 20261107T1503-0001-c 20261107T1503-0001 task.request)
scan build "$ID" 1 6
check "base: three queued task.requests are all listed" eq "$rc:$out" "0:$(work "$r1" "$r2" "$r3")"
MESH_WORKERS_DIR= MESH_MAX_WORKERS=1 scan build "$ID" 1 6
check "base: an empty MESH_WORKERS_DIR is base, and MESH_MAX_WORKERS caps nothing" \
  eq "$rc:$out" "0:$(work "$r1" "$r2" "$r3")"
touch "$HOME/.mesh-stop"
SECONDS=0
scan build "$ID" 1 6
el=$SECONDS
check "base: the sentinel gives STOP at once" eq "$rc:$out:$((el <= 1))" "2:STOP:1"
rm -f "$HOME/.mesh-stop"

export MESH_WORKERS_DIR="$W" MESH_MAX_WORKERS=2

# --- worker mode, none running: the two oldest by id, across queues and
# whatever the file names' order.
clear_queues
q1=$(msg roles/build a-third 20261107T1503-0001 task.request)
q2=$(msg roles/build b-first 20261107T1501-0001 task.request)
q3=$(msg "$ID" c-second 20261107T1502-0001 task.request)
scan build "$ID" 1 6
check "no workers folder yet: running 0, the two oldest by id" eq "$rc:$out" "0:$(work "$q2" "$q3")"
mkdir -p "$W/.hidden"; : > "$W/not-a-folder"
scan build "$ID" 1 6
check "a workers folder with only a file and a dot folder: running 0" \
  eq "$rc:$out" "0:$(work "$q2" "$q3")"
rm -rf "$W/not-a-folder" "$W/.hidden"

# --- one running: room for one, the oldest.
worker 20261107T1400-0001
scan build "$ID" 1 6
check "one worker at a cap of 2: only the oldest" eq "$rc:$out" "0:$(work "$q2")"

# --- two running (the cap): no task.request, but a queued task.cancel and
# query are listed.
worker 20261107T1400-0002
c1=$(msg roles/build d-cancel 20261107T1504-0001 task.cancel)
y1=$(msg "$ID" e-query 20261107T1505-0001 query)
scan build "$ID" 1 6
check "at the cap: the cancel and the query, no task.request" eq "$rc:$out" "0:$(work "$c1" "$y1")"
rm -f "$c1" "$y1"
SECONDS=0
scan build "$ID" 1 2
el=$SECONDS
check "at the cap with only task.requests queued: IDLE, exit 5" eq "$rc:$out" "5:IDLE"
check "and by its deadline (2 s, slack 3 s; $el s)" test "$el" -le 5

# --- the order: worker lines, then cancels and queries, replies, library
# submissions, then task.requests.
clear_queues
worker 20261107T1400-0003; : > "$W/20261107T1400-0003/.done"
c1=$(msg roles/build f-cancel 20261107T1504-0001 task.cancel)
y1=$(msg "$ID" g-query 20261107T1505-0001 query)
p1=$(msg "$ID" h-reply 20261107T1506-0001 reply)
s1=$(msg roles/librarian i-submit 20261107T1507-0001 library.submit)
q1=$(msg roles/build j-task 20261107T1508-0001 task.request)
q2=$(msg roles/build k-task 20261107T1509-0001 task.request)
scan build,librarian "$ID" 1 6
check "the whole order, one slot left" \
  eq "$rc:$out" "0:$(nl WORK "FINISHED 20261107T1400-0003" "$c1" "$y1" "$p1" "$s1" "$q1")"
scan build,librarian "$ID" 1 6
check "FINISHED repeats; reply and submit only once" \
  eq "$rc:$out" "0:$(nl WORK "FINISHED 20261107T1400-0003" "$c1" "$y1" "$q1")"

# --- worker lines in task id order, FINISHED and TIMEOUT mixed; a deadline
# that is not a whole number gives none.
clear_queues
past=$(( $(date -u +%s) - 5 ))
worker 20261107T1400-0009; echo "$past" > "$W/20261107T1400-0009/deadline"
worker 20261107T1400-0005; : > "$W/20261107T1400-0005/.done"
worker 20261107T1400-0007; echo "$past" > "$W/20261107T1400-0007/deadline"
: > "$W/20261107T1400-0007/.done"
worker 20261107T1400-0006; echo soon > "$W/20261107T1400-0006/deadline"
worker 20261107T1400-0008; echo "$(( past + 3600 ))" > "$W/20261107T1400-0008/deadline"
before=$(cd "$W" && find . | LC_ALL=C sort)
scan build "$ID" 1 6
check "worker lines in task id order; .done wins over a passed deadline" \
  eq "$rc:$out" "0:$(nl WORK "FINISHED 20261107T1400-0005" "FINISHED 20261107T1400-0007" "TIMEOUT 20261107T1400-0009")"
check "the scanner writes nothing in the workers folder" \
  eq "$(cd "$W" && find . | LC_ALL=C sort)" "$before"

# --- a subfolder that gains .done gives FINISHED within 3 s: at POLL 1 s,
# and at POLL 30 s, where it is the check between scans that sees it.
for poll in 1 30; do
  clear_queues
  worker 20261107T1401-0001
  ( sleep 1; : > "$W/20261107T1401-0001/.done" ) & bgp=$!
  SECONDS=0
  scan build "$ID" "$poll" 6
  el=$SECONDS
  wait "$bgp"
  check "POLL $poll s: .done gives FINISHED" eq "$rc:$out" "0:$(nl WORK "FINISHED 20261107T1401-0001")"
  check "POLL $poll s: within 3 s of the .done (written at 1 s; $el s)" test "$el" -le 4
done

# --- a deadline 2 s ahead gives TIMEOUT within 3 s after it.
for poll in 1 30; do
  clear_queues
  worker 20261107T1402-0001
  echo "$(( $(date -u +%s) + 2 ))" > "$W/20261107T1402-0001/deadline"
  SECONDS=0
  scan build "$ID" "$poll" 6
  el=$SECONDS
  check "POLL $poll s: a deadline 2 s ahead gives TIMEOUT" eq "$rc:$out" "0:$(nl WORK "TIMEOUT 20261107T1402-0001")"
  check "POLL $poll s: within 3 s after it ($el s)" test "$el" -ge 1 -a "$el" -le 5
done

# --- the stop sentinel with one worker: no STOP and no task.request; a
# cancel is still listed; STOP within 3 s of the last subfolder's removal.
clear_queues
worker 20261107T1403-0001
q1=$(msg roles/build l-task 20261107T1510-0001 task.request)
touch "$HOME/.mesh-stop"
SECONDS=0
scan build "$ID" 1 2
el=$SECONDS
check "sentinel and one worker: IDLE, not STOP, no task.request" eq "$rc:$out" "5:IDLE"
check "and it went on scanning to its deadline ($el s)" test "$el" -ge 2
c1=$(msg "$ID" m-cancel 20261107T1511-0001 task.cancel)
scan build "$ID" 1 2
check "sentinel and one worker: the cancel is listed, no task.request" eq "$rc:$out" "0:$(work "$c1")"
rm -f "$c1"
for poll in 1 30; do
  worker 20261107T1403-0001
  ( sleep 1; rm -rf "$W/20261107T1403-0001" ) & bgp=$!
  SECONDS=0
  scan build "$ID" "$poll" 6
  el=$SECONDS
  wait "$bgp"
  check "POLL $poll s: STOP once the last worker is removed" eq "$rc:$out" "2:STOP"
  check "POLL $poll s: within 3 s of the removal (at 1 s; $el s)" test "$el" -le 4
done
SECONDS=0
scan build "$ID" 1 6
el=$SECONDS
check "sentinel and no worker: STOP at once" eq "$rc:$out:$((el <= 1))" "2:STOP:1"
rm -f "$HOME/.mesh-stop"

# --- the cap rule: unset, empty or not usable is 3; a usable value is that
# number, however large.
clear_queues
mkdir -p "$W"
q1=$(msg roles/build n-a 20261107T1601-0001 task.request)
q2=$(msg roles/build n-b 20261107T1602-0001 task.request)
q3=$(msg roles/build n-c 20261107T1603-0001 task.request)
q4=$(msg roles/build n-d 20261107T1604-0001 task.request)
for v in two 0 ""; do  # the rest of the rule: test_mesh_workers.sh, same code
  MESH_MAX_WORKERS="$v" scan build "$ID" 1 6
  check "MESH_MAX_WORKERS='$v' acts as 3" eq "$rc:$out" "0:$(work "$q1" "$q2" "$q3")"
done
out=$(env -u MESH_MAX_WORKERS bash "$SCAN" "$BUS" build "$ID" 1 6 2>&1); rc=$?
check "MESH_MAX_WORKERS unset acts as 3" eq "$rc:$out" "0:$(work "$q1" "$q2" "$q3")"
MESH_MAX_WORKERS=1 scan build "$ID" 1 6
check "MESH_MAX_WORKERS=1: the oldest only" eq "$rc:$out" "0:$(work "$q1")"
MESH_MAX_WORKERS=99999999999999999999 scan build "$ID" 1 6
check "a cap past the shell's integers lists all four, no error" \
  eq "$rc:$out" "0:$(work "$q1" "$q2" "$q3" "$q4")"
worker 20261107T1404-0001; worker 20261107T1404-0002; worker 20261107T1404-0003
c1=$(msg roles/build n-e 20261107T1605-0001 task.cancel)
MESH_MAX_WORKERS=two scan build "$ID" 1 6
check "three workers at 'two' (3): the cancel, no task.request" eq "$rc:$out" "0:$(work "$c1")"
rm -f "$c1"
MESH_MAX_WORKERS=4 scan build "$ID" 1 6
check "three workers at 4: room for one" eq "$rc:$out" "0:$(work "$q1")"

# --- the heartbeat goes on while workers run, once per heartbeat interval.
clear_queues
worker 20261107T1405-0001
printf 'schema_version: 1\nagent_id: n1\nagent_name: node-one\npoll_interval_sec: 1\nlast_poll: 2026-01-01T00:00:00Z\n' \
  > "$BUS/agents/$ID.yaml"
bash "$SKILLS/mesh-on/mesh-commit.sh" "$BUS" "register n1" "agents/$ID.yaml" >/dev/null
base=$(g -C "$BUS_ORIGIN" rev-parse main)
MESH_HEARTBEAT_SEC=1 scan build "$ID" 1 2
n=$(g -C "$BUS_ORIGIN" rev-list --count "$base..main")
check "with a worker running the scan ends IDLE" eq "$rc:$out" "5:IDLE"
check "and heartbeats were pushed meanwhile ($n)" test "$n" -ge 1

unit_done
