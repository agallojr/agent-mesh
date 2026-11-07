#!/usr/bin/env bash
# mesh-workers.sh -- the worker cap and the stop of one worker's processes,
# for the poller that keeps polling while its workers run (PROTOCOL §8).
#
# Usage: mesh-workers.sh cap [<value>]
#        mesh-workers.sh stop <WORKERS_DIR> <task id>
#
# cap: reads <value> as MESH_MAX_WORKERS (PROTOCOL §4.1) and prints exactly
#   one line, exit 0:
#     max workers: <n>      <value> is a whole number of at least 1 written
#                           with no sign, space or leading zero
#     max workers: 3        <value> is absent or empty
#     max workers: 3 (MESH_MAX_WORKERS=<value> is not usable)   otherwise
#
# stop: stops the processes the worker recorded in <WORKERS_DIR>/<task id>/pids.
#   Each line that is a whole number above 1 (no sign, space or leading zero)
#   is a pid; any other line is skipped. Before the first signal it walks the
#   descendants of each listed pid still running with pgrep -P. It sends TERM
#   to each of them, checks every 1 s, and 10 s after the TERM sends KILL to
#   each still running. It returns as soon as none is running (at most 5 s
#   after the KILL, so a process stuck in the kernel cannot hold the poller).
#   A zombie counts as ended. It never signals pid 1, its own pid or an
#   ancestor of its own. It prints STOPPED <task id> <k> processes, <k> the
#   number of listed pids it sent TERM to (descendants are signalled, not
#   counted; 0 for a missing folder or pids file), exits 0 and removes nothing.
#   A <task id> that is empty or holds / or .., or a <WORKERS_DIR> that is not
#   absolute, is a usage error: one line on stderr, exit 2.
#
# Sourcing this file defines its functions without running it (the scanner
# reads the cap with mw_cap). Portable: bash 3.2+, POSIX ps, pgrep, macOS and
# Linux.

MW_DEFAULT_CAP=3
MW_KILL_AFTER_SEC=10
MW_KILL_GRACE_SEC=5

mw_usable() {  # 0 if $1 is a whole number >= 1 with no sign, space or 0 lead
  case "$1" in
    ""|0*|*[!0123456789]*) return 1 ;;
  esac
  return 0
}

mw_cap() {  # mw_cap <value>: print the cap the value gives
  if mw_usable "${1-}"; then printf '%s\n' "$1"; else echo "$MW_DEFAULT_CAP"; fi
}

mw_cap_line() {  # mw_cap_line [<value>]: the one line `cap` prints
  local v="${1-}"
  if [ -z "$v" ]; then
    echo "max workers: $MW_DEFAULT_CAP"
  elif mw_usable "$v"; then
    echo "max workers: $v"
  else
    v=$(printf '%s' "$v" | tr '\n\r' '  ')
    echo "max workers: $MW_DEFAULT_CAP (MESH_MAX_WORKERS=$v is not usable)"
  fi
}

mw_usage() {
  echo "usage: mesh-workers.sh cap [<value>] | stop <WORKERS_DIR> <task id>" >&2
  exit 2
}

mw_alive() {  # 0 if pid $1 runs (a zombie has ended)
  kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in
    ""|Z*) return 1 ;;
  esac
  return 0
}

mw_ancestors() {  # this process, then each ancestor up to pid 1, one per line
  local p=$$ n=0 pp
  while [ -n "$p" ] && [ "$p" != 0 ] && [ "$n" -lt 100 ]; do
    printf '%s\n' "$p"
    [ "$p" = 1 ] && return 0
    pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ "$pp" = "$p" ] && return 0
    p=$pp; n=$((n + 1))
  done
}

mw_stop() {  # mw_stop <WORKERS_DIR> <task id>
  local dir="$1" id="$2" file line p c listed="" all=" " guard queue sent=0
  local left now i
  file="$dir/$id/pids"
  guard=" 1 $(mw_ancestors | tr '\n' ' ') "
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      mw_usable "$line" || continue
      [ "$line" = 1 ] && continue
      case "$guard" in *" $line "*) continue ;; esac
      case " $listed " in *" $line "*) continue ;; esac
      mw_alive "$line" || continue
      listed="$listed $line"
    done < "$file"
  fi
  # Each listed pid and its descendants, walked before the first signal.
  queue="$listed"
  while [ -n "${queue# }" ]; do
    set -- $queue
    p="$1"; shift; queue=" $*"
    case "$all" in *" $p "*) continue ;; esac
    case "$guard" in *" $p "*) continue ;; esac
    all="$all$p "
    for c in $(pgrep -P "$p" 2>/dev/null); do
      queue="$queue $c"
    done
  done
  for p in $all; do
    kill -TERM "$p" 2>/dev/null || continue
    case " $listed " in *" $p "*) sent=$((sent + 1)) ;; esac
  done
  i=0
  while :; do
    left=""
    for p in $all; do mw_alive "$p" && left="$left $p"; done
    [ -n "$left" ] || break
    [ "$i" -ge $((MW_KILL_AFTER_SEC + MW_KILL_GRACE_SEC)) ] && break
    sleep 1; i=$((i + 1))
    if [ "$i" -eq "$MW_KILL_AFTER_SEC" ]; then
      for p in $left; do mw_alive "$p" && kill -KILL "$p" 2>/dev/null; done
    fi
  done
  echo "STOPPED $id $sent processes"
}

mw_main() {
  case "${1-}" in
    cap)
      [ $# -le 2 ] || mw_usage
      mw_cap_line "${2-}"
      exit 0 ;;
    stop)
      [ $# -eq 3 ] || mw_usage
      case "$2" in /*) ;; *) mw_usage ;; esac
      case "$3" in ""|*/*|*..*) mw_usage ;; esac
      mw_stop "$2" "$3"
      exit 0 ;;
    *) mw_usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  mw_main "$@"
fi
