#!/usr/bin/env bash
# run.sh -- agent-mesh unit suite. Runs every tests/unit/test_* file, prints
# "PASS <name>" or "FAIL <name>" per file and a last line "unit <p>/<n> pass",
# and exits 0 only when every file passes. A failing test's output goes to
# stderr, indented, so stdout carries only those lines.
#
# Each test builds its own throwaway repos under a temporary folder, with HOME
# pointed into it, and removes them; none touches a real bus or ~/.claude.
# Portable: bash 3.2+, macOS and Linux.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
pass=0
total=0
for t in "$HERE"/test_*; do
  [ -f "$t" ] || continue
  total=$((total + 1))
  name=$(basename "$t")
  case "$name" in
    *.py) runner="python3" ;;
    *)    runner="bash" ;;
  esac
  log=$(mktemp "${TMPDIR:-/tmp}/mesh-unit-log.XXXXXX")
  if "$runner" "$t" >"$log" 2>&1; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    sed 's/^/    /' "$log" >&2
  fi
  rm -f "$log"
done
echo "unit $pass/$total pass"
[ "$total" -gt 0 ] && [ "$pass" -eq "$total" ]
