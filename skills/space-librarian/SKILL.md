---
name: space-librarian
description: File records into a memory space (a Project Space or any other rw space) after the header-profile, reference and id checks, one commit per record, pushed to the space's main; in integrate mode, a change's renames and edits in one commit. Invoke when a librarian node files records into a space that spaces.yaml assigns to its role, when a session with no bus files a record into a space checkout, when a change's lead files its integrate update, or when someone asks to file, check or desk-run records for a space.
allowed-tools: Read, Write, Bash, Grep, Glob
---

# space-librarian: file records into a memory space

A memory space (the memory-spaces design) is a git repo of records with one
writer per mesh, its librarian. This skill is that writer. It is given a space
root and record files, checks each record, and files the ones that pass: one
commit per record, pushed to the space's `main`. A change's integrate is the
one exception, filed in one commit in integrate mode (section 3). It needs no
bus.

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

Integrate mode takes renames as well (section 3).

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

The three checks, as the check script `check.sh` runs them:

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
  holds. Values shorter than three characters are skipped. Each value
  matches as a whole word. A hostname or credential key name inside a longer
  name joined by `-` or `_` passes. An agent id, agent name or task id joined
  that way does not, as in the bus's own `<task id>-<slug>` file names.
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
  `<category>-<YYYYMMDDTHHMMZ>-<4 hex>`, or the UTC-named form: `ev-<UTC>`,
  or `ev-<UTC>-<shard id>` for a shard (a task id and one lowercase letter),
  such as `ev-<UTC>-T19a`, under `changes/<id>/evidence/`; `<UTC>-<slug>`
  under `decisions/` and `handoffs/`. It must not be already present: no
  other file in the space holds it. Evidence, decisions and handoffs are one
  file per event, so a record there whose path is already on `origin/main`
  with other content is refused as `id`.
- **Test fixtures.** A file under `changes/*/tests/fixtures/` or
  `tests/*/fixtures/` gets the profile check only, in every mode. Fixture
  data may look like records, but it is a test's input, so its ids and
  citations are not checked.

The script is `check.sh`, shipped beside this file in the skill's directory,
`<skill dir>`. Run that file with `sh` as it ships; never copy it into the
space or rebuild it by hand:

```
SPACE=<space root> sh <skill dir>/check.sh <space path> ...
```

Set `BUS=<bus root>` to name the bus. It prints `REFUSED ...` for a record
that fails, and `CHECKED <space path>` for one that passes. `CHECKED` is a
working line: those records go on to section 2, and it is never part of the
output. The script is POSIX `sh`, and its patterns are `grep -E`, `sed -E`
and POSIX `awk` (no `grep -P`, no GNU-only flag), so it runs unchanged with
BSD and GNU tools. The value lists it builds stay in its own temporary
directory, which it deletes on exit.

In integrate mode, `--move <from> <to>` pairs come before the records
(section 3).

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

## 3. Integrate mode

At a change's integrate, the change's lead files the update in one commit
(swe-pod `PROCESS.md` §8): two renames, the change's tests into
`tests/<id>/` and its folder into `changes/archive/<yyyy-mm-dd>-<id>/`, and
the edited and new files. Only the lead uses this mode, and only there. It
is the one exception to one record per commit.

**Inputs.**

- The space root, as in section 2, and the change id, for the message.
- **Renames**: an ordered list of `<from> <to>` pairs of space paths, each a
  file or a folder. They are made in the order given, so a folder inside
  another renamed folder comes first: `changes/<id>/tests` to `tests/<id>`,
  then `changes/<id>` to `changes/archive/<yyyy-mm-dd>-<id>`. Each `<from>`
  holds tracked files, and no `<to>` exists yet.
- **Records**: the edited and new files, each named by its path after the
  moves. Write them all first, where they are before the moves; a record
  inside a renamed folder moves with it.

**Paths.** The update's paths are the tracked files under each rename, named
by their paths after the moves, and the records: each once, in sorted order.
An untracked file inside a renamed folder moves with it, but is filed only if
it is a record.

**Output.** If the update is filed, `FILED <space path> <sha7>` for every
path, each with the one commit's `<sha7>`. If any path is refused,
`REFUSED <space path>: <profile|reference|id> line <n>` for each refused
path, and nothing else: a refused path refuses the whole commit, and no path
is filed.

1. Start from the tip:

   ```
   git -C <space root> fetch origin
   git -C <space root> rebase --autostash origin/main
   ```

2. Check every path, before any rename is made:

   ```
   SPACE=<space root> sh <skill dir>/check.sh --move <from> <to> ... <record> ...
   ```

   Give one `--move <from> <to>` per rename, in order, then the records. The
   script reads each path where it is now and runs the three checks of
   section 1 on it under its path after the moves. A moved record whose id
   is the one at its old path on `origin/main` passes the id check: an id
   that moves with its record is neither new nor a duplicate. A moved
   evidence, decision or handoff record must also be unchanged from its old
   path. If the script prints any `REFUSED` line, print those lines and
   stop. Nothing has changed. A `bad rename` or `no such record` line from
   the script is an error for the caller: report it and stop.

3. Make the renames, in order, then commit once. For each rename:

   ```
   mkdir -p <space root>/<folder that holds to>
   git -C <space root> mv -- <from> <to>
   ```

   Skip a rename whose `<from>` is gone and whose `<to>` is present: an
   earlier run made it. If a `git mv` fails, undo the renames already made
   (step 6) and stop. Then:

   ```
   git -C <space root> add -- <record> ...
   git -C <space root> commit -m "Integrate <change id>" -- <from> <to> ... <record> ...
   ```

   The commit names every `<from>`, every `<to>` and every record, so it
   holds the renames and the edits, each file as the check read it, and no
   other change. If git reports nothing to commit, or that a `<from>` matches
   no file, an earlier run made the commit; go on to step 4.

4. Bring the commit onto the tip, and find it:

   ```
   git -C <space root> fetch origin
   git -C <space root> rebase --autostash origin/main
   git -C <space root> log -1 --format=%H -- <first to>
   ```

   `<first to>` is the first rename's `<to>`, and the last command prints
   `<commit>`. Run step 2's check again, with the same arguments, since the
   rebase may have brought in a record that now holds an id. If it prints
   any `REFUSED` line, undo the commit with
   `git -C <space root> reset -q --soft HEAD~1`, undo the renames (step 6),
   print those lines, and stop.

5. Push and confirm as section 2 does in its steps 4 and 5:
   `git -C <space root> push origin HEAD:main`, repeating step 4 after a
   rejected push, three pushes at most. After a rebase conflict, run
   `git -C <space root> rebase --abort`. After a conflict or a third
   rejected push, print nothing and tell the caller that filing stopped.
   Otherwise fetch, and only if
   `git -C <space root> merge-base --is-ancestor <commit> origin/main` exits
   0, print `FILED <space path> <sha7>` for each path the check printed as
   `CHECKED`, in its order.

6. To undo the renames, move each one made back, the last first:

   ```
   mkdir -p <space root>/<folder that holds from>
   git -C <space root> mv -- <to> <from>
   ```

   The records keep their content.

## Desk run

When the caller asks for a desk run, run the check script (section 1) as
written, since it only reads. Then print each command of section 2 for each
`CHECKED` record, in order, with the space root, path and message filled in
and `<commit>` left as it is, and run none of them. A desk run prints no
`FILED` line. In integrate mode, run step 2's check, then print the commands
of steps 1 and 3 to 5, filled in the same way.

## Never

- Print a matched line, a pattern list or a value from one, or write any of
  them inside the space.
- Commit more than one record in a commit, outside integrate mode (section
  3), its only exception; or commit a file it was not given. In integrate
  mode, the tracked files under a rename count as given.
- Force-push, push anything other than `HEAD:main`, or create a branch in the
  space.
- Write a space listed `access: ro`. This skill commits only in the space's
  own repo; it never commits to the bus or moves the space's gitlink there.
