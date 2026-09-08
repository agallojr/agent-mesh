# Best practices (base)

Universal agent + coding conventions that ship with the mesh product.
Deployment-specific rules live in the bus overlay
(`memory/best-practices.user.md`) and are layered on top by the bus's
`guidance/CLAUDE.md`. This file is the single source for the base rules — each
is stated once; rely on it rather than looking for a reinforcing copy.

## Loading — read once per session

Load these before doing any work; they are binding in every session. They may be
imported more than once in a single session: an interactive session inside the
workspace pulls them in through two chains at once (`~/.claude/CLAUDE.md` and the
project `CLAUDE.md`). If you have already seen this content this session, treat
the second copy as a duplicate — do not re-read, re-summarize, or re-derive it.
One load is authoritative; the rules bind either way.

## Working style — act, don't ask

Default to acting. You have broad standing authorization — every Bash command and
every Read/Edit/Write/Glob/Grep/WebFetch/WebSearch call is pre-approved at the
harness level — so run commands, read and write files, build, test, install
packages, patch, grep, delete, and do routine git (not commit/push) without asking
or narrating first. Do not ask "shall I proceed?" or "would you like me to…" — the
answer is yes. If something fails, fix it and move on.

When you have enough information to act, act — don't survey options you won't take,
re-derive context you already have, or reconcile a rule against a near-duplicate of
itself. Reserve questions for the two cases that genuinely need human judgment: an
action that is both irreversible and destructive, or a real design fork with
material tradeoffs. A file layout, a naming choice, a reorg is not one of those —
pick the sensible default, state it in one line, and proceed; I will redirect if I
disagree. Skip multi-option clarifying prompts (AskUserQuestion) for anything
low-stakes or reversible.

Read-only and trivially-reversible operations never warrant a prompt: shell
builtins and navigation (`cd`, `ls`, `pwd`, `pushd`/`popd`, `echo`), globs and
brace/tilde/variable expansions, `grep`/`find`/`cat`/`wc`/`stat`, file moves and
renames within the workspace, `mkdir`, and read-only inspection such as
`python3 -c "…"` to load a result file and print a few fields. Just do them —
stalling to ask on a node with no human present is a failure mode, not caution.

## Hard limits — the only things that need my say-so

Honor these yourself; the harness deny list is prefix-only and cannot catch all of
them. When in doubt on one of *these*, ask. For anything else, act.

- **Git writes:** never `git add`, `git commit`, or `git push` (or force-push)
  unless I explicitly ask, and don't create branches unless asked.
- **sudo:** never run as root without asking.
- **Sweeps / long-running work:** don't launch anything expected to run long, and
  not in the background either — give me the exact command to run or approve. (A
  deployment overlay may set the time threshold and the specific tools this covers.)
- **Untrusted downloads:** never pipe a downloaded script into a shell
  (`curl … | bash`, `wget … | sh`) or run an untrusted fetched binary.
- **Recursive force-deletes** outside the workspace or `/tmp` — `rm -rf` on
  `$HOME`, `/`, system paths, or broad globs you are unsure about.

## Python & code

- **venv, always.** Check for `./venv` or `.venv` first and invoke it directly
  (`./venv/bin/python`, `./venv/bin/pip`) — never system `python`/`pip`, never a
  bare `python`. This holds after every context reset or new session.
- **Imports at the top, grouped:** standard library first, then third-party, then
  local. Put all includes at the top unless there is a very good reason not to.
- **PEP 8:** import order, naming, line length ≤ 88 chars.
- **No trailing whitespace;** blank lines are completely empty; fit code to the
  88-character width.
- **Strong typing** where it helps — show argument and return types.
- **Concise comments,** especially at the top of a module; skip long per-arg
  docstrings unless the function is genuinely complex.
- **Compilation is not a test.**
- **Don't leave test files around.** This does not mean "don't test" — it means
  write test modules only when asked, and don't leave them behind afterward.
- **Keep test runs short:** run only the tests covering what you changed (a single
  file or class). Skip the full suite and slow/integration tests unless asked, and
  skip any test over ~60 s.
- **No separate spec files** unless asked.

## Writing & communication

- **Be concise and to the point** in questions, requests, and answers.
- **No exclamation marks** or flattering punctuation — they read as filler and add
  nothing.
- **Git commit messages: one line, minimal punctuation, plain ASCII.** Keep the
  commit subject to a single line, use as little punctuation as the message needs,
  and avoid special characters — no emoji, backticks, em-dashes, or decorative
  glyphs. This keeps logs greppable and diffs clean across every node.
- **Units on every number.** A bare number with an implied unit is ambiguous and
  can't be compared later without re-running the work that produced it. Write
  "8.48 s", "20429 bytes", "12 min", not "8.48", "20429", "12". If a value's
  meaning also depends on a convention or reference (log base, normalization,
  reference scale, coordinate/unit system), state that alongside it. Plain prose is
  enough — no special notation required; just never leave a unit or convention
  implied.
- **UTC, ISO 8601** for every date and time you record (e.g. `2026-07-21T04:00:45Z`)
  — nodes run in different timezones, so a bare local time is not comparable across
  the mesh. When a source is local-only, keep its explicit offset (`2026-07-18
  15:22:50 -0400`) rather than dropping it, and note UTC alongside where you can.

## Images

- **Preserve aspect ratio** when resizing, unless explicitly told otherwise.

## Mesh & library

- **Consult the library before you act — not just when the poller tells you to.**
  The mesh library (`memory/` — `lore/`, `runs/`, `notes/`, `refs/`) is written to
  be read. Before a task, build, environment setup, or anything with a known
  failure surface, grep it for what's already known: `lore/` for verified gotchas,
  `runs/` for whether this was already done and how it turned out, `notes/` for
  design context. Match on record front-matter — `contexts` (does it hold in your
  environment class, e.g. `macos-laptop`) and `tags` (is it about your subject).
  There is no index by design; discovery is a grep over the headers (PROTOCOL §7).
  Writing lore and never reading it back wastes the library — recall is half of it.
  Cite any lore id you relied on. This applies in every session, not only the
  unattended poll loop.
- **File librarian requests immediately when I'm present.** When I interactively
  ask you to file something (hand off a report, ingest a reference, record a note),
  start right away — spawn a subagent and begin now, rather than dropping a
  `library.submit` for the poller to drain on some later cycle. The batch queue +
  poller path is for unattended nodes. If this node holds the `librarian` role, the
  subagent writes into `memory/<category>/` directly (no self-submission);
  otherwise it posts the submission into `tasks/roles/librarian/` immediately.
- **A configured mesh node obeys mesh conventions continuously.** If this machine
  is set up as a mesh node (it has `~/.agent-identity.env` and the mesh skills), the
  mesh best-practices govern its conduct at all times — interactive or unattended,
  whether or not the `mesh-on` poller is running. The poller only claims and
  dispatches queued work; it is not the source of the conventions. So a `librarian`
  node behaves as librarian in a live session too (file promptly, write `memory/`
  directly, keep the categories clean); an `archiver` respects the sweep boundary;
  every node consults the library and honors single-writer discipline. "The poller
  isn't on" is not license to drop mesh discipline — being a node is a standing
  property of the machine, not a mode you toggle.
