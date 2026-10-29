#!/usr/bin/env bash
# mesh-wait.sh -- the poller's park while an executor runs. The poller runs its
# executor in the background, so the Agent call returns at once, and a poller
# that then "waits" by ending its turn leaves the node deaf, with nothing
# scanning and no heartbeat, until the executor's report wakes it, if it ever
# does (the R1 defect). Instead the poller parks on this script as ONE
# SYNCHRONOUS Bash call, as it parks on mesh-scan-loop.sh, and keeps its turn.
#
# Usage: mesh-wait.sh <REPO> <AGENT_ID> <POLL_SEC> <DONE_FILE> \
#          [MAX_WAIT_SEC [TASK_DEADLINE]]
#   DONE_FILE      absolute path the executor creates as its last act, after
#                  it has written its result (the poller puts both in the
#                  task's staging folder)
#   MAX_WAIT_SEC   this call's deadline: defaults to $MESH_MAX_WAIT_SEC, else
#                  240 (4 min), under the 5-min prompt-cache TTL, as for the
#                  scanner
#   TASK_DEADLINE  optional, UTC epoch in s: the task's own cap (its dispatch
#                  time plus its timeout_min)
# Exit:  0 + "DONE"     -> DONE_FILE exists: the executor has finished
#        5 + "WAITING"  -> this call's deadline, executor still running: re-park
#        4 + "TIMEOUT"  -> TASK_DEADLINE passed: write the task failed
#        2 + usage line on stderr for a usage error
#
# It does not end on ~/.mesh-stop: a running executor finishes, the poller
# writes its terminal status, and the scanner stops the poller at the top of
# its next cycle. While it waits it rewrites last_poll in the node's own
# agents/<AGENT_ID>.yaml and pushes it once per heartbeat interval
# (MESH_HEARTBEAT_SEC, 900 s by default, checked every poll interval) through
# mesh-commit.sh (the shared mc_heartbeat), so a node busy on a long task still
# shows as polling. A failed push neither stops nor delays it. It starts only
# short-lived children (sleep, mesh-commit.sh), returns by its deadline, and
# writes no heartbeat once its caller is gone. It checks the done file every
# 2 s. Portable: bash 3.2+, POSIX userland, macOS and Linux.
set -uo pipefail

usage() {
  echo "usage: mesh-wait.sh <REPO> <AGENT_ID> <POLL_SEC> <DONE_FILE> [MAX_WAIT_SEC [TASK_DEADLINE]]" >&2
  exit 2
}
[ $# -ge 4 ] && [ $# -le 6 ] || usage
REPO="$1"; AGENT_ID="$2"; POLL="$3"; DONE_FILE="$4"
MAX_WAIT="${5:-${MESH_MAX_WAIT_SEC:-240}}"
TASK_DEADLINE="${6:-}"
case "$POLL" in ""|*[!0123456789]*) usage ;; esac
case "$MAX_WAIT" in ""|*[!0123456789]*) usage ;; esac
case "$TASK_DEADLINE" in *[!0123456789]*) usage ;; esac
case "$DONE_FILE" in /*) ;; *) usage ;; esac
[ "$POLL" -gt 0 ] || POLL=60

WAIT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$WAIT_DIR/mesh-commit.sh"   # functions only: mc_heartbeat
MC_PARENT=$PPID
SECONDS=0
next_beat=0
while :; do
  [ -e "$DONE_FILE" ] && { echo DONE; exit 0; }
  if [ -n "$TASK_DEADLINE" ] && [ "$(date -u +%s)" -ge "$TASK_DEADLINE" ]; then
    echo TIMEOUT; exit 4
  fi
  if [ "$SECONDS" -ge "$next_beat" ]; then
    next_beat=$(( SECONDS + POLL ))
    mc_heartbeat || { [ $? -eq 3 ] && { echo WAITING; exit 5; }; }
    [ -e "$DONE_FILE" ] && { echo DONE; exit 0; }
  fi
  [ "$SECONDS" -lt "$MAX_WAIT" ] || { echo WAITING; exit 5; }
  nap=2
  [ $(( MAX_WAIT - SECONDS )) -lt "$nap" ] && nap=$(( MAX_WAIT - SECONDS ))
  [ "$nap" -gt 0 ] && sleep "$nap"
done
