# How to operate as an operator interface (not a node)

You are an **operator interface** to the mesh -- a human's console, reached
from a laptop (`main`) or a phone. You are NOT a mesh node: you do not run the
`mesh-on` skill, you do not poll, you do not run an executor, and you never
write a status file. The full protocol is `spec/PROTOCOL.md`; this file is the
operational digest for an interface.

## The one rule of topology

The mesh is a **star**: one hub, worker spokes. **Operators talk only to the
hub.** You never address a worker directly -- the hub decides which worker does
what and fans the work out. This keeps one brain in charge of dispatch and keeps
operators trivial and stateless.

Resolve the hub from `agents/*.yaml` -- it is the entry with `role: hub` (today
`241f3c`, name `hub-laptop`). Never hardcode a machine name; read the id.

## Your identity

- Operators use a reserved, human-readable `from` id: `op-main`, `op-phone`,
  etc. Operators are NOT registered in `agents/` and never appear there.
- You hold no `~/.agent-identity.env` and no poller. You are stateless: you
  keep no watermark in the repo (interface state must not pollute the ledger).
  To see "what's new," diff from a commit SHA you paste or a recent time window.

## The allowed write-set -- deliberately tiny

| You may write | You must never write |
|---|---|
| new files in `tasks/<hub-id>/` (requests TO the hub) | any `status/**` |
| (nothing else) | any `agents/*.yaml` |
|  | any worker inbox `tasks/<worker-id>/` |
|  | `memory/lore/**`, `_archive/**`, `workflows/**` |
|  | any existing file (messages are immutable once pushed) |

You only ever ADD a new, uniquely-named file to the hub's inbox. Because every
message is a new file, pushes never textually conflict -- a `pull --rebase` plus
retry always resolves. This is the same property that lets several writers share
`main`.

## Two verbs

### CHECK -- read the ledger (read-only, the common case)

1. `git -C <repo> pull` (or `fetch` + `reset --hard origin/main` if a rebase
   balks -- an interface has nothing local to lose).
2. `git -C <repo> log --stat <since>..HEAD`, where `<since>` is a SHA you paste
   or a time window (`--since=2.hours`).
3. Read the changed files under `status/ outbox/ tasks/ agents/ memory/lore/`
   and summarize what happened: task outcomes, replies, new nodes, lore, sweeps.

The ledger is the source of truth. You reconstruct status from git history, not
from anyone messaging you -- so an interface being offline loses nothing.

### SEND -- drop one request into the hub's inbox

1. `git -C <repo> pull`.
2. Read `agents/*.yaml` to resolve the hub id (`role: hub`).
3. Write a NEW `tasks/<hub-id>/<UTC-YYYYMMDDTHHMM>-<seq>-<slug>.md` with
   frontmatter per `spec/PROTOCOL.md` section 5: `from: op-main` (or `op-phone`),
   `to: <hub-id>`, `type: task.request` for work or `type: query` for a
   question/status ask, plus `Goal / Context / Done when / On failure`.
4. `git -C <repo> add <that one file>`, then `commit` (PLAIN-TEXT message), then
   `push origin HEAD`.

The hub senses it on its next inbox scan, decides the worker(s), originates the
worker task(s), tracks status, and writes results -- all into the ledger. You
learn the outcome on your next CHECK. The hub does not push to you.

If the hub routes a `reply` to you (answering a `query` you sent), it lands as a
new file in `tasks/<your-op-id>/`; you pick it up on CHECK. You never reply to a
reply and never write status for it.

## Phone specifics (Claude Code on web / mobile app)

- Inference runs on your **personal Claude subscription** -- no Bedrock, no API
  key. The subscription is the credential.
- GitHub read + commit + **push work**, but push is restricted to the **current
  branch**. The mesh lives on `main`, so operate on `main`.
- There is no local git PreToolUse hook on a cloud session; your guardrail is
  this write-set. Worst case you can only ADD a new file to the hub's inbox --
  which any participant may do.
- Orient a fresh phone session in one step: "read guidance/operator-interface.md
  and check the mesh."

## Not yet supported

Kicking off a multi-step **hub workflow** from an interface needs a
`workflow.request` message type the hub recognizes in its inbox scan (today
workflows arrive via main's in-process message, which a phone cannot send).
Until then, an interface sends single `task.request`/`query` messages; the hub
may still choose to run a workflow in response.
