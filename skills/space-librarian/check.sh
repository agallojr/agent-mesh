: "${SPACE:?set SPACE to the space root}"
SPACE=${SPACE%/}
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
esc() { sed -e 's#[[\.*^$+?(){}|]#\\&#g'; }
val() { sed -n -E "s/^$1:[[:space:]]*\"?([^\"#[:space:]]+).*/\\1/p" "$2"; }

# Integrate mode: `--move <from> <to>` pairs come first, in the order the
# renames are made. Each path is then named as it will be after the moves,
# and the tracked files under each rename are checked too, under those names.
# A path is read where it is now: before the moves, at its old path.
TAB=$(printf '\t')
: > "$W/moves"
while [ "${1:-}" = --move ]; do
  if [ $# -lt 3 ]; then echo "--move needs <from> <to>" >&2; exit 2; fi
  a=${2#./}; a=${a%/}; b=${3#./}; b=${b%/}
  x=0; y=0; [ -e "$SPACE/$a" ] && x=1; [ -e "$SPACE/$b" ] && y=1
  if [ "$x" = "$y" ]; then echo "bad rename: $a $b" >&2; exit 2; fi
  printf '%s\t%s\n' "$a" "$b" >> "$W/moves"; shift 3
done
sed -n '1!G;h;$p' "$W/moves" > "$W/moves.rev"
fwd() {  # path $1 after the moves
  p=$1
  while IFS=$TAB read -r a b; do
    case "$p" in "$a") p=$b ;; "$a"/*) p=$b/${p#"$a"/} ;; esac
  done < "$W/moves"
  printf '%s\n' "$p"
}
old() {  # path $1 before the moves
  p=$1
  while IFS=$TAB read -r a b; do
    case "$p" in "$b") p=$a ;; "$b"/*) p=$a/${p#"$b"/} ;; esac
  done < "$W/moves.rev"
  printf '%s\n' "$p"
}

# The bus: given, else the space's superproject, else the node's REPO_PATH.
if [ -z "${BUS:-}" ]; then
  BUS=$(git -C "$SPACE" rev-parse --show-superproject-working-tree 2>/dev/null)
  [ -n "$BUS" ] && [ -d "$BUS/agents" ] || BUS=
  if [ -z "$BUS" ] && [ -f "$HOME/.agent-identity.env" ]; then
    BUS=$(sed -n -E 's/^REPO_PATH=["]?([^"#[:space:]]+).*/\1/p' \
      "$HOME/.agent-identity.env" | head -n 1)
  fi
fi
[ -n "$BUS" ] && [ -d "$BUS/agents" ] || BUS=

# profile: real values from the bus and the node, built at run time, in three
# lists by boundary: words (hostnames, credential key names), agents (agent
# ids and names, inbox names) and tids (mesh task ids).
: > "$W/words"; : > "$W/agents"; : > "$W/tids"; : > "$W/paths"
if [ -n "$BUS" ]; then
  for y in "$BUS"/agents/*.yaml; do
    [ -f "$y" ] || continue
    for k in agent_id agent_name; do val "$k" "$y"; done >> "$W/agents"
    val hostname "$y" >> "$W/words"
    val hostname "$y" | cut -d. -f1 >> "$W/words"
    sed -n -E 's/^credentials_available:[[:space:]]*\[(.*)\].*/\1/p' "$y" |
      tr ',' '\n' >> "$W/words"
    c=$(val cwd "$y" | sed -E 's#/+$##')
    case "$c" in
      /?*) printf '%s\n' "$c" "$(printf '%s\n' "$c" | cut -d/ -f1-3)" \
             >> "$W/paths" ;;
    esac
  done
  ls "$BUS/tasks" 2>/dev/null | grep -vE '^(roles|\..*)$' >> "$W/agents"
  find "$BUS/tasks" "$BUS/status" "$BUS/_archive" -type f 2>/dev/null |
    sed 's#.*/##' | grep -oE '[0-9]{8}T[0-9]{4}-[0-9]{4}' >> "$W/tids"
fi
for h in "$(hostname 2>/dev/null)" "$(uname -n 2>/dev/null)"; do
  printf '%s\n' "$h" "${h%%.*}"
done >> "$W/words"
if [ -f "$HOME/.agent-credentials.env" ]; then
  sed -n -E 's/^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' \
    "$HOME/.agent-credentials.env" >> "$W/words"
fi
case "$HOME" in /?*) printf '%s\n' "$HOME" >> "$W/paths" ;; esac
# A value matches as a whole word. In words, `-` and `_` are word characters,
# so a label inside a longer name passes. Agent ids and task ids end at any
# non-alphanumeric character, so `node-<agent id>` and the bus's own
# `<task id>-<slug>` names match, and a task id also ends at a letter.
pat() {  # list $1, left boundary class $2, right boundary class $3
  sed -E 's/^[[:space:]"]+//; s/[[:space:]"]+$//' "$W/$1" |
    grep -E '^.{3,}$' | grep -vE '^(null|~)$' | sort -u | esc |
    sed "s#.*#(^|[^$2])&([^$3]|\$)#"
}
{ pat words A-Za-z0-9_- A-Za-z0-9_-; pat agents A-Za-z0-9 A-Za-z0-9
  pat tids A-Za-z0-9 0-9; } > "$W/profile"
sed -E 's#/+$##' "$W/paths" | grep -E '^/.{2,}' | sort -u | esc |
  sed 's#.*#&([^A-Za-z0-9_.-]|$)#' >> "$W/profile"
printf '%s\n' '(^|[^A-Za-z0-9_.-])/(Users|home)/[A-Za-z0-9._-]+' >> "$W/profile"

# reference: this space's id and its may_reference list. The profile check
# is not run where header_profile is mesh (core, lore); a single-writer space
# also takes the counter id form.
SID=$(val id "$SPACE/space.yaml" | head -n 1)
PROF=$(val header_profile "$SPACE/space.yaml" | head -n 1)
WM=$(val writer_model "$SPACE/space.yaml" | head -n 1)
awk '/^may_reference:/ {
       s = $0; sub(/^may_reference:[ \t]*/, "", s); sub(/[ \t]*#.*$/, "", s)
       if (s != "") { gsub(/\[|\]|[ \t"]/, "", s); n = split(s, a, ",")
                      for (i = 1; i <= n; i++) if (a[i] != "") print a[i]; exit }
       blk = 1; next }
     blk && /^[ \t]*-/ { s = $0; sub(/^[ \t]*-[ \t]*/, "", s)
                         sub(/[ \t]*#.*$/, "", s); gsub(/"/, "", s); print s; next }
     blk { exit }' "$SPACE/space.yaml" > "$W/mayref"
# In core and in lore, a bare id also resolves in the other of the two, PEER,
# when the bus mounts it beside this space: at its spaces.yaml path, else
# spaces/<id>, with that id in its space.yaml.
PEER=
case "$SID" in core) o=lore ;; lore) o=core ;; *) o= ;; esac
if [ -n "$o" ] && [ -n "$BUS" ]; then
  pa=$(awk -v o="$o" '{ s = $0; sub(/[ \t]+#.*$/, "", s) }
    s ~ ("[{,][ \t]*id:[ \t]*\"?" o "\"?[ \t]*[,}]") &&
    match(s, /[{,][ \t]*path:[ \t]*[^,} \t]+/) {
      x = substr(s, RSTART, RLENGTH); sub(/.*path:[ \t]*/, "", x)
      gsub(/"/, "", x); print x; exit }' "$BUS/spaces.yaml" 2>/dev/null)
  d=$BUS/${pa:-spaces/$o}; d=${d%/}
  if [ -f "$d/space.yaml" ] && [ "$(val id "$d/space.yaml" | head -n 1)" = "$o" ]
  then
    sp=$(CDPATH= cd -P -- "$SPACE" && pwd); bp=$(CDPATH= cd -P -- "$BUS" && pwd)
    case "$sp" in "$bp"/*) PEER=$d ;; esac
  fi
fi
QID='(^|[^A-Za-z0-9_.:/-])(core|lore|tmp|lore:[a-z0-9][a-z0-9-]*'
QID="$QID"'|proj:[a-z0-9][a-z0-9-]*)'
QID="$QID"'/([a-z][a-z0-9]*-)?[0-9]{8}[A-Za-z0-9-]*(@[0-9a-f]+)?'
# scratch: in a shareable space, a citation of scratch fails the reference
# check: a path holding spaces/tmp/<name> or agent-tmp/<name>, a qualified id
# tmp/<...>, or the scratch repo's URL, with or without .git, from the bus's
# .gitmodules entry for spaces/tmp.
: > "$W/scratch"
if [ "$PROF" = shareable ]; then
  printf '%s\n' '(^|[^A-Za-z0-9_.-])(spaces/tmp|agent-tmp)/[A-Za-z0-9_]' \
    '(^|[^A-Za-z0-9_.:/-])tmp/[A-Za-z0-9_]' > "$W/scratch"
  if [ -n "$BUS" ] && [ -f "$BUS/.gitmodules" ]; then
    git config -f "$BUS/.gitmodules" --get-regexp '^submodule\..*\.path$' \
      2>/dev/null |
      while read -r k v; do
        [ "$v" = spaces/tmp ] || continue
        k=${k#submodule.}
        git config -f "$BUS/.gitmodules" --get "submodule.${k%.path}.url"
      done | sed -E 's#/+$##; s#\.git$##' | grep -E '^.{3,}$' | esc |
      sed 's#.*#&(\\.git)?([^A-Za-z0-9_-]|$)#' >> "$W/scratch"
  fi
fi

idof() {  # "<line> <id>" from a record's front-matter on stdin
  awk 'NR == 1 { if ($0 != "---") exit; next }
       $0 == "---" { exit }
       /^id:/ { x = $0; sub(/^id:[ \t]*/, "", x); sub(/[ \t]+#.*$/, "", x)
                gsub(/"/, "", x); print NR, x; exit }'
}
holders() {  # files in space root $2 (default this space) named by id $1,
             # or with id: $1
  find "${2:-$SPACE}" -name .git -prune -o -type f -name "$1*" -print
  find "${2:-$SPACE}" -name .git -prune -o -type f -name '*.md' \
    -exec grep -lE "^id:[[:space:]]*\"?$1\"?[[:space:]]*\$" {} +
}
others() {  # holders on stdin other than record $2, at space path $1; under
            # refs/, a stored artifact <stem>.<ext> beside it is no holder
  while IFS= read -r h; do
    [ "$h" = "$2" ] && continue
    case "$1" in refs/*)
      case "$h" in
        "${2%.md}".*.md) ;;
        "${2%.md}".*) [ "${h%/*}" = "${2%/*}" ] && continue ;;
      esac ;;
    esac
    printf '%s\n' "$h"
  done
}
chg() {  # the folder of change $1, live or archived
  if [ -d "$SPACE/changes/$1" ]; then echo "$SPACE/changes/$1"; return; fi
  for d in "$SPACE"/changes/archive/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-"$1"
  do [ -d "$d" ] && echo "$d" && return; done
}
resolve() {  # true if citation $1 resolves
  c=$1; bare=1
  case "$c" in *://*) return 0 ;; esac
  c=${c%%@*}
  case "$c" in
    core/*|lore/*|tmp/*|lore:*/*|proj:*/*)
      s=${c%%/*}; c=${c#*/}; bare=0
      if [ "$s" != "$SID" ]; then
        grep -qE "^$(printf '%s\n' "$s" | esc)\$" "$W/mayref"; return
      fi ;;
  esac
  if printf '%s\n' "$c" | grep -qE '^([a-z][a-z0-9]*-)?[0-9]{8}[A-Za-z0-9-]*$'
  then
    [ -n "$(holders "$c")" ] ||
      { [ "$bare" = 1 ] && [ -n "$PEER" ] && [ -n "$(holders "$c" "$PEER")" ]; }
    return
  fi
  if printf '%s\n' "$c" | grep -qE '^[a-z0-9][a-z0-9-]*/T[0-9]+$'; then
    t=${c##*/}; d=$(chg "${c%/*}")
    [ -n "$d" ] && grep -qE \
      "^(#+[[:space:]]+$t([[:space:]:]|\$)|\|[[:space:]]*$t[[:space:]]*\|)" \
      "$d/plan.md" 2>/dev/null
    return
  fi
  printf '%s\n' "$c" | grep -qE '^[a-z0-9][a-z0-9-]*$' && [ -n "$(chg "$c")" ]
}
text() {  # record $1, line for line: its body outside inline code and fenced
          # blocks; with $2 = 1, also the values of the front-matter
          # reference fields and source_path
  awk -v v="${2:-0}" 'NR == 1 && $0 == "---" { fm = 1; print ""; next }
       fm && $0 == "---" { fm = 0; print ""; next }
       fm && v && /^(related|supersedes|superseded_by|discovered_in|source_path):/ {
         x = $0; sub(/^[a-z_]+:/, "", x); sub(/[ \t]+#.*$/, "", x)
         blk = (x ~ /^[ \t]*$/); print x; next }
       fm && v && blk && /^[ \t]+-[ \t]/ {
         x = $0; sub(/[ \t]+#.*$/, "", x); print x; next }
       fm { blk = 0; print ""; next }
       /^[ \t]*(```|~~~)/ { fence = !fence; print ""; next }
       fence { print ""; next }
       /^[ \t]*$/ { code = 0 }
       { out = ""; s = $0
         while ((i = index(s, "`")) > 0) {
           if (!code) out = out substr(s, 1, i - 1)
           code = !code; s = substr(s, i + 1) }
         if (!code) out = out s
         print out }' "$1"
}
refs() {  # "<line> <citation>" for each citation in record $1
  awk 'function emit(x) { gsub(/^[ \t"]+|[ \t"]+$/, "", x)
                          if (x != "" && x != "null" && x != "~") print NR, x }
       NR == 1 { if ($0 != "---") exit; next }
       $0 == "---" { exit }
       /^(related|supersedes|superseded_by|discovered_in):/ {
         x = $0; sub(/^[a-z_]+:/, "", x); sub(/[ \t]+#.*$/, "", x)
         blk = (x ~ /^[ \t]*$/); gsub(/\[|\]/, "", x)
         n = split(x, a, ","); for (i = 1; i <= n; i++) emit(a[i]); next }
       blk && /^[ \t]+-[ \t]/ { x = $0; sub(/^[ \t]+-[ \t]+/, "", x)
                                sub(/[ \t]+#.*$/, "", x); emit(x); next }
       { blk = 0 }' "$1"
  text "$1" | grep -noE "$QID" | sed -E 's/^([0-9]+):[^a-z]?/\1 /'
}

BASE=HEAD
if git -C "$SPACE" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  BASE=origin/main
fi
# The paths: in integrate mode, the tracked files under each rename and the
# records, each once, in sorted order; otherwise the records as given.
: > "$W/todo"
if [ -s "$W/moves" ]; then
  while IFS=$TAB read -r a b; do
    git -c core.quotepath=off -C "$SPACE" ls-files -- "$a" "$b"
  done < "$W/moves" | while IFS= read -r p; do fwd "$p"; done > "$W/list"
  for r in "$@"; do printf '%s\n' "${r#./}"; done >> "$W/list"
  LC_ALL=C sort -u "$W/list" > "$W/todo"
else
  for r in "$@"; do printf '%s\n' "$r"; done > "$W/todo"
fi
while IFS= read -r r <&3; do
  r=${r#./}; f=$SPACE/$r
  [ -f "$f" ] || f=$SPACE/$(old "$r")
  if [ ! -f "$f" ]; then echo "no such record: $r" >&2; continue; fi
  # profile
  if [ "$PROF" != mesh ]; then
    n=$(grep -naE -f "$W/profile" "$f" | head -n 1 | cut -d: -f1)
    if [ -n "$n" ]; then echo "REFUSED $r: profile line $n"; continue; fi
  fi
  # Test fixtures are data, not records: the profile check only.
  case "$r" in
    changes/*/tests/fixtures/*|tests/*/fixtures/*) echo "CHECKED $r"; continue ;;
    *.md) ;;
    *) echo "CHECKED $r"; continue ;;
  esac
  # reference
  n=$(refs "$f" | sort -n | while read -r ln c; do
        resolve "$c" || { echo "$ln"; break; }
      done)
  if [ -s "$W/scratch" ]; then
    m=$(text "$f" 1 | grep -naE -f "$W/scratch" | head -n 1 | cut -d: -f1)
    if [ -n "$m" ] && { [ -z "$n" ] || [ "$m" -lt "$n" ]; }; then n=$m; fi
  fi
  if [ -n "$n" ]; then echo "REFUSED $r: reference line $n"; continue; fi
  # id
  x=$(idof < "$f"); n=${x%% *}; id=${x#* }
  if [ -z "$x" ]; then
    case "$r" in
      decisions/*.md|handoffs/*.md) id=$(basename "$r" .md); n=1 ;;
    esac
  fi
  if [ -n "$id" ]; then
    form='[a-z][a-z0-9]*-[0-9]{8}T[0-9]{4}Z-[0-9a-f]{4}'; ev=0
    [ "$WM" = single-writer ] && form="$form|[a-z][a-z0-9]*-[0-9]{8}-[0-9]{4}"
    case "$r" in
      changes/*/evidence/*) ev=1
        form="$form|ev-[0-9]{8}T[0-9]{4}Z(-T[0-9]+[a-z])?" ;;
      decisions/*|handoffs/*) ev=1
        form="$form|[0-9]{8}T[0-9]{4}Z-[a-z0-9][a-z0-9-]*" ;;
    esac
    # A moved record is compared with its old path: an id that moves with
    # it is neither new nor a duplicate.
    q=$(old "$r")
    git -C "$SPACE" cat-file -e "$BASE:$q" 2>/dev/null || q=$r
    if git -C "$SPACE" cat-file -e "$BASE:$q" 2>/dev/null; then
      if [ "$ev" = 1 ]; then
        if [ "$q" = "$r" ] && [ "$f" = "$SPACE/$r" ]; then
          git -C "$SPACE" diff --quiet "$BASE" -- "$r"
        else git -C "$SPACE" show "$BASE:$q" | cmp -s - "$f"; fi ||
          { echo "REFUSED $r: id line $n"; continue; }
        echo "CHECKED $r"; continue
      fi
      o=$(git -C "$SPACE" show "$BASE:$q" | idof)
      if [ "${o#* }" = "$id" ]; then echo "CHECKED $r"; continue; fi
    fi
    if ! printf '%s\n' "$id" | grep -qE "^($form)\$" ||
       [ -n "$(holders "$id" | others "$r" "$f")" ]
    then echo "REFUSED $r: id line $n"; continue; fi
  fi
  echo "CHECKED $r"
done 3< "$W/todo"
