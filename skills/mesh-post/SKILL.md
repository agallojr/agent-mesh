---
name: mesh-post
description: Post one or more task/query messages into the agent mesh — addressed to a role (any holder claims it) or to a specific node's direct inbox — in one turnkey step. Writes schema-correct message files into the coordination repo, assigns globally-unique ids, and pushes. Use when you (as an operator, or as a node) want to ask a role to do something, fan one request out to several roles/nodes, or ping a node, in the hubless role-addressed mesh. Does not run the poller loop; it just drops messages.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# mesh-post — turnkey SEND for the mesh

The mesh is peer-to-peer and role-addressed: no hub. To get work done you drop a
message into a **role queue** (`tasks/roles/<role>/`) and whichever node holds that
role claims it; or into a node's **direct inbox** (`tasks/<agent_id>/`) to ping or
pin work to one node. This skill sends such messages and pushes them. It is the
operator's SEND verb (`guidance/operator-interface.md`); a node may use it too. It
writes only the message file(s) it creates — never `status/**`, never anything else.

`mesh-post.sh` (next to this file) owns all the mechanics — identity, pull,
**globally-unique id assignment**, schema-correct frontmatter, queue placement,
scoped commit, and pull-rebase-retry push. Your only real job is the **body**:
expand the user's intent into a self-contained task the claiming node can run with
no history of this conversation.

## What you supply vs what the script does

You supply (judgment the script can't do):
- **body** — a markdown file with Goal / Context / Done when / On failure (for a
  `query`, Goal + Context is enough). Inline every path, commit, branch, prior
  result, and lore id the reader needs. This is the intelligence; write it well.
- **target(s), type, title** — and optionally priority, timeout, credentials.

The script does (every mechanical, error-prone part — do NOT do these by hand):
- resolves `from` (AGENT_ID from `~/.agent-identity.env`, else `op-main`) and the
  repo path (REPO_PATH, else `--repo`);
- `git pull --rebase` first;
- assigns each message a **unique** id `<UTC-YYYYMMDDTHHMM>-<seq>`, where `<seq>`
  avoids every id already used this minute in any target queue, in `status/`, and
  earlier in the same run — so fanning one task out to N targets yields N distinct
  ids (status files are keyed by id in one global namespace, so shared ids collide);
- emits the §5 frontmatter and places each file in the right queue;
- **scope-commits only the files it wrote** (never `git add -A`), with a plain-text
  message, and pushes with up to 3 pull-rebase retries.

## Do this

1. Write the body to a temp file (e.g. `/tmp/mesh-post-body.md`). Make it
   self-contained; when fanning out to different OSes/nodes, write one body per
   variant and call the script once per variant.
2. Run the script:

```bash
<repo>/product/skills/mesh-post/mesh-post.sh \
  --to role:build --to role:geworker \
  --type task.request --title trilinos-spack-build \
  --priority normal --timeout-min 300 \
  --body-file /tmp/mesh-post-body.md
```

   Flags: `--to` (repeatable) is `role:<role>` or a bare `<agent_id>`; `--type` is
   `task.request` | `query` | `reply` | `task.cancel` | `library.submit` | …;
   `--title` is a kebab-case slug; optional `--priority low|normal|high` (default
   normal), `--timeout-min N` (default 120), `--credentials K1,K2` (KEY NAMES only,
   never values), `--depends-on id1,id2`, `--from <id>`, `--repo <path>`. Add
   `--dry-run` to write + stage without commit/push when you want to inspect first.

3. Report to the user in one line per target: the target, the assigned id, and the
   file path — and that they will see the outcome (status/reply) on their next
   CHECK of the ledger. You do NOT wait here; the claiming node's poller senses the
   message on its next scan and routes any `reply` into your inbox
   (`tasks/<from-id>/`).

## Notes

- **Type tells the consumer what it is.** `task.request`/`query`/`task.cancel` are
  claimable work (get a `status/<id>.json`); `library.submit` is drained by the
  librarian and gets no status; `reply` is information the recipient just surfaces.
- **Unstaffed role is fine.** Posting to a role no node currently holds just waits
  until one comes online. To check who holds a role:
  `grep -l "<role>" <repo>/agents/*.yaml`.
- **Git gate.** The script uses the literal `-C <repo>` form and a plain-text commit
  message, staging only its new files, so it stays inside the node git gate.
  Invoking mesh-post authorizes that one scoped commit+push — that is the skill's
  job; it does not touch the working tree's other changes.
