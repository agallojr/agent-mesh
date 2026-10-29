#!/usr/bin/env bash
# mesh-stale.sh -- name the nodes that have stopped polling, and the tasks
# they hold. Read-only. mesh-check runs it after its pull and reports its
# lines verbatim, first, under "Nodes not polling".
#
# Usage: mesh-stale.sh <REPO> [--now <YYYY-MM-DDTHH:MM:SSZ>]
#   --now defaults to the current UTC time.
#
# For each <REPO>/agents/*.yaml, with interval its poll_interval_sec (60 s
# when absent) and age the whole s from its last_poll to now:
#   age > 3 * interval:
#     NOT POLLING <agent_id> <agent_name>: last poll <age> s ago at
#       <last_poll>, interval <interval> s; holds <held>      (one line)
#   no last_poll (or one not of the form above):
#     NO LAST POLL <agent_id> <agent_name>; holds <held>
#   otherwise nothing for that node.
# <held> is "<task id> <state>" for each <REPO>/status/*.json whose agent_id
# is the node's and whose state is accepted or running, joined by ", ", in
# task id order; or "nothing". A node's poller rewrites last_poll once per
# poll interval while it is live, an executor's run included, so an old
# last_poll means the poller stopped (PROTOCOL 4.3).
# Exit status: 0, or 2 for a usage error.
# Portable: bash 3.2+, POSIX sed and awk; no GNU or BSD date flags.
set -u

usage() {
  echo "usage: mesh-stale.sh <REPO> [--now <YYYY-MM-DDTHH:MM:SSZ>]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
REPO="$1"; shift
NOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --now) [ $# -ge 2 ] || usage; NOW="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -d "$REPO" ] || usage

D='[0123456789]'
is_utc() {  # YYYY-MM-DDTHH:MM:SSZ
  case "$1" in
    $D$D$D$D-$D$D-$D${D}T$D$D:$D$D:$D${D}Z) return 0 ;;
  esac
  return 1
}
[ -n "$NOW" ] || NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
is_utc "$NOW" || usage

epoch() {  # whole s since 1970-01-01T00:00:00Z, no date(1) flavor needed
  printf '%s\n' "$1" | awk -F'[-T:Z]' '
    function days(y, m, d,   era, yoe, doy, doe) {
      y -= (m <= 2)
      era = int((y >= 0 ? y : y - 399) / 400)
      yoe = y - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe - 719468
    }
    { printf "%d\n", days($1 + 0, $2 + 0, $3 + 0) * 86400 + $4 * 3600 + $5 * 60 + $6 }'
}

yv() {  # yv <key> <file>: first value, comment and quotes off
  sed -n "s/^$1:[[:space:]]*//p" "$2" | head -1 \
    | sed -e 's/[[:space:]][[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

jv() {  # jv <key> <file>: a JSON string value, the file read as one line
  tr '\n' ' ' < "$2" \
    | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# Every held task once: "<task id> <state> <agent id>", in task id order.
# (A function, not inline: bash 3.2 misparses a case inside $(...).)
collect_held() {
  local f st tid
  for f in "$REPO"/status/*.json; do
    [ -f "$f" ] || continue
    st=$(jv state "$f")
    case "$st" in accepted|running) ;; *) continue ;; esac
    tid=$(basename "$f" .json)
    printf '%s %s %s\n' "$tid" "$st" "$(jv agent_id "$f")"
  done | LC_ALL=C sort
}
HELD=$(collect_held)

held_by() {  # held_by <agent id>
  local h
  h=$(printf '%s\n' "$HELD" | awk -v a="$1" '
    $3 == a { out = out (out == "" ? "" : ", ") $1 " " $2 }
    END { print out }')
  [ -n "$h" ] || h="nothing"
  printf '%s\n' "$h"
}

NOW_S=$(epoch "$NOW")
for f in "$REPO"/agents/*.yaml; do
  [ -f "$f" ] || continue
  id=$(yv agent_id "$f")
  [ -n "$id" ] || id=$(basename "$f" .yaml)
  name=$(yv agent_name "$f")
  interval=$(yv poll_interval_sec "$f")
  case "$interval" in ""|0|*[!0123456789]*) interval=60 ;; esac
  last=$(yv last_poll "$f")
  if ! is_utc "$last"; then
    echo "NO LAST POLL $id $name; holds $(held_by "$id")"
    continue
  fi
  age=$(( NOW_S - $(epoch "$last") ))
  if [ "$age" -gt $(( 3 * interval )) ]; then
    echo "NOT POLLING $id $name: last poll $age s ago at $last, interval $interval s; holds $(held_by "$id")"
  fi
done
exit 0
