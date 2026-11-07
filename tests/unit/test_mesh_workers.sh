#!/usr/bin/env bash
# Unit test of skills/mesh-on/mesh-workers.sh (poll-while-workers-run plan
# sections 2.1 and 2.2): `cap` reads MESH_MAX_WORKERS as a whole number of at
# least 1 with no sign, space or leading zero, else 3, in one line, with a
# notice for a value that is not usable; `stop` sends TERM to each pid a
# worker recorded and to its descendants, KILL 10 s later to any still
# running, skips every other line, never signals its own ancestors, removes
# nothing, and prints STOPPED <id> <k> processes. Every process it signals
# here is one this test started. Runs about 12 s.
set -u
. "$(dirname "$0")/lib.sh"
unit_setup
MW="$SKILLS/mesh-on/mesh-workers.sh"
W="$T/workers"
mkdir -p "$W"
STARTED=""  # every fixture process this test starts; killed on exit
start_bg() { "$@" >/dev/null 2>&1 </dev/null & LAST=$!; STARTED="$STARTED $LAST"; }
cleanup() {
  local p
  for p in $STARTED; do
    gone "$p" && continue
    pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null
  done
  rm -rf "$T"
}
trap cleanup EXIT

run() { out=$("$@" 2>"$T/err"); rc=$?; err=$(cat "$T/err"); }
lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }
gone() {  # gone <pid>: not running (a zombie not yet reaped counts as gone)
  kill -0 "$1" 2>/dev/null || return 0
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*|"") return 0 ;; esac
  return 1
}
reap() {  # reap <pid>...: collect each fixture process that has ended
  local p
  for p in "$@"; do gone "$p" && wait "$p" 2>/dev/null; done
  return 0
}
wait_child() {  # wait_child <pid>: print its first child once it has one
  local i=0 c=""
  while [ "$i" -lt 50 ]; do
    c=$(pgrep -P "$1" 2>/dev/null | head -1)
    [ -n "$c" ] && { printf '%s\n' "$c"; return 0; }
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# --- cap: none, empty, usable values.
run bash "$MW" cap
check "cap with no value prints max workers: 3" eq "$rc:$out:$err" "0:max workers: 3:"
run bash "$MW" cap ""
check "cap with an empty value prints max workers: 3" eq "$rc:$out:$err" "0:max workers: 3:"
for v in 1 5 10 12; do
  run bash "$MW" cap "$v"
  check "cap $v prints max workers: $v" eq "$rc:$out:$err" "0:max workers: $v:"
done

# --- cap: values that are not usable give 3 and the notice, in one line.
for v in 0 two -1 07 " 2" "2 " +2 1.5 00; do
  run bash "$MW" cap "$v"
  check "cap '$v' exits 0 with one line" eq "$rc:$(lines "$out")" "0:1"
  check "cap '$v' prints 3 with the notice" \
    eq "$out" "max workers: 3 (MESH_MAX_WORKERS=$v is not usable)"
done
run bash "$MW" cap "$(printf '1\n2')"
check "a value holding a newline still gives one line" eq "$rc:$(lines "$out")" "0:1"
check "and that line has the notice" \
  test -n "$(printf '%s\n' "$out" | grep 'max workers: 3 (.*is not usable)')"

# --- stop: a sleep, a process that ignores TERM (with its child), a shell
# whose child is a sleep, and a line that is not a pid. All gone when it
# returns, the TERM-ignoring one only after the 10 s KILL; 3 sent TERM.
mkdir -p "$W/t1"
start_bg sleep 3600; A=$LAST
start_bg bash -c 'trap "" TERM; sleep 3600; :'; B=$LAST
start_bg bash -c 'sleep 3600; :'; C=$LAST
BC=$(wait_child "$B"); DC=$(wait_child "$C")
check "the fixture processes started" test -n "$BC" -a -n "$DC"
printf '%s\n%s\nabc\n%s\n' "$A" "$B" "$C" > "$W/t1/pids"
SECONDS=0
run bash "$MW" stop "$W" t1
el=$SECONDS
check "stop prints STOPPED t1 3 processes, exit 0" eq "$rc:$out:$err" "0:STOPPED t1 3 processes:"
check "the TERM-ignoring process held it at least 10 s ($el s)" test "$el" -ge 10
check "it returned soon after the KILL ($el s)" test "$el" -le 14
for p in "$A" "$B" "$BC" "$C" "$DC"; do
  check "process $p is gone" gone "$p"
done
check "stop removes nothing" test -f "$W/t1/pids" -a -d "$W/t1"
reap "$A" "$B" "$C"

# --- stop returns as soon as none runs: a plain sleep ends on TERM.
mkdir -p "$W/t2"
start_bg sleep 3600; A=$LAST
printf '%s\n' "$A" > "$W/t2/pids"
SECONDS=0
run bash "$MW" stop "$W" t2
el=$SECONDS
check "one sleep: STOPPED t2 1 processes" eq "$rc:$out" "0:STOPPED t2 1 processes"
check "it returns within 3 s when TERM is enough ($el s)" test "$el" -le 3
check "the sleep is gone" gone "$A"
reap "$A"

# --- a pid already ended is not counted; running it again sends nothing.
run bash "$MW" stop "$W" t2
check "a second stop of the same worker sends TERM to none" eq "$rc:$out" "0:STOPPED t2 0 processes"

# --- no pids file, or no folder: 0 processes.
mkdir -p "$W/t3"
run bash "$MW" stop "$W" t3
check "no pids file: STOPPED t3 0 processes" eq "$rc:$out:$err" "0:STOPPED t3 0 processes:"
run bash "$MW" stop "$W" t9
check "no folder: STOPPED t9 0 processes" eq "$rc:$out:$err" "0:STOPPED t9 0 processes:"
check "and it made no folder" test ! -e "$W/t9"

# --- lines that are not a whole number above 1 are skipped, a live process
# behind them included.
mkdir -p "$W/t4"
start_bg sleep 3600; A=$LAST
printf ' %s\n%s \n0%s\n+%s\n%sx\n-%s\n\n0\n1\n' "$A" "$A" "$A" "$A" "$A" "$A" > "$W/t4/pids"
run bash "$MW" stop "$W" t4
check "only lines that are not a pid: STOPPED t4 0 processes" eq "$rc:$out" "0:STOPPED t4 0 processes"
check "the process behind them still runs" test "$(gone "$A" && echo gone || echo runs)" = runs
kill "$A" 2>/dev/null; reap "$A"

# --- it never signals an ancestor: a wrapper this test starts records its
# own pid, then runs stop, which is its child.
mkdir -p "$W/t5"
out=$(bash -c 'printf "%s\n" "$$" > "$1/t5/pids"; bash "$2" stop "$1" t5' _ "$W" "$MW" 2>&1); rc=$?
check "an ancestor's pid is not signalled: STOPPED t5 0 processes, exit 0" \
  eq "$rc:$out" "0:STOPPED t5 0 processes"

# --- usage errors: one line on stderr, exit 2, nothing on stdout.
for args in "stop relative/w t1" "stop $W a/b" "stop $W .." "stop $W a..b" \
            "stop $W" "stop" "bogus" ""; do
  # shellcheck disable=SC2086
  run bash "$MW" $args
  check "usage error for [${args//"$W"/<W>}]: exit 2, one stderr line, no stdout" \
    eq "$rc:$(lines "$err"):$out" "2:1:"
done
run bash "$MW" stop "$W" ""
check "an empty task id is a usage error" eq "$rc:$(lines "$err"):$out" "2:1:"

unit_done
