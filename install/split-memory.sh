#!/usr/bin/env bash
#
# split-memory.sh -- move a bus's library and scratch into three spaces.
#
#   names    print the repo names of a mesh, by the naming rule
#   split    make the core, lore and scratch repos in a work folder, from a
#            fresh clone of the bus's origin; it only reads the bus
#   publish  push the three repos to new, empty remotes
#   mount    in a bus clone, swap the library and scratch for the three
#            space submodules and the compatibility links; it stages all of
#            it and commits nothing
#
# Core gets the bus's notes, refs, runs, workflows and the overlay
# best-practices.user.md, and lore gets its lore, each with its history
# (git-filter-repo, the leading memory/ dropped from each path). Scratch
# starts from agent-tmp/ at the bus's origin/main, without history. Each
# outward step is the operator's: publish, and the commit and push that mount
# prints as RUN lines.
#
# Refusals beside the main ones: REFUSED fetch (split: no origin/main),
# REFUSED keep <folder>: <why> (split: not a spike name, also left, no
# untracked file, holds a git repo), REFUSED readiness this node (no
# AGENT_CONTEXT), REFUSED readiness <class>: not a class name (split: a class
# that would name a report outside --readiness), UNMAPPED agent-tmp/<file>
# (split: a scratch file that the root files of tmp would replace), LEFTOVER
# for a tracked file changed under memory/ or agent-tmp/ (mount), REFUSED
# mount: spaces.yaml ... (mount: a spaces: line holding a value other than an
# empty list, so that no entry can be appended under it), and UNSPLIT <path>
# (mount: a bus file that its space's main lacks, as when the library moved
# on after the split).
#
# Bash 3.2 or later, git and Git LFS; split also needs git-filter-repo. Run it
# from an agent-mesh checkout: split reads templates/spaces/ from it. It never
# prints a credential: a URL is shown without its user info.
#
# Exit: 0 done; 1 a git step failed; 2 usage; 3 refused on readiness or a
# tool; 4 refused on the bus, the work folder or a remote; 5 verify mismatch.

set -u
set -o pipefail
export LC_ALL=C

NL='
'
Q="'"
AT=agent-tmp            # the bus's scratch folder; a link once mounted
TMPM=spaces/tmp         # where the bus mounts scratch
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
TPL=$HERE/templates/spaces
# The seven links of a mounted bus: path, then target.
LINKS="memory/lore ../spaces/lore/lore
memory/notes ../spaces/core/notes
memory/refs ../spaces/core/refs
memory/runs ../spaces/core/runs
memory/workflows ../spaces/core/workflows
memory/best-practices.user.md ../spaces/core/best-practices.user.md
$AT $TMPM"
OVERLAY_OLD=@../memory/best-practices.user.md
OVERLAY=@../spaces/core/best-practices.user.md
BASE_IMPORT=@../product/guidance/best-practices.base.md

usage() {
  cat <<'EOF'
Usage:
  split-memory.sh names   --owner <owner> --mesh <mesh>
  split-memory.sh split   --bus <bus clone> --work <dir> --owner <owner>
                          --mesh <mesh> --readiness <dir>
                          [--set-aside <class>]...
                          [--keep <folder>]... [--leave <folder>]...
  split-memory.sh publish --work <dir> --core-url <url> --lore-url <url>
                          --tmp-url <url>
  split-memory.sh mount   --bus <bus clone> --core-url <url> --lore-url <url>
                          --tmp-url <url> [--carry-ignored]
EOF
}

SCR=$(mktemp -d "${TMPDIR:-/tmp}/split-memory.XXXXXX") || exit 1
trap 'rm -rf "$SCR"' EXIT
LOG=$SCR/log
: > "$LOG"

die2() { printf 'split-memory.sh: %s\n' "$1" >&2; usage >&2; exit 2; }
redact() { sed -E 's#(://)[^/@[:space:]]*@#\1#g'; }
show_url() { printf '%s\n' "$1" | redact; }
fail() {
  printf 'ERROR %s\n' "$1" >&2
  tail -n 20 "$LOG" | redact >&2
  exit 1
}
must() {  # description, command...: run it quietly, or fail
  local d=$1; shift
  "$@" >>"$LOG" 2>&1 </dev/null || fail "$d"
}
inlist() {  # item list: true if the newline-ended list holds the item
  case $NL$2 in *"$NL$1$NL"*) return 0 ;; esac
  return 1
}
name_ok() { case $1 in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
spike_ok() { case $1 in ''|[!a-z0-9]*|*[!a-z0-9._-]*) return 1 ;; esac; }
url_of() {
  case $1 in
    core) printf '%s' "$CORE_URL" ;;
    lore) printf '%s' "$LORE_URL" ;;
    tmp) printf '%s' "$TMP_URL" ;;
  esac
}
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
  else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# Reads `git cat-file --batch` output. m=lfs prints the oid of each blob that
# is an LFS pointer; m=id prints the front-matter id: of each blob. Its input
# has each NUL byte mapped to \001 first: an awk that ends a string at a NUL
# would count a line short, and the parse would lose its place.
BLOBS='
need == 0 {
  if ($2 == "missing") next
  need = $3 + 1; got = 0; n = 0; ptr = 0; fm = 0; oid = ""; next
}
{
  got += length($0) + 1; n++; s = $0; sub(/\r$/, "", s)
  if (m == "lfs") {
    if (n == 1) ptr = (s == "version https://git-lfs.github.com/spec/v1")
    else if (ptr && s ~ /^oid sha256:[0-9a-f]+$/ && length(s) == 75)
      oid = substr(s, 12)
  } else if (n == 1) {
    fm = (s == "---")
  } else if (fm) {
    if (s == "---") fm = 0
    else if (s ~ /^id:/) {
      sub(/^id:[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); gsub(/["\047]/, "", s)
      sub(/[ \t]+$/, "", s); if (s != "") print s; fm = 0
    }
  }
  if (got >= need) { if (oid != "") print oid; need = 0 }
}'

lfs_oids() {  # repo rev: the LFS oids that the history of rev references
  git -C "$1" rev-list --objects "$2" > "$SCR/objs" || return 1
  cut -d' ' -f1 "$SCR/objs" |
    git -C "$1" cat-file \
      --batch-check='%(objectname) %(objecttype) %(objectsize)' |
    awk '$2 == "blob" && $3 < 1024 { print $1 }' |
    git -C "$1" cat-file --batch | tr '\000' '\001' |
    awk -v m=lfs "$BLOBS" | sort -u
}

ids_at() {  # repo rev [path]...: the front-matter ids of the *.md files
  local r=$1 v=$2; shift 2
  git -C "$r" ls-tree -r -z "$v" -- "$@" | tr '\0' '\n' |
    awk -F '\t' '$2 ~ /\.md$/ { split($1, a, " ")
      if (a[2] == "blob") print a[3] }' |
    git -C "$r" cat-file --batch | tr '\000' '\001' |
    awk -v m=id "$BLOBS" | sort -u
}

media() {  # repo: its local LFS store
  local d
  d=$(git -C "$1" lfs env 2>/dev/null | sed -n 's/^LocalMediaDir=//p' |
    sed -n 1p)
  [ -n "$d" ] || d=$(git -C "$1" rev-parse --absolute-git-dir)/lfs/objects
  printf '%s\n' "$d"
}

lfs_bad() {  # repo oid-file: how many oids are absent or wrong in the store
  local md b=0 o f
  md=$(media "$1")
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    f=$md/${o:0:2}/${o:2:2}/$o
    if [ ! -f "$f" ] || [ "$(sha256 "$f")" != "$o" ]; then b=$((b + 1)); fi
  done < "$2"
  echo "$b"
}

count() { wc -l < "$1" | tr -d ' '; }

# Git LFS and its pre-push hook take a remote name, and a bare local path
# is no URL to them, so each LFS transfer and push goes through a remote of
# its own, split-memory, removed once the transfer ends.
remote_on() {  # repo url
  git -C "$1" remote remove split-memory >/dev/null 2>&1
  git -C "$1" remote add split-memory "$2"
}
remote_off() { git -C "$1" remote remove split-memory >/dev/null 2>&1; }
lfs_at() {  # repo url lfs-subcommand [option]...
  local r=$1 u=$2 rc; shift 2
  remote_on "$r" "$u" || return 1
  git -C "$r" lfs "$@" split-memory; rc=$?
  remote_off "$r"
  return $rc
}

bus_root() {  # make BUS the absolute path of a bus clone's top
  local b top
  [ -d "$BUS" ] || die2 "no such bus clone: $BUS"
  b=$(cd "$BUS" && pwd) || die2 "cannot enter $BUS"
  top=$(git -C "$b" rev-parse --show-toplevel 2>/dev/null) ||
    die2 "not a git work tree: $BUS"
  [ "$(cd "$top" && pwd -P)" = "$(cd "$b" && pwd -P)" ] ||
    die2 "not the top of its repo: $BUS"
  BUS=$b
}

# --- arguments --------------------------------------------------------------
CMD=${1:-}
[ $# -gt 0 ] && shift
case $CMD in
  names|split|publish|mount) ;;
  -h|--help|help) usage; exit 0 ;;
  *) die2 "unknown subcommand: ${CMD:-none}" ;;
esac
BUS= WORK= OWNER= MESH= READINESS= HAVE_READINESS=0 ASIDE= KEEP= LEAVE=
CORE_URL= LORE_URL= TMP_URL= CARRY=0
takes() {
  case $CMD:$1 in
    names:--owner|names:--mesh) return 0 ;;
    split:--bus|split:--work|split:--owner|split:--mesh) return 0 ;;
    split:--readiness|split:--set-aside|split:--keep|split:--leave) return 0 ;;
    publish:--work|publish:--core-url|publish:--lore-url) return 0 ;;
    publish:--tmp-url) return 0 ;;
    mount:--bus|mount:--core-url|mount:--lore-url|mount:--tmp-url) return 0 ;;
    mount:--carry-ignored) return 0 ;;
  esac
  return 1
}
while [ $# -gt 0 ]; do
  o=$1
  case $o in -h|--help) usage; exit 0 ;; esac
  takes "$o" || die2 "$CMD does not take $o"
  if [ "$o" = --carry-ignored ]; then CARRY=1; shift; continue; fi
  [ $# -ge 2 ] || die2 "$o needs a value"
  v=$2; shift 2
  case $o in
    --bus) BUS=$v ;;
    --work) WORK=$v ;;
    --owner) OWNER=$v ;;
    --mesh) MESH=$v ;;
    --readiness) READINESS=$v; HAVE_READINESS=1 ;;
    --set-aside) ASIDE=$ASIDE$v$NL ;;
    --keep) inlist "$v" "$KEEP" || KEEP=$KEEP$v$NL ;;
    --leave) LEAVE=$LEAVE$v$NL ;;
    --core-url) CORE_URL=$v ;;
    --lore-url) LORE_URL=$v ;;
    --tmp-url) TMP_URL=$v ;;
  esac
done
req() { [ -n "$1" ] || die2 "$CMD needs $2"; }

# --- names ------------------------------------------------------------------
cmd_names() {
  req "$OWNER" --owner; req "$MESH" --mesh
  name_ok "$OWNER" || die2 "not a name: $OWNER"
  name_ok "$MESH" || die2 "not a name: $MESH"
  printf 'bus agent-mesh-%s\n' "$MESH"
  printf 'tmp agent-mesh-%s-tmp\n' "$MESH"
  printf 'core %s-core\n' "$OWNER"
  printf 'lore %s-lore\n' "$OWNER"
}

# --- split: the five checks -------------------------------------------------
node_class() {  # AGENT_CONTEXT in ~/.agent-identity.env
  local f=$HOME/.agent-identity.env x
  [ -f "$f" ] || return 0
  x="s/^(export[[:space:]]+)?AGENT_CONTEXT=[\"$Q]?([^\"$Q#[:space:]]*).*/\\2/p"
  sed -n -E "$x" "$f" | tail -n 1
}

classes() {  # the distinct context: of the bus's registered agents
  local y
  for y in "$BUS"/agents/*.yaml; do
    [ -f "$y" ] || continue
    sed -n -E "s/^context:[[:space:]]*[\"$Q]?([^\"$Q#[:space:]]+).*/\\1/p" \
      "$y" | sed -n 1p
  done | sort -u
}

has_filter_repo() {  # report class: true if it holds OK <class> filter-repo
  tr -d '\r' < "$1" |
    awk -v c="$2" '$1 == "OK" && $2 == c && $3 == "filter-repo" { f = 1 }
                   END { exit !f }'
}

check_readiness() {
  local bad=0 seen= c f l st
  THIS=$(node_class)
  REG=$(classes)$NL
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    inlist "$c" "$seen" && continue
    seen=$seen$c$NL
    if ! inlist "$c" "$REG"; then
      echo "REFUSED set-aside $c: not registered"; bad=1
    elif [ "$c" = "$THIS" ]; then
      echo "REFUSED set-aside $c: this node"; bad=1
    else
      echo "SET-ASIDE $c: left out by the operator"
    fi
  done <<EOF
$ASIDE
EOF
  [ "$bad" = 0 ] || exit 3
  ASIDE=$seen
  if [ -z "$THIS" ]; then
    echo "REFUSED readiness this node: no AGENT_CONTEXT"; exit 3
  fi
  # A class's report is <readiness>/<class>.txt. No such file is missing; a
  # file whose last line that is not blank, a trailing carriage return
  # dropped, is not READY <class> is not ready. This node's report must
  # also hold its OK <class> filter-repo line.
  printf '%s\n%s\n' "$REG" "$THIS" | grep -v '^$' | sort -u > "$SCR/need"
  while IFS= read -r c; do
    inlist "$c" "$ASIDE" && continue
    f=$READINESS/$c.txt
    if ! name_ok "$c"; then
      st="not a class name"
    elif [ -z "$READINESS" ] || [ ! -f "$f" ]; then
      st=missing
    else
      l=$(awk '{ sub(/\r$/, "") } NF { x = $0 } END { print x }' "$f")
      if [ "$l" != "READY $c" ]; then
        st="not ready"
      elif [ "$c" = "$THIS" ] && ! has_filter_repo "$f" "$c"; then
        st="not ready"
      else
        st=ok
      fi
    fi
    if [ "$st" != ok ]; then echo "REFUSED readiness $c: $st"; bad=1; fi
  done < "$SCR/need"
  [ "$bad" = 0 ] || exit 3
}

check_clean() {
  local n m
  git --version >/dev/null 2>&1 || { echo "REFUSED tool git"; exit 3; }
  if ! git -C "$BUS" fetch -q --no-recurse-submodules origin >>"$LOG" 2>&1 ||
     ! SHA=$(git -C "$BUS" rev-parse -q --verify \
       'refs/remotes/origin/main^{commit}'); then
    echo "REFUSED fetch: no origin/main"; exit 4
  fi
  SHA7=${SHA:0:7}
  git -C "$BUS" status --porcelain --untracked-files=all -- memory \
    > "$SCR/st" 2>>"$LOG" || fail "status of memory/"
  n=$(count "$SCR/st")
  m=$(git -C "$BUS" rev-list --count HEAD --not "$SHA" -- memory "$AT") ||
    fail "list unpushed commits"
  if [ "$n" != 0 ] || [ "$m" != 0 ]; then
    echo "REFUSED unclean memory/: $n uncommitted, $m unpushed"; exit 4
  fi
}

check_mapped() {
  local bad=0 p t x
  git -C "$BUS" ls-tree -r -z --name-only "$SHA" -- memory > "$SCR/mem.z" ||
    fail "list memory/ at origin/main"
  tr '\0' '\n' < "$SCR/mem.z" > "$SCR/mem"
  while IFS= read -r p; do
    case $p in
      memory/lore/*|memory/notes/*|memory/refs/*|memory/runs/*) ;;
      memory/workflows/*|memory/best-practices.user.md) ;;
      *) echo "UNMAPPED $p"; bad=1 ;;
    esac
  done < "$SCR/mem"
  # Scratch's own top-level files would collide with the ones the split
  # writes at tmp's root, before the split as after it.
  t=$(git -C "$BUS" cat-file -t "$SHA:$AT" 2>/dev/null)
  if [ -n "$t" ] && [ "$t" != tree ]; then
    echo "UNMAPPED $AT"; bad=1
  elif [ "$t" = tree ]; then
    for x in .gitattributes .gitignore space.yaml; do
      if git -C "$BUS" cat-file -e "$SHA:$AT/$x" 2>/dev/null; then
        echo "UNMAPPED $AT/$x"; bad=1
      fi
    done
  fi
  [ "$bad" = 0 ] || exit 4
}

check_decided() {
  local bad=0 f k
  : > "$SCR/untracked"
  if [ -d "$BUS/$AT" ] && [ ! -L "$BUS/$AT" ]; then
    git -C "$BUS" ls-files -z --others --exclude-standard -- "$AT/" \
      > "$SCR/u.z" || fail "list untracked scratch"
    tr '\0' '\n' < "$SCR/u.z" > "$SCR/untracked"
  fi
  sed -n "s#^$AT/\\([^/]*\\).*#\\1#p" "$SCR/untracked" | sort -u \
    > "$SCR/folders"
  while IFS= read -r f; do
    inlist "$f" "$KEEP" || inlist "$f" "$LEAVE" ||
      { echo "UNDECIDED $AT/$f"; bad=1; }
  done < "$SCR/folders"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if ! spike_ok "$k"; then
      echo "REFUSED keep $AT/$k: not a spike name"; bad=1
    elif inlist "$k" "$LEAVE"; then
      echo "REFUSED keep $AT/$k: also left"; bad=1
    elif ! grep -qxF -- "$k" "$SCR/folders"; then
      echo "REFUSED keep $AT/$k: no untracked file"; bad=1
    elif awk -v p="$AT/$k/" 'index($0, p) == 1 && /\/$/ { f = 1 }
                             END { exit !f }' "$SCR/untracked"; then
      echo "REFUSED keep $AT/$k: holds a git repo"; bad=1
    fi
  done <<EOF
$KEEP
EOF
  [ "$bad" = 0 ] || exit 4
}

check_tools() {
  local bad=0
  git --version >/dev/null 2>&1 || { echo "REFUSED tool git"; bad=1; }
  git lfs version >/dev/null 2>&1 || { echo "REFUSED tool git-lfs"; bad=1; }
  git filter-repo --version >/dev/null 2>&1 ||
    { echo "REFUSED tool git-filter-repo"; bad=1; }
  [ "$bad" = 0 ] || exit 3
}

# --- split: the build ---------------------------------------------------------
history_of() {  # space, filter-repo --path args...
  local s=$1; shift
  must "clone the bus for $s" env GIT_LFS_SKIP_SMUDGE=1 git clone -q \
    --no-tags --single-branch --branch main "$SRC" "$WORK/$s"
  must "filter the history of $s" env GIT_LFS_SKIP_SMUDGE=1 \
    git -C "$WORK/$s" filter-repo --force --quiet --preserve-commit-hashes \
    --replace-refs delete-no-add "$@" --path .gitattributes \
    --path .gitignore --path-rename memory/:
  git -C "$WORK/$s" remote remove origin >/dev/null 2>&1
  git -C "$WORK/$s" rev-parse -q --verify refs/heads/main >/dev/null ||
    fail "$s has no history"
}

scratch_tip() {  # tmp: one commit holding agent-tmp/ at $SHA, no history
  local t=$WORK/tmp tree
  : > "$SCR/tree.z"
  if [ "$(git -C "$SRC" cat-file -t "$SHA:$AT" 2>/dev/null)" = tree ]; then
    git -C "$SRC" ls-tree -z "$SHA:$AT" > "$SCR/tree.z" ||
      fail "read the scratch tip"
  fi
  git -C "$SRC" ls-tree -z "$SHA" -- .gitattributes .gitignore \
    >> "$SCR/tree.z" || fail "read the bus's root files"
  tree=$(git -C "$SRC" mktree -z < "$SCR/tree.z") ||
    fail "make the scratch tree"
  TIPC=$(git -C "$SRC" commit-tree "$tree" \
    -m "Start scratch from agent-tmp/ at bus $SHA7" </dev/null 2>>"$LOG") ||
    fail "make the scratch commit"
  must "keep the scratch commit" git -C "$SRC" update-ref \
    refs/heads/split-tmp "$TIPC"
  must "make tmp" git init -q "$t"
  must "name tmp's branch" git -C "$t" symbolic-ref HEAD refs/heads/main
  must "fetch the scratch tip" git -C "$t" fetch -q --no-tags "$SRC" \
    refs/heads/split-tmp
  must "set tmp's main" git -C "$t" update-ref refs/heads/main "$TIPC"
  rm -f "$t/.git/FETCH_HEAD"
  must "check out tmp" env GIT_LFS_SKIP_SMUDGE=1 git -C "$t" reset -q --hard
}

cmd_split() {
  local s r f msg k w d o c b bad V VL S
  req "$BUS" --bus; req "$WORK" --work; req "$OWNER" --owner
  req "$MESH" --mesh
  [ "$HAVE_READINESS" = 1 ] || die2 "split needs --readiness"
  name_ok "$OWNER" || die2 "not a name: $OWNER"
  name_ok "$MESH" || die2 "not a name: $MESH"
  for s in core lore tmp; do
    [ -f "$TPL/$s/space.yaml" ] ||
      die2 "no templates/spaces/ beside this script; run it from a checkout"
  done
  bus_root
  if [ -e "$WORK" ]; then
    [ -d "$WORK" ] && [ -z "$(ls -A "$WORK")" ] ||
      die2 "the work folder must be empty or absent: $WORK"
    w=$(cd "$WORK" && pwd -P)
  else
    w=$(cd "$(dirname "$WORK")" 2>/dev/null && pwd -P) ||
      die2 "no parent folder for $WORK"
    w=$w/$(basename "$WORK")
  fi
  case $w/ in "$(cd "$BUS" && pwd -P)"/*)
    die2 "the work folder must be outside the bus: $WORK" ;; esac

  check_readiness
  check_clean
  check_mapped
  check_decided
  check_tools

  ORIGIN=$(git -C "$BUS" remote get-url origin 2>/dev/null) ||
    fail "the bus has no origin"
  case $ORIGIN in
    /*|*://*|*:*) ;;
    *) ORIGIN=$(cd "$BUS" && cd "$ORIGIN" 2>/dev/null && pwd) ||
         fail "cannot resolve the bus's origin" ;;
  esac
  mkdir -p "$WORK" || fail "make the work folder"
  WORK=$(cd "$WORK" && pwd)
  SRC=$WORK/.bus.git
  must "clone the bus's origin" env GIT_LFS_SKIP_SMUDGE=1 git clone -q \
    --bare --no-tags --single-branch --branch main "$ORIGIN" "$SRC"
  git -C "$SRC" cat-file -e "$SHA^{commit}" 2>/dev/null ||
    fail "origin/main $SHA7 is not on the bus's origin"
  must "pin the clone at $SHA7" git -C "$SRC" update-ref refs/heads/main "$SHA"

  history_of core --path memory/notes/ --path memory/refs/ \
    --path memory/runs/ --path memory/workflows/ \
    --path memory/best-practices.user.md
  history_of lore --path memory/lore/
  scratch_tip

  for s in core lore tmp; do
    r=$WORK/$s
    must "set up LFS in $s" git -C "$r" lfs install --local --skip-repo
    # A missing object is not fatal here: VERIFY lfs reports it.
    lfs_at "$r" "$ORIGIN" fetch --all >>"$LOG" 2>&1 </dev/null
    git -C "$r" lfs checkout >>"$LOG" 2>&1 </dev/null
  done

  ADDED_README=0
  for s in core lore tmp; do
    r=$WORK/$s; f=space.yaml; msg="Add space.yaml from the product template"
    sed -e "s/<owner>/$OWNER/g" -e "s/<mesh>/$MESH/g" "$TPL/$s/space.yaml" \
      > "$r/space.yaml" || fail "write the $s manifest"
    if [ "$s" = tmp ] && ! git -C "$r" cat-file -e HEAD:README.md 2>/dev/null
    then
      cp "$TPL/tmp/README.md" "$r/README.md" || fail "write tmp's README.md"
      f="space.yaml README.md"; ADDED_README=1
      msg="Add space.yaml and README.md from the product templates"
    fi
    must "add the $s manifest" git -C "$r" add -- $f
    must "commit the $s manifest" git -C "$r" commit -q \
      -m "$msg" -- $f
  done
  MANIFEST_TMP=$(git -C "$WORK/tmp" rev-parse HEAD) || fail "read tmp"

  while IFS= read -r k; do
    [ -n "$k" ] || continue
    sed -n "s#^$AT/##p" "$SCR/untracked" |
      awk -v k="$k" 'index($0, k "/") == 1 || $0 == k' > "$SCR/keep"
    (cd "$BUS/$AT" && COPYFILE_DISABLE=1 tar -cf - -T "$SCR/keep") 2>>"$LOG" |
      (cd "$WORK/tmp" && tar -xpf -) 2>>"$LOG" || fail "copy spike $k"
    must "add spike $k" git -C "$WORK/tmp" add -f -- "$k"
    must "commit spike $k" git -C "$WORK/tmp" commit -q \
      -m "Add spike $k, untracked before the split"
  done <<EOF
$KEEP
EOF

  # Verify, then report.
  bad=0; V=; VL=
  ids_at "$BUS" "$SHA" memory/notes memory/refs memory/runs \
    memory/workflows memory/best-practices.user.md > "$SCR/ids.bus.core"
  ids_at "$BUS" "$SHA" memory/lore > "$SCR/ids.bus.lore"
  for s in core lore; do
    ids_at "$WORK/$s" main > "$SCR/ids.$s"
    d=$(comm -3 "$SCR/ids.bus.$s" "$SCR/ids.$s" | wc -l | tr -d ' ')
    if [ "$d" = 0 ]; then
      V="${V}VERIFY $s ids $(count "$SCR/ids.$s") match$NL"
    else V="${V}VERIFY $s ids MISMATCH $d$NL"; bad=1; fi
  done

  { if [ "$(git -C "$BUS" cat-file -t "$SHA:$AT" 2>/dev/null)" = tree ]; then
      git -C "$BUS" ls-tree -r -z "$SHA" -- "$AT/"
    fi
    git -C "$BUS" ls-tree -z "$SHA" -- .gitattributes .gitignore
  } | tr '\0' '\n' |
    awk -F '\t' -v p="$AT/" '{ split($1, a, " "); x = $2
      if (index(x, p) == 1) x = substr(x, length(p) + 1); print a[3] "\t" x }' |
    sort > "$SCR/files.bus"
  { echo space.yaml; [ "$ADDED_README" = 1 ] && echo README.md
    git -C "$WORK/tmp" diff --name-only --no-renames -z "$MANIFEST_TMP" main |
      tr '\0' '\n'; } > "$SCR/excl"
  git -C "$WORK/tmp" ls-tree -r -z main | tr '\0' '\n' |
    awk -F '\t' 'FILENAME == ARGV[1] { x[$0] = 1; next }
      !($2 in x) { split($1, a, " "); print a[3] "\t" $2 }' "$SCR/excl" - |
    sort > "$SCR/files.tmp"
  d=$(comm -3 "$SCR/files.bus" "$SCR/files.tmp" | wc -l | tr -d ' ')
  if [ "$d" = 0 ]; then
    V="${V}VERIFY tmp files $(count "$SCR/files.bus") match$NL"
  else V="${V}VERIFY tmp files MISMATCH $d$NL"; bad=1; fi

  S=
  for s in core lore tmp; do
    r=$WORK/$s
    lfs_oids "$r" main > "$SCR/oids.$s" || fail "list the LFS objects of $s"
    o=$(count "$SCR/oids.$s")
    c=$(git -C "$r" rev-list --count main)
    f=$(git -C "$r" ls-tree -r -z --name-only main | tr -cd '\0' | wc -c |
      tr -d ' ')
    if [ "$s" = tmp ]; then
      S="${S}SPLIT tmp tip $SHA7 $c commits, $f files, $o LFS objects$NL"
    else
      S="${S}SPLIT $s history $c commits, $f files, $o LFS objects$NL"
    fi
    b=$(lfs_bad "$r" "$SCR/oids.$s")
    if [ "$b" = 0 ]; then VL="${VL}VERIFY $s lfs $o present$NL"
    else VL="${VL}VERIFY $s lfs MISMATCH $b$NL"; bad=1; fi
  done
  rm -rf "$SRC"
  printf '%s%s%s' "$S" "$V" "$VL"
  [ "$bad" = 0 ] || exit 5
}

# --- publish ----------------------------------------------------------------
cmd_publish() {
  local s u r l h o refs bad=0
  req "$WORK" --work; req "$CORE_URL" --core-url; req "$LORE_URL" --lore-url
  req "$TMP_URL" --tmp-url
  [ -d "$WORK" ] || die2 "no such work folder: $WORK"
  WORK=$(cd "$WORK" && pwd)
  for s in core lore tmp; do
    git -C "$WORK/$s" rev-parse -q --verify refs/heads/main >/dev/null 2>&1 ||
      die2 "no $s repo with a main in $WORK; run split first"
  done
  for s in core lore tmp; do
    u=$(url_of "$s")
    if ! refs=$(git -C "$WORK/$s" ls-remote "$u" 2>>"$LOG" </dev/null); then
      echo "REFUSED publish $s: $(show_url "$u") unreachable"; bad=1
    elif [ -n "$refs" ]; then
      echo "REFUSED publish $s: remote not empty"; bad=1
    fi
  done
  [ "$bad" = 0 ] || exit 4
  for s in core lore tmp; do
    u=$(url_of "$s"); r=$WORK/$s
    must "add the remote of $s" remote_on "$r" "$u"
    must "push the LFS objects of $s" git -C "$r" lfs push --all split-memory
    must "push the main of $s" git -C "$r" push -q split-memory \
      refs/heads/main:refs/heads/main
    remote_off "$r"
    l=$(git -C "$r" rev-parse main)
    h=$(git -C "$r" ls-remote "$u" refs/heads/main 2>>"$LOG" </dev/null |
      cut -f1)
    [ "$h" = "$l" ] || fail "the remote main of $s is not the local main"
    lfs_oids "$r" main > "$SCR/oids" || fail "list the LFS objects of $s"
    o=$(count "$SCR/oids")
    echo "PUBLISHED $s $(show_url "$u") ${l:0:7}, $o LFS objects"
  done
}

# --- mount ------------------------------------------------------------------
gitlink() {  # path: the commit the index pins there, if a gitlink
  git -C "$BUS" ls-files -s -- "$1" | awk '$1 == "160000" { print $2 }'
}

listed() {  # space id: true if spaces.yaml lists it
  local x
  x="^[[:space:]]*-[[:space:]]*\\{?[[:space:]]*id:[[:space:]]*$1"
  [ -f "$BUS/spaces.yaml" ] &&
    grep -Eq "$x[[:space:]]*([,}]|\$)" "$BUS/spaces.yaml"
}

overlay_set() {  # true if guidance/CLAUDE.md is absent or imports from core
  local g=$BUS/guidance/CLAUDE.md
  [ ! -f "$g" ] || grep -qxF -- "$OVERLAY" "$g"
}

mounted() {  # true if the whole mount is already in the index
  local s e p t
  for s in core lore tmp; do
    [ -n "$(gitlink "spaces/$s")" ] || return 1
    git -C "$BUS" config -f .gitmodules --get "submodule.spaces/$s.path" \
      >/dev/null 2>&1 || return 1
    listed "$s" || return 1
  done
  overlay_set || return 1
  git -C "$BUS" ls-files -s -- memory "$AT" > "$SCR/ix" || return 1
  [ "$(count "$SCR/ix")" = 7 ] || return 1
  while read -r p t; do
    e=$(awk -v p="$p" '$4 == p { print $1, $2 }' "$SCR/ix")
    [ "${e%% *}" = 120000 ] || return 1
    [ "$(git -C "$BUS" cat-file blob "${e#* }")" = "$t" ] || return 1
    [ -L "$BUS/$p" ] && [ "$(readlink "$BUS/$p")" = "$t" ] || return 1
  done <<EOF
$LINKS
EOF
}

print_mounted() {
  local s x
  for s in core lore tmp; do
    x=$(gitlink "spaces/$s")
    echo "MOUNTED spaces/$s ${x:0:7}"
  done
}

leftovers() {  # what mount would lose or leave behind
  : > "$SCR/left.z"
  { git -C "$BUS" ls-files -z --others --exclude-standard -- memory
    git -C "$BUS" ls-files -z --others --ignored --exclude-standard -- memory
    git -C "$BUS" diff -z --name-only HEAD -- memory
    if [ -d "$BUS/$AT" ] && [ ! -L "$BUS/$AT" ]; then
      git -C "$BUS" ls-files -z --others --exclude-standard -- "$AT/"
      git -C "$BUS" diff -z --name-only HEAD -- "$AT/"
      if [ "$CARRY" = 0 ]; then
        git -C "$BUS" ls-files -z --others --ignored --exclude-standard \
          -- "$AT/"
      fi
    fi
  } > "$SCR/left.z" 2>>"$LOG" || fail "list leftovers"
  tr '\0' '\n' < "$SCR/left.z" | grep -v '^$' | sort -u | sed 's/^/LEFTOVER /'
}

unsplit() {  # each tracked bus file that its space's main lacks
  local P=$SCR/probe.git s
  must "make a probe repo" git init -q --bare "$P"
  for s in core lore tmp; do
    must "fetch the main of $s" git -C "$P" fetch -q --no-tags \
      "$(url_of "$s")" "+refs/heads/main:refs/heads/$s"
  done
  for s in core lore tmp; do
    git -C "$P" ls-tree -r -z "refs/heads/$s" | tr '\0' '\n' |
      awk -F '\t' -v s="$s" '{ split($1, a, " "); print s "\t" a[3] "\t" $2 }'
  done > "$SCR/have" || fail "list the spaces"
  git -C "$BUS" ls-tree -r -z HEAD -- memory "$AT" | tr '\0' '\n' |
    awk -F '\t' -v at="$AT/" '{ split($1, a, " "); p = $2; s = "none"; q = p
      if (index(p, "memory/lore/") == 1) { s = "lore"; q = substr(p, 8) }
      else if (p ~ /^memory\/(notes|refs|runs|workflows)\// ||
               p == "memory/best-practices.user.md") {
        s = "core"; q = substr(p, 8) }
      else if (index(p, at) == 1) { s = "tmp"; q = substr(p, length(at) + 1) }
      print s "\t" a[3] "\t" q "\t" p }' > "$SCR/want" || fail "list the bus"
  awk -F '\t' 'FILENAME == ARGV[1] { h[$1 "\t" $2 "\t" $3] = 1; next }
    !(($1 "\t" $2 "\t" $3) in h) { print "UNSPLIT " $4 }' \
    "$SCR/have" "$SCR/want"
}

registry_ok() {  # true if add_entries can append under spaces.yaml's spaces:
  local y=$BUS/spaces.yaml v
  [ -f "$y" ] || return 0
  listed core && listed lore && listed tmp && return 0
  # The spaces: line may hold nothing (a block list follows) or [], and no
  # other value: not an inline list, nor a scalar such as ~.
  v=$(awk '/^spaces:/ { s = $0; sub(/\r$/, "", s); sub(/^spaces:/, "", s)
             sub(/[ \t]#.*$/, "", s); gsub(/[ \t]/, "", s); print s; exit }' \
        "$y") || return 1
  case $v in ''|'[]') return 0 ;; esac
  return 1
}

add_entries() {  # append the missing registry entries under spaces:
  local y=$BUS/spaces.yaml e x
  [ -f "$y" ] || printf 'spaces: []\n' > "$y"
  e=; x="access: rw, librarian:"
  listed core || e="$e- {id: core, path: spaces/core, $x librarian}$NL"
  listed lore || e="$e- {id: lore, path: spaces/lore, $x librarian}$NL"
  listed tmp || e="$e- {id: tmp, path: spaces/tmp, $x none}$NL"
  [ -n "$e" ] || return 0
  registry_ok ||
    fail "spaces.yaml's spaces: is not a block list; make it one first"
  ENTS=$e awk '
    { line[NR] = $0 }
    END {
      n = split(ENVIRON["ENTS"], E, "\n"); k = 0
      for (i = 1; i <= NR; i++) if (line[i] ~ /^spaces:/) { k = i; break }
      if (k == 0) {
        for (i = 1; i <= NR; i++) print line[i]
        print "spaces:"
        for (j = 1; j <= n; j++) if (E[j] != "") print "  " E[j]
        exit
      }
      if (line[k] ~ /^spaces:[ \t]*\[[ \t]*\][ \t\r]*(#.*)?$/) {
        for (i = 1; i < k; i++) print line[i]
        print "spaces:"
        for (j = 1; j <= n; j++) if (E[j] != "") print "  " E[j]
        for (i = k + 1; i <= NR; i++) print line[i]
        exit
      }
      last = k; ind = "  "
      for (i = k + 1; i <= NR; i++) {
        if (line[i] ~ /^[^ \t#-]/) break
        if (line[i] ~ /^[ \t]*-/) {
          last = i; ind = line[i]; sub(/-.*/, "", ind)
        } else if (line[i] ~ /^[ \t]+[^ \t#]/ && last > k) last = i
      }
      for (i = 1; i <= last; i++) print line[i]
      for (j = 1; j <= n; j++) if (E[j] != "") print ind E[j]
      for (i = last + 1; i <= NR; i++) print line[i]
    }' "$y" > "$SCR/spaces.yaml" || fail "edit spaces.yaml"
  cat "$SCR/spaces.yaml" > "$y" || fail "write spaces.yaml"
}

set_overlay() {  # import the overlay from core in guidance/CLAUDE.md
  local g=$BUS/guidance/CLAUDE.md
  [ -f "$g" ] || return 0
  overlay_set && return 0
  if grep -qxF -- "$OVERLAY_OLD" "$g"; then
    awk -v o="$OVERLAY_OLD" -v n="$OVERLAY" \
      '$0 == o { print n; next } { print }' "$g" > "$SCR/claude"
  elif grep -qxF -- "$BASE_IMPORT" "$g"; then
    awk -v b="$BASE_IMPORT" -v n="$OVERLAY" '{ print } $0 == b { print n }' \
      "$g" > "$SCR/claude"
  else
    { cat "$g"; printf '%s\n' "$OVERLAY"; } > "$SCR/claude"
  fi || fail "edit guidance/CLAUDE.md"
  cat "$SCR/claude" > "$g" || fail "write guidance/CLAUDE.md"
}

cmd_mount() {
  local re s u h gd p q d t m bad=0
  req "$BUS" --bus; req "$CORE_URL" --core-url; req "$LORE_URL" --lore-url
  req "$TMP_URL" --tmp-url
  re='^[A-Za-z][A-Za-z0-9+.-]*://[^/]*@'
  for s in core lore tmp; do
    u=$(url_of "$s")
    if [[ $u =~ $re ]]; then
      die2 "give the $s URL without user info: it goes into .gitmodules"
    fi
  done
  bus_root
  if mounted; then print_mounted; exit 0; fi

  leftovers > "$SCR/left"
  if [ -s "$SCR/left" ]; then cat "$SCR/left"; exit 4; fi
  if ! registry_ok; then
    echo "REFUSED mount: spaces.yaml's spaces: holds a value other than [];" \
      "make it a block list first"
    exit 4
  fi
  for s in core lore tmp; do
    u=$(url_of "$s")
    h=$(git -C "$BUS" ls-remote "$u" refs/heads/main 2>>"$LOG" </dev/null |
      cut -f1)
    if [ -z "$h" ]; then
      echo "REFUSED mount: $(show_url "$u") has no main"; bad=1
    fi
  done
  [ "$bad" = 0 ] || exit 4
  unsplit > "$SCR/unsplit"
  if [ -s "$SCR/unsplit" ]; then cat "$SCR/unsplit"; exit 4; fi

  # Network first: the submodules. Nothing under the library or scratch
  # changes until all three are in. With -b main each checkout is left on
  # its main branch, attached: the sync tool checks scratch in on a branch
  # and stops at a detached HEAD with changes.
  gd=$(git -C "$BUS" rev-parse --git-common-dir) ||
    fail "find the bus's git dir"
  case $gd in /*) ;; *) gd=$BUS/$gd ;; esac
  for s in core lore tmp; do
    [ -n "$(gitlink "spaces/$s")" ] && continue
    [ ! -e "$gd/modules/spaces/$s" ] ||
      fail "spaces/$s is half added: remove its .git/modules dir, then rerun"
    must "add the submodule spaces/$s" git -C "$BUS" submodule add -q -b main \
      -- "$(url_of "$s")" "spaces/$s"
    must "set ignore for spaces/$s" git -C "$BUS" config -f .gitmodules \
      "submodule.spaces/$s.ignore" all
  done
  must "stage .gitmodules" git -C "$BUS" add -- .gitmodules

  if [ "$CARRY" = 1 ] && [ -d "$BUS/$AT" ] && [ ! -L "$BUS/$AT" ]; then
    git -C "$BUS" ls-files -z --others --ignored --exclude-standard -- "$AT/" |
      tr '\0' '\n' > "$SCR/ignored" || fail "list ignored scratch"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      q=$TMPM/${p#"$AT/"}
      if [ -e "$BUS/$q" ] || [ -L "$BUS/$q" ]; then
        fail "cannot carry $p: $q exists"
      fi
      mkdir -p "$(dirname "$BUS/$q")" && mv "$BUS/$p" "$BUS/$q" ||
        fail "carry $p"
    done < "$SCR/ignored"
  fi

  must "remove the tracked library and scratch" git -C "$BUS" rm -r -q \
    --ignore-unmatch -- memory "$AT"
  for d in memory "$AT"; do
    if [ -d "$BUS/$d" ] && [ ! -L "$BUS/$d" ]; then
      find "$BUS/$d" -depth -type d -empty -exec rmdir {} \;
    fi
  done
  if [ -d "$BUS/$AT" ] && [ ! -L "$BUS/$AT" ]; then
    fail "$AT still holds files"
  fi
  mkdir -p "$BUS/memory" || fail "make memory/"
  while read -r p t; do
    if [ -L "$BUS/$p" ] && [ "$(readlink "$BUS/$p")" = "$t" ]; then
      continue
    fi
    if [ -e "$BUS/$p" ] || [ -L "$BUS/$p" ]; then
      fail "cannot link $p: it exists"
    fi
    ln -s "$t" "$BUS/$p" || fail "link $p"
  done <<EOF
$LINKS
EOF
  must "stage the links" git -C "$BUS" add -- memory "$AT"
  add_entries
  must "stage spaces.yaml" git -C "$BUS" add -- spaces.yaml
  set_overlay
  if [ -f "$BUS/guidance/CLAUDE.md" ]; then
    must "stage guidance/CLAUDE.md" git -C "$BUS" add -- guidance/CLAUDE.md
  fi

  print_mounted
  m="Split memory into core, lore and scratch spaces"
  echo "RUN git -C $BUS commit -m \"$m\""
  echo "RUN git -C $BUS push origin HEAD:main"
}

case $CMD in
  names) cmd_names ;;
  split) cmd_split ;;
  publish) cmd_publish ;;
  mount) cmd_mount ;;
esac
