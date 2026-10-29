#!/usr/bin/env bash
# mesh-model.sh -- how mesh-on spawns the poller and its executors on the model
# a node asks for, and the poller's start report (PROTOCOL 4.1; the mesh-on
# skill, step 5).
#
# A model setting (MESH_POLLER_MODEL, MESH_EXECUTOR_MODEL) is an alias (opus,
# sonnet, haiku or fable) or a full model id: claude- followed by lowercase
# letters, digits and -, such as claude-sonnet-5-5. The Agent tool's `model`
# parameter takes an alias only; an agent definition's `model:` takes an
# alias or a full id. So a full id is spawned as an agent definition,
# <config dir>/agents/mesh-<id>.md, whose model is that id.
#
# Usage:
#   mesh-model.sh spawn <poller|executor> [<value>]
#     alias    -> prints "model <alias>": pass model: <alias> on the Agent call
#     full id  -> writes the definition if it is not already as it should be,
#                 prints "agent mesh-<id>": pass subagent_type: mesh-<id> and
#                 no model on the Agent call; when it wrote the definition just
#                 now, a second line "NEW DEFINITION <path>" (restart the
#                 session once so Claude Code loads it); a link or other
#                 non-file at that path is REFUSED
#     unset    -> the poller's default, "model sonnet"; an executor needs a
#                 value (mesh-on passes the alias of its own session's model)
#     neither  -> prints "REFUSED <reason>", exit 1, writes nothing
#   mesh-model.sh report <requested> <running model id> [<notice text>]
#     prints "poller model: <running model id>", then exactly one line
#     "model fallback: requested <requested>, running <running model id>" when
#     the poller is not on the model asked for: the notice text holds Claude
#     Code's restriction notice for the requested model
#     (Model "<requested>" is restricted by your organization's settings. ...),
#     or the request is a full id and the running id is another model. With no
#     fallback there is no second line. An unset request is the default,
#     sonnet. A request that is neither alias nor id is REFUSED, exit 1.
# Exit status: 0, 1 for REFUSED, 2 for a usage error.
# The config dir is resolved as Claude Code resolves it: CLAUDE_CODE_CONFIG_DIR,
# else CLAUDE_CONFIG_DIR, else ~/.claude. Portable: bash 3.2+, POSIX sed/grep.
set -u

usage() {
  echo "usage: mesh-model.sh spawn <poller|executor> [<value>]" >&2
  echo "       mesh-model.sh report <requested> <running model id> [<notice text>]" >&2
  exit 2
}

kind() {  # kind <value>: alias, id or bad
  case "$1" in
    opus|sonnet|haiku|fable) echo alias; return ;;
  esac
  case "$1" in
    claude-?*)
      case "${1#claude-}" in
        *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) echo bad ;;
        *) echo id ;;
      esac ;;
    *) echo bad ;;
  esac
}

refuse_value() {
  printf 'REFUSED %s is neither an alias (opus, sonnet, haiku, fable) nor a full model id (claude- then lowercase letters, digits and -)\n' "'$1'"
  exit 1
}

spawn() {
  local role="$1" value="$2" dir name file tmp new
  case "$role" in poller|executor) ;; *) usage ;; esac
  if [ -z "$value" ]; then
    [ "$role" = poller ] || { echo "REFUSED no executor model given"; exit 1; }
    value=sonnet
  fi
  case "$(kind "$value")" in
    alias) echo "model $value"; return 0 ;;
    bad) refuse_value "$value" ;;
  esac
  dir="${CLAUDE_CODE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/agents"
  name="mesh-$value"
  file="$dir/$name.md"
  mkdir -p "$dir" || { echo "REFUSED cannot make $dir"; exit 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/mesh-model.XXXXXX") || { echo "REFUSED no temp file"; exit 1; }
  cat > "$tmp" <<EOF
---
name: $name
description: A mesh poller or executor pinned to $value. Spawned by the mesh-on skill only.
model: $value
---
You are an agent of a git-coordinated agent mesh, spawned by the mesh-on
skill as its poller or as an executor of one task. The prompt you are given
holds your complete instructions; follow them exactly.
EOF
  if [ -L "$file" ] || { [ -e "$file" ] && [ ! -f "$file" ]; }; then
    rm -f "$tmp"; echo "REFUSED $file is a link or not a plain file"; exit 1
  fi
  new=""
  if [ -f "$file" ] && cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
  else
    cat "$tmp" > "$file" && rm -f "$tmp" || { rm -f "$tmp"; echo "REFUSED cannot write $file"; exit 1; }
    new=1
  fi
  echo "agent $name"
  # Claude Code loads agent definitions at session start: a definition just
  # written may not be loaded until the session restarts.
  [ -z "$new" ] || echo "NEW DEFINITION $file"
}

report() {
  local req="$1" run="$2" notice="$3" base
  [ -n "$run" ] || usage
  [ -n "$req" ] || req=sonnet
  [ "$(kind "$req")" != bad ] || refuse_value "$req"
  echo "poller model: $run"
  base="${run%%\[*}"
  if printf '%s\n' "$notice" | grep -qF "Model \"$req\" is restricted by your organization's settings."; then
    echo "model fallback: requested $req, running $run"
  elif [ "$(kind "$req")" = id ] && [ "$base" != "$req" ]; then
    echo "model fallback: requested $req, running $run"
  fi
  return 0
}

[ $# -ge 1 ] || usage
case "$1" in
  spawn)  [ $# -ge 2 ] && [ $# -le 3 ] || usage; spawn "$2" "${3-}" ;;
  report) [ $# -ge 3 ] && [ $# -le 4 ] || usage; report "$2" "$3" "${4-}" ;;
  *) usage ;;
esac
