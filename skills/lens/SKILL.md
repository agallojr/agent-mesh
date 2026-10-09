---
name: lens
description: Run one or more biased reviewer lenses (e.g. qc-skeptic) over a target file, note, or result, in parallel, each in its own subagent, then collect a side-by-side panel. Invoke when the user types /lens or asks for a lens / skeptic / panel review of a result.
allowed-tools: Read, Bash, Glob, Grep, Task, Write
---

# lens — fan out biased reviewers over a target

Usage: `/lens <lens[,lens...]|all> <target> [<target>...] [focus: <text>]`

The lens contract and review format live in
`<REPO_PATH>/product/lenses/README.md` — single source; read it, do not
restate it.

## 1. Resolve

- `REPO_PATH` from `~/.agent-identity.env` (fall back to the bus clone this
  session is in).
- Available lenses: directories under `<REPO_PATH>/product/lenses/` and
  `<REPO_PATH>/lenses/` (overlay wins on name). `all` means every one.
  Unknown name: list the available ones and stop.
- Targets to absolute paths; confirm each exists.
- Output dir: `<REPO_PATH>/agent-tmp/lens/<YYYYMMDDTHHMMZ>-<target-slug>/`.

## 2. Fan out

Spawn every requested lens in ONE message, in the background, with
`subagent_type: lens-<name>` (model: the lens default unless the user named
one). Each prompt carries: the target absolute path(s), the user's focus text
verbatim if any, and its output path `<out>/<name>.md`. Lenses do not see this
conversation; pass anything they need.

## 3. Panel

When all lenses have returned, read each review and write `<out>/panel.md`:
a table (lens, verdict, top objection, severity), then points where lenses
agree, then where they conflict. Do not adjudicate on the lenses' behalf
beyond that; the conflict is the signal.

## 4. Report

Final message: the panel table and the full absolute path of every review and
of `panel.md`.
