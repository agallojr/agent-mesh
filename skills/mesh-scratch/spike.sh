#!/bin/sh
# spike.sh - save or end one spike in the mesh's scratch space.
# Writes only the outcome file (end); runs no git write. It prints each git
# command as a "RUN " line and the agent runs them in order, one call each.
#
#   spike.sh save <spike> [--root <scratch root>]
#   spike.sh end  <spike> (--filed <space id>/<record id> | --spawned proj:<name>
#                 | --abandoned) [--why <text>] [--root <scratch root>]
#
# Root defaults to <REPO_PATH>/spaces/tmp; REPO_PATH is the bus root, from the
# environment or ~/.agent-identity.env. A refusal prints
# "REFUSED <spike>: <reason>", writes nothing and exits 1.

refuse() {
  echo "REFUSED $spike: $1"
  exit 1
}

usage() {
  echo "usage: spike.sh save <spike> [--root <dir>]" >&2
  echo "       spike.sh end <spike> (--filed <space>/<record> |" \
    "--spawned proj:<name> | --abandoned) [--why <text>] [--root <dir>]" >&2
  exit 2
}

[ $# -ge 2 ] || usage
cmd=$1
spike=$2
shift 2
case $cmd in save | end) ;; *) usage ;; esac

root=
filed=
spawned=
abandoned=
why=
while [ $# -gt 0 ]; do
  case $1 in
    --root) [ $# -ge 2 ] || usage; root=$2; shift 2 ;;
    --filed) [ $# -ge 2 ] || usage; filed=$2; shift 2 ;;
    --spawned) [ $# -ge 2 ] || usage; spawned=$2; shift 2 ;;
    --abandoned) abandoned=1; shift ;;
    --why) [ $# -ge 2 ] || usage; why=$2; shift 2 ;;
    *) usage ;;
  esac
done

# bus root: environment first, then the identity file
bus=${REPO_PATH:-}
if [ -z "$bus" ] && [ -f "$HOME/.agent-identity.env" ]; then
  bus=$(sed -n 's/^REPO_PATH=//p' "$HOME/.agent-identity.env" | tail -n 1 |
    tr -d "\"'")
fi
[ -n "$root" ] || root=$bus/spaces/tmp
[ -n "$root" ] && [ "$root" != /spaces/tmp ] || {
  echo "spike.sh: no --root and no REPO_PATH" >&2
  exit 2
}

# a spike name matches [a-z0-9][a-z0-9._-]*
case $spike in
  '' | [!a-z0-9]* | *[!a-z0-9._-]*) refuse "not a spike name" ;;
esac
[ -d "$root/$spike" ] || refuse "no folder $spike in the scratch space"

if [ "$cmd" = save ]; then
  echo "RUN git -C $root add -- $spike"
  echo "RUN git -C $root commit -q -m \"Save spike $spike\" -- $spike"
  echo "RUN git -C $root pull --rebase -q origin main"
  echo "RUN git -C $root push -q origin HEAD:main"
  exit 0
fi

# end: exactly one outcome
n=0
[ -n "$filed" ] && n=$((n + 1))
[ -n "$spawned" ] && n=$((n + 1))
[ -n "$abandoned" ] && n=$((n + 1))
[ "$n" -eq 1 ] || usage

dirty=$(git -C "$root" status --porcelain -- "$spike") ||
  refuse "scratch root is not a git work tree"
[ -z "$dirty" ] ||
  refuse "untracked, modified or staged files in the folder, save first"
tracked=$(git -C "$root" ls-files -- "$spike") ||
  refuse "scratch root is not a git work tree"
[ -n "$tracked" ] || refuse "no tracked file in the folder, save first"

if [ -n "$filed" ]; then
  outcome=filed
  space=${filed%%/*}
  rec=${filed#*/}
  [ "$space" != "$filed" ] && [ -n "$space" ] && [ -n "$rec" ] ||
    refuse "--filed wants <space id>/<record id>"
  [ -f "$bus/spaces.yaml" ] || refuse "no spaces.yaml under the bus root"
  mpath=$(sed -n "s|^ *- *{ *id: *$space *,.*path: *\([^, }]*\).*|\1|p" \
    "$bus/spaces.yaml" | head -n 1)
  [ -n "$mpath" ] || refuse "space $space is not in spaces.yaml"
  found=
  for f in "$bus/$mpath/$rec"-* "$bus/$mpath"/*/"$rec"-*; do
    [ -f "$f" ] && found=1
  done
  if [ -z "$found" ] && [ -d "$bus/$mpath" ]; then
    hit=$(grep -rl --exclude-dir=.git "^id: *$rec\$" "$bus/$mpath" |
      head -n 1)
    [ -n "$hit" ] && found=1
  fi
  [ -n "$found" ] || refuse "record $rec not found in $space"
elif [ -n "$spawned" ]; then
  outcome=spawned
  case $spawned in
    proj:[a-z0-9]*) ;;
    *) refuse "--spawned wants proj:<name>" ;;
  esac
  case ${spawned#proj:} in
    *[!a-z0-9-]*) refuse "--spawned wants proj:<name>" ;;
  esac
else
  outcome=abandoned
fi

out=$root/$spike.outcome.md
{
  echo "---"
  echo "spike: $spike"
  echo "outcome: $outcome"
  echo "ended: $(date -u +%Y-%m-%dT%H:%MZ)"
  [ -n "$filed" ] && echo "filed_as: $filed"
  [ -n "$spawned" ] && echo "project: $spawned"
  echo "---"
  [ -n "$why" ] && echo "$why"
} >"$out"

echo "RUN git -C $root rm -r -q -- $spike"
echo "RUN git -C $root add -- $spike.outcome.md"
echo "RUN git -C $root commit -q -m \"End spike $spike: $outcome\"" \
  "-- $spike $spike.outcome.md"
echo "RUN git -C $root pull --rebase -q origin main"
echo "RUN git -C $root push -q origin HEAD:main"
