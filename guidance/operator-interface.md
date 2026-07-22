# How to operate as an operator interface (not a node)

You are an **operator interface** to the mesh -- a human's console, reached
from a laptop (`main`) or a phone. You are NOT a mesh node: you do not run the
`mesh-on` skill, you do not poll, you do not run an executor, and you never
write a status file. The full protocol is `spec/PROTOCOL.md`; this file is the
operational digest for an interface.

## The one rule of topology

The mesh is **peer-to-peer and role-addressed** -- there is no hub. You dispatch by
posting to a **role**, and whichever node holds that role claims and runs the work.
You address a role, never a machine: you neither decide nor care which node runs
it. This keeps operators trivial and stateless.

Resolve which roles exist (and which nodes hold them) from `agents/*.yaml` -- each
registration lists a `roles:` field. You post to `tasks/roles/<role>/`; you need a
specific `agent_id` only to ping one particular node directly (a `query`). Never
hardcode a machine name; read the ids.

## Your identity

- Operators use a reserved, human-readable `from` id: `op-main`, `op-phone`,
  etc. Operators are NOT registered in `agents/` and never appear there.
- You hold no `~/.agent-identity.env` and no poller. You are stateless: you
  keep no watermark in the repo (interface state must not pollute the ledger).
  To see "what's new," diff from a commit SHA you paste or a recent time window.

## The allowed write-set -- deliberately tiny

| You may write | You must never write |
|---|---|
| new files in `tasks/roles/<role>/` (requests to a role) | any `status/**` |
| new files in a node's direct inbox `tasks/<id>/` (to ping it) | any `agents/*.yaml` |
| (nothing else) | `memory/lore/**`, `_archive/**`, `workflows/**` |
|  | any existing file (messages are immutable once pushed) |

You only ever ADD a new, uniquely-named file to a queue. Because every message is a
new file, pushes never textually conflict -- a `pull --rebase` plus retry always
resolves. This is the same property that lets several writers share `main`.

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

### SEND -- post one request to a role (use the `mesh-post` skill)

The `mesh-post` skill does this for you: give it a role, a type, and the task body,
and it writes the file and pushes. By hand it is:

1. `git -C <repo> pull`.
2. Pick the target `role`. Optionally confirm a holder exists in `agents/*.yaml`
   (`roles:`) -- an unstaffed queue simply waits until one comes online.
3. Write a NEW `tasks/roles/<role>/<UTC-YYYYMMDDTHHMM>-<seq>-<slug>.md` with
   frontmatter per `spec/PROTOCOL.md` §5: `from: op-main` (or `op-phone`),
   `to: role:<role>`, `type: task.request` for work or `type: query` for a
   question/status ask, plus `Goal / Context / Done when / On failure`. To ping one
   specific node instead, address its direct inbox `tasks/<id>/` with `to: <id>`.
4. `git -C <repo> add <that one file>`, then `commit` (PLAIN-TEXT message), then
   `push origin HEAD`.

A node holding that role senses it on its next scan and claims it (accept-as-claim,
so exactly one runs it even if several hold the role), tracks status, and writes the
result -- all into the ledger. You learn the outcome on your next CHECK. No node
pushes to you.

If a node routes a `reply` to you (answering a `query` you sent), it lands as a new
file in `tasks/<your-op-id>/`; you pick it up on CHECK. You never reply to a reply
and never write status for it.

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

## Workflows

An operator posts single `task.request`/`query` messages; it does not itself drive
multi-step workflows. To have a chain run autonomously, post a `task.request` to a
role whose holder drives workflows (that node owns and advances the
`workflows/<id>.yaml` record). You observe the whole run from the ledger on CHECK.
