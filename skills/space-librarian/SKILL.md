---
name: space-librarian
description: File records into a memory space (a Project Space or any other rw space) after the header-profile, reference and id checks, one commit per record, pushed to the space's main. Invoke when a librarian node files records into a space that spaces.yaml assigns to its role, when a session with no bus files a record into a space checkout, or when someone asks to file, check or desk-run records for a space.
allowed-tools: Read, Write, Bash, Grep, Glob
---

# space-librarian: file records into a memory space

A memory space (the memory-spaces design) is a git repo of records with one
writer per mesh, its librarian. This skill is that writer. It is given a space
root and record files, checks each record, and files the ones that pass: one
commit per record, pushed to the space's `main`. It needs no bus.

## Who runs it

- **On a mesh.** A mesh librarian uses this skill for every rw space that
  `spaces.yaml` assigns to its role: each entry with `access: rw` and its role
  in `librarian:`. It never writes a space listed `access: ro`. To list the
  spaces a role files (one-line entries, as the registry is written):

  ```sh
  grep -E 'access:[[:space:]]*rw' <bus root>/spaces.yaml |
    grep -E 'librarian:[[:space:]]*<role>[[:space:]]*[},]'
  ```

- **Without a bus** (single seat). The session uses this skill directly, on
  its checkout of the space, as its own librarian. The checks are the same;
  the real values they look for then come from the node alone.

It files what it is handed. Deciding what belongs in the space, and who may
hand it over, is the caller's job.

## Inputs

- **Space root**: the space's checkout, a git repo with `space.yaml` at its
  root and the space's remote as `origin`. In a bus it is `spaces/<path>`.
- **Records**: paths relative to the space root, each already written at that
  path. They are checked, and filed, in the order given.
- **Bus root** (optional). If not given, the bus is the space's superproject,
  else the `REPO_PATH` in `~/.agent-identity.env`. It counts only if it has
  `agents/`. With none, there is no bus.

## Output

One line per record, in the order given, and nothing else:

```
FILED <space path> <sha7>
REFUSED <space path>: <profile|reference|id> line <n>
```

`<n>` is the 1-based line of the record where the check failed. The checks run
in the order profile, reference, id, and the first that fails is reported, at
its first failing line. The output never holds the matched text or any value
the checks search for. A record path that names no file is an error for the
caller, not a result line.

## 1. Check each record

The three checks, as the script below runs them:

- **profile.** No real hostname, agent id, mesh task id or credential key
  name, and no home path, anywhere in the file. Real values come from the bus
  where one is present: `agents/*.yaml` (`agent_id`, `agent_name`,
  `hostname` and its first label, `credentials_available`, `cwd`), the
  direct-inbox names under `tasks/`, and the task ids in the file names under
  `tasks/`, `status/` and `_archive/`. From the node come the local hostname
  (`hostname` and `uname -n`, with their first labels) and the credential key
  names in `~/.agent-credentials.env`. Home paths are matched by four
  patterns:
  - the local `$HOME`;
  - each registered agent's `cwd`;
  - the first two path components of each registered agent's `cwd`;
  - absolute per-user paths under the macOS and Linux home roots.

  Generic `~/` paths are allowed, and so is an id-shaped example that no bus
  holds. Values shorter than three characters are skipped.
- **reference** (Markdown records). Every citation must resolve. A citation
  is a value of a front-matter reference field (`related`, `supersedes`,
  `superseded_by`, `discovered_in`), or a qualified cross-space id
  `<space id>/<record id>` in the body outside inline code and fenced blocks,
  where a space id is `core`, `lore`, `lore:<name>` or `proj:<name>`. A
  trailing `@<commit>` pin is ignored. It resolves when it is:
  - a URL;
  - a record id held by a record in the space (in its `id:` line, or as the
    start of its file name);
  - a qualified id whose space is listed in `may_reference` in `space.yaml`,
    or is this space (then the rest must resolve here);
  - a change id with a folder `changes/<id>/` or
    `changes/archive/<date>-<id>/`;
  - `<change>/T<n>`, where that change's `plan.md` has task `T<n>` as a
    heading or a table row.
- **id** (Markdown records). The id is the front-matter `id:`; under
  `decisions/` and `handoffs/` with no `id:` line it is the file name. A
  record with no id passes. An id already at this same path on `origin/main`
  (or `HEAD`, where there is no `origin/main`) is not new and passes. A new
  id must have the form
  `<category>-<YYYYMMDDTHHMMZ>-<4 hex>`, or the UTC-named form: `ev-<UTC>`
  under `changes/<id>/evidence/`, `<UTC>-<slug>` under `decisions/` and
  `handoffs/`. It must not be already present: no other file in the space
  holds it. Evidence, decisions and handoffs are one file per event, so a
  record there whose path is already on `origin/main` with other content is
  refused as `id`.

Copy the script into a file in a scratch directory outside the space, never
inside it, and run it with `sh`:

```
SPACE=<space root> sh <script file> <space path> ...
```

Set `BUS=<bus root>` to name the bus. It prints `REFUSED ...` for a record
that fails, and `CHECKED <space path>` for one that passes. `CHECKED` is a
working line: those records go on to section 2, and it is never part of the
output. The script is POSIX `sh`, and its patterns are `grep -E`, `sed -E`
and POSIX `awk` (no `grep -P`, no GNU-only flag), so it runs unchanged with
BSD and GNU tools. The value lists it builds stay in its own temporary
directory, which it deletes on exit.

```sh
: "${SPACE:?set SPACE to the space root}"
SPACE=${SPACE%/}
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
esc() { sed -e 's#[[\.*^$+?(){}|]#\\&#g'; }
val() { sed -n -E "s/^$1:[[:space:]]*\"?([^\"#[:space:]]+).*/\\1/p" "$2"; }

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

# profile: real values from the bus and the node, built at run time.
: > "$W/words"; : > "$W/paths"
if [ -n "$BUS" ]; then
  for y in "$BUS"/agents/*.yaml; do
    [ -f "$y" ] || continue
    for k in agent_id agent_name hostname; do val "$k" "$y"; done >> "$W/words"
    val hostname "$y" | cut -d. -f1 >> "$W/words"
    sed -n -E 's/^credentials_available:[[:space:]]*\[(.*)\].*/\1/p' "$y" |
      tr ',' '\n' >> "$W/words"
    c=$(val cwd "$y" | sed -E 's#/+$##')
    case "$c" in
      /?*) printf '%s\n' "$c" "$(printf '%s\n' "$c" | cut -d/ -f1-3)" \
             >> "$W/paths" ;;
    esac
  done
  ls "$BUS/tasks" 2>/dev/null | grep -vE '^(roles|\..*)$' >> "$W/words"
  find "$BUS/tasks" "$BUS/status" "$BUS/_archive" -type f 2>/dev/null |
    sed 's#.*/##' | grep -oE '[0-9]{8}T[0-9]{4}-[0-9]{4}' >> "$W/words"
fi
for h in "$(hostname 2>/dev/null)" "$(uname -n 2>/dev/null)"; do
  printf '%s\n' "$h" "${h%%.*}"
done >> "$W/words"
if [ -f "$HOME/.agent-credentials.env" ]; then
  sed -n -E 's/^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' \
    "$HOME/.agent-credentials.env" >> "$W/words"
fi
case "$HOME" in /?*) printf '%s\n' "$HOME" >> "$W/paths" ;; esac
sed -E 's/^[[:space:]"]+//; s/[[:space:]"]+$//' "$W/words" |
  grep -E '^.{3,}$' | grep -vE '^(null|~)$' | sort -u | esc |
  sed 's#.*#(^|[^A-Za-z0-9_-])&([^A-Za-z0-9_-]|$)#' > "$W/profile"
sed -E 's#/+$##' "$W/paths" | grep -E '^/.{2,}' | sort -u | esc |
  sed 's#.*#&([^A-Za-z0-9_.-]|$)#' >> "$W/profile"
printf '%s\n' '(^|[^A-Za-z0-9_.-])/(Users|home)/[A-Za-z0-9._-]+' >> "$W/profile"

# reference: this space's id and its may_reference list.
SID=$(val id "$SPACE/space.yaml" | head -n 1)
awk '/^may_reference:/ {
       s = $0; sub(/^may_reference:[ \t]*/, "", s); sub(/[ \t]*#.*$/, "", s)
       if (s != "") { gsub(/\[|\]|[ \t"]/, "", s); n = split(s, a, ",")
                      for (i = 1; i <= n; i++) if (a[i] != "") print a[i]; exit }
       blk = 1; next }
     blk && /^[ \t]*-/ { s = $0; sub(/^[ \t]*-[ \t]*/, "", s)
                         sub(/[ \t]*#.*$/, "", s); gsub(/"/, "", s); print s; next }
     blk { exit }' "$SPACE/space.yaml" > "$W/mayref"
QID='(^|[^A-Za-z0-9_.:/-])(core|lore|lore:[a-z0-9][a-z0-9-]*|proj:[a-z0-9][a-z0-9-]*)'
QID="$QID"'/([a-z][a-z0-9]*-)?[0-9]{8}[A-Za-z0-9-]*(@[0-9a-f]+)?'

idof() {  # "<line> <id>" from a record's front-matter on stdin
  awk 'NR == 1 { if ($0 != "---") exit; next }
       $0 == "---" { exit }
       /^id:/ { x = $0; sub(/^id:[ \t]*/, "", x); sub(/[ \t]+#.*$/, "", x)
                gsub(/"/, "", x); print NR, x; exit }'
}
holders() {  # files in the space named by id $1, or with id: $1
  find "$SPACE" -name .git -prune -o -type f -name "$1*" -print
  find "$SPACE" -name .git -prune -o -type f -name '*.md' \
    -exec grep -lE "^id:[[:space:]]*\"?$1\"?[[:space:]]*\$" {} +
}
chg() {  # the folder of change $1, live or archived
  if [ -d "$SPACE/changes/$1" ]; then echo "$SPACE/changes/$1"; return; fi
  for d in "$SPACE"/changes/archive/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-"$1"
  do [ -d "$d" ] && echo "$d" && return; done
}
resolve() {  # true if citation $1 resolves
  c=$1
  case "$c" in *://*) return 0 ;; esac
  c=${c%%@*}
  case "$c" in
    core/*|lore/*|lore:*/*|proj:*/*)
      s=${c%%/*}; c=${c#*/}
      if [ "$s" != "$SID" ]; then
        grep -qE "^$(printf '%s\n' "$s" | esc)\$" "$W/mayref"; return
      fi ;;
  esac
  if printf '%s\n' "$c" | grep -qE '^([a-z][a-z0-9]*-)?[0-9]{8}[A-Za-z0-9-]*$'
  then [ -n "$(holders "$c")" ]; return; fi
  if printf '%s\n' "$c" | grep -qE '^[a-z0-9][a-z0-9-]*/T[0-9]+$'; then
    t=${c##*/}; d=$(chg "${c%/*}")
    [ -n "$d" ] && grep -qE \
      "^(#+[[:space:]]+$t([[:space:]:]|\$)|\|[[:space:]]*$t[[:space:]]*\|)" \
      "$d/plan.md" 2>/dev/null
    return
  fi
  printf '%s\n' "$c" | grep -qE '^[a-z0-9][a-z0-9-]*$' && [ -n "$(chg "$c")" ]
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
  awk 'NR == 1 && $0 == "---" { fm = 1; print ""; next }
       fm { if ($0 == "---") fm = 0; print ""; next }
       /^[ \t]*(```|~~~)/ { fence = !fence; print ""; next }
       fence { print ""; next }
       /^[ \t]*$/ { code = 0 }
       { out = ""; s = $0
         while ((i = index(s, "`")) > 0) {
           if (!code) out = out substr(s, 1, i - 1)
           code = !code; s = substr(s, i + 1) }
         if (!code) out = out s
         print out }' "$1" |
    grep -noE "$QID" | sed -E 's/^([0-9]+):[^a-z]?/\1 /'
}

BASE=HEAD
if git -C "$SPACE" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  BASE=origin/main
fi
for r in "$@"; do
  r=${r#./}; f=$SPACE/$r
  if [ ! -f "$f" ]; then echo "no such record: $r" >&2; continue; fi
  # profile
  n=$(grep -naE -f "$W/profile" "$f" | head -n 1 | cut -d: -f1)
  if [ -n "$n" ]; then echo "REFUSED $r: profile line $n"; continue; fi
  case "$r" in *.md) ;; *) echo "CHECKED $r"; continue ;; esac
  # reference
  n=$(refs "$f" | sort -n | while read -r ln c; do
        resolve "$c" || { echo "$ln"; break; }
      done)
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
    case "$r" in
      changes/*/evidence/*) ev=1; form="$form|ev-[0-9]{8}T[0-9]{4}Z" ;;
      decisions/*|handoffs/*) ev=1
        form="$form|[0-9]{8}T[0-9]{4}Z-[a-z0-9][a-z0-9-]*" ;;
    esac
    if git -C "$SPACE" cat-file -e "$BASE:$r" 2>/dev/null; then
      if [ "$ev" = 1 ]; then
        git -C "$SPACE" diff --quiet "$BASE" -- "$r" ||
          { echo "REFUSED $r: id line $n"; continue; }
        echo "CHECKED $r"; continue
      fi
      o=$(git -C "$SPACE" show "$BASE:$r" | idof)
      if [ "${o#* }" = "$id" ]; then echo "CHECKED $r"; continue; fi
    fi
    if ! printf '%s\n' "$id" | grep -qE "^($form)\$" ||
       holders "$id" | grep -vxE "$(printf '%s\n' "$f" | esc)" | grep -q .
    then echo "REFUSED $r: id line $n"; continue; fi
  fi
  echo "CHECKED $r"
done
```

## 2. Commit, push, confirm

Take the `CHECKED` records one at a time, in order. Every git command names
the space root as a literal absolute path (`git -C <space root> ...`), never a
variable, so a git gate can see where it writes; where one is installed, its
allowlist must hold the space root. Messages are plain text on one line.

1. Fetch, and skip a record that is already filed:

   ```
   git -C <space root> fetch origin
   git -C <space root> cat-file -e origin/main:<space path>
   git -C <space root> diff --quiet origin/main -- <space path>
   ```

   If both of the last two exit 0, the record is on `origin/main` as it is.
   Make no commit; take as `<commit>` the output of
   `git -C <space root> log -1 --format=%H origin/main -- <space path>`, and
   go to step 5.
2. Commit the record alone:

   ```
   git -C <space root> add -- <space path>
   git -C <space root> commit -m "File <space path>" -- <space path>
   ```

   If git reports nothing to commit, an earlier run committed the record and
   stopped before its push; go on to step 3.
3. Bring the commit onto the tip, and find it:

   ```
   git -C <space root> fetch origin
   git -C <space root> rebase --autostash origin/main
   git -C <space root> log -1 --format=%H -- <space path>
   ```

   The last command prints `<commit>`. `--autostash` keeps records not yet
   filed out of the way of the rebase. Then run the check script again on
   this record alone, since the rebase may have brought in a record that now
   holds its id. If it prints `REFUSED`, undo the commit with
   `git -C <space root> reset -q HEAD~1`, print that line, and go on to the
   next record.
4. Push:

   ```
   git -C <space root> push origin HEAD:main
   ```

   If the push is rejected, repeat step 3 and push again, three pushes at
   most. If the rebase conflicts, run `git -C <space root> rebase --abort`.
   After a conflict, or a third rejected push, print nothing for this record
   or the ones after it, and tell the caller that filing stopped at this
   record.
5. Confirm with a fresh fetch:

   ```
   git -C <space root> fetch origin
   git -C <space root> merge-base --is-ancestor <commit> origin/main
   ```

   Only if it exits 0, print `FILED <space path> <sha7>`, where `<sha7>` is
   the first seven characters of `<commit>`.

## Desk run

When the caller asks for a desk run, run the check script (section 1) as
written, since it only reads. Then print each command of section 2 for each
`CHECKED` record, in order, with the space root, path and message filled in
and `<commit>` left as it is, and run none of them. A desk run prints no
`FILED` line.

## Never

- Print a matched line, a pattern list or a value from one, or write any of
  them inside the space.
- Commit more than one record in a commit, or commit a file it was not given.
- Force-push, push anything other than `HEAD:main`, or create a branch in the
  space.
- Write a space listed `access: ro`. This skill commits only in the space's
  own repo; it never commits to the bus or moves the space's gitlink there.
