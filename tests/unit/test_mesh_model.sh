#!/usr/bin/env bash
# Unit test of skills/mesh-on/mesh-model.sh (plan sections 2.1 and 2.6, R3):
# an alias and a full model id each map to the way the poller or an executor
# is spawned on that model; a value that is neither is refused; the
# organization's restriction notice for the requested model gives exactly one
# "model fallback:" line naming the model used, and no notice gives none.
set -u
. "$(dirname "$0")/lib.sh"
unit_setup
MM="$SKILLS/mesh-on/mesh-model.sh"
AG="$CLAUDE_CONFIG_DIR/agents"

# --- spawn: an alias is passed as the Agent tool's model
for a in opus sonnet haiku fable; do
  out=$(bash "$MM" spawn poller "$a"); rc=$?
  check "poller alias $a spawns with model $a" eq "$rc:$out" "0:model $a"
  out=$(bash "$MM" spawn executor "$a"); rc=$?
  check "executor alias $a spawns with model $a" eq "$rc:$out" "0:model $a"
done
check "an alias writes no agent definition" test ! -d "$AG"
out=$(bash "$MM" spawn poller ""); rc=$?
check "an unset poller model is the sonnet default" eq "$rc:$out" "0:model sonnet"

# --- spawn: a full id is an agent definition whose model is that id
out=$(bash "$MM" spawn poller claude-sonnet-5-5); rc=$?
D="$AG/mesh-claude-sonnet-5-5.md"
check "a full poller id spawns as its agent definition, new this time" \
  eq "$rc:$out" "0:$(printf 'agent mesh-claude-sonnet-5-5\nNEW DEFINITION %s' "$D")"
check "the definition file exists" test -f "$D"
check "the definition names itself" grep -qx 'name: mesh-claude-sonnet-5-5' "$D"
check "the definition pins the model id" grep -qx 'model: claude-sonnet-5-5' "$D"
check "the definition has front matter" eq "$(sed -n 1p "$D")" "---"
check "the definition sets no tools line (it inherits the tools)" \
  eq "$(grep -c '^tools:' "$D")" 0
before=$(cksum < "$D")
out=$(bash "$MM" spawn executor claude-sonnet-5-5); rc=$?
check "the same id again spawns as the same definition, not new" \
  eq "$rc:$out" "0:agent mesh-claude-sonnet-5-5"
check "a second spawn leaves the definition as it was" eq "$(cksum < "$D")" "$before"
out=$(bash "$MM" spawn executor claude-opus-5-5); rc=$?
check "a full executor id spawns as its own definition" \
  eq "$rc:$(printf '%s\n' "$out" | sed -n 1p):$(sed -n 's/^model: //p' "$AG/mesh-claude-opus-5-5.md")" \
  "0:agent mesh-claude-opus-5-5:claude-opus-5-5"
ln -s "$T/elsewhere.md" "$AG/mesh-claude-fable-5-1.md"
out=$(bash "$MM" spawn executor claude-fable-5-1); rc=$?
check "a link at the definition path is refused" eq "$rc:${out%% *}" "1:REFUSED"
check "and nothing is written through it" test ! -e "$T/elsewhere.md"
rm -f "$AG/mesh-claude-fable-5-1.md"
out=$(env -u CLAUDE_CONFIG_DIR CLAUDE_CODE_CONFIG_DIR="$T/cfg2" bash "$MM" spawn poller claude-haiku-5-5); rc=$?
check "the definition goes to the config dir Claude Code uses" \
  test "$rc:$(printf '%s\n' "$out" | sed -n 1p)" = "0:agent mesh-claude-haiku-5-5" -a -f "$T/cfg2/agents/mesh-claude-haiku-5-5.md"

# --- spawn: a value that is neither is refused, and writes nothing
n=$(ls "$AG" | wc -l | tr -d ' ')
for bad in gpt-4 Sonnet Claude-sonnet-5-5 claude- "claude-sonnet 5" claude_sonnet \
           "claude-sonnet-5-5[1m]" ../claude-x claude-x/y "opus;sonnet" claude-ÄB; do
  out=$(bash "$MM" spawn poller "$bad"); rc=$?
  check "'$bad' is refused" eq "$rc:${out%% *}" "1:REFUSED"
done
check "a refused value writes no definition" eq "$(ls "$AG" | wc -l | tr -d ' ')" "$n"
out=$(bash "$MM" spawn executor ""); rc=$?
check "an executor needs a model value" eq "$rc:${out%% *}" "1:REFUSED"
bash "$MM" spawn other sonnet >/dev/null 2>&1; rc=$?
check "an unknown role is a usage error" eq "$rc" 2
bash "$MM" >/dev/null 2>&1; rc=$?
check "no arguments is a usage error" eq "$rc" 2

# --- report: the start report lines
NOTICE='Model "sonnet" is restricted by your organization'"'"'s settings. Using claude-sonnet-5-5 instead.'
out=$(bash "$MM" report sonnet claude-sonnet-5-5); rc=$?
check "an alias with no notice: one poller model line, no fallback" \
  eq "$rc:$out" "0:poller model: claude-sonnet-5-5"
out=$(bash "$MM" report sonnet claude-sonnet-5-5 "$NOTICE"); rc=$?
check "the restriction notice for the requested alias gives one fallback line" \
  eq "$rc:$out" "0:$(printf 'poller model: claude-sonnet-5-5\nmodel fallback: requested sonnet, running claude-sonnet-5-5')"
out=$(bash "$MM" report sonnet claude-sonnet-5-5 "$(printf '%s\nother text\n%s' "$NOTICE" "$NOTICE")")
check "a notice shown twice still gives exactly one fallback line" \
  eq "$(printf '%s\n' "$out" | grep -c '^model fallback: ')" 1
FNOTE='Model "fable" is restricted by your organization'"'"'s settings. Using claude-opus-5-5 instead.'
out=$(bash "$MM" report sonnet claude-sonnet-5-5 "$FNOTE")
check "a notice for another model gives no fallback line" \
  eq "$out" "poller model: claude-sonnet-5-5"
out=$(bash "$MM" report claude-sonnet-5-5 claude-sonnet-5-5); rc=$?
check "a full id that runs as asked gives no fallback line" \
  eq "$rc:$out" "0:poller model: claude-sonnet-5-5"
out=$(bash "$MM" report claude-sonnet-5-5 "claude-sonnet-5-5[1m]")
check "a context-size tag on the running id is not a fallback" \
  eq "$out" "poller model: claude-sonnet-5-5[1m]"
out=$(bash "$MM" report claude-sonnet-5-5 claude-haiku-5-5)
check "a full id that runs on another model gives one fallback line" \
  eq "$out" "$(printf 'poller model: claude-haiku-5-5\nmodel fallback: requested claude-sonnet-5-5, running claude-haiku-5-5')"
out=$(bash "$MM" report "" claude-sonnet-5-5 "$NOTICE")
check "an unset request is the sonnet default" \
  eq "$out" "$(printf 'poller model: claude-sonnet-5-5\nmodel fallback: requested sonnet, running claude-sonnet-5-5')"
bash "$MM" report sonnet "" >/dev/null 2>&1; rc=$?
check "no running id is a usage error" eq "$rc" 2
out=$(bash "$MM" report gpt-4 claude-sonnet-5-5); rc=$?
check "a request that is neither is refused" eq "$rc:${out%% *}" "1:REFUSED"

unit_done
