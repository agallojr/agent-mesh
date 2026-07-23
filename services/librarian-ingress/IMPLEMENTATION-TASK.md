# Task brief — deploy the librarian ingress Worker

For a pinned agent-mesh agent. Goal: stand up the `note_to_librarian` MCP ingress
so the Android phone (personal account) can hand notes to the librarian.

## Deliverable
A deployed Cloudflare Worker at a stable HTTPS URL whose `/mcp` endpoint answers
MCP over Streamable HTTP and, on `note_to_librarian`, commits a `library.submit`
addressed `role:librarian` into `agent-mesh-bus` (in `tasks/roles/librarian/`, the
librarian's role queue — the librarian drains it, it is not claimed as a task).

## Steps
1. Land these files into the repo (recommended: a new `services/librarian-ingress/`
   directory in `agent-mesh`, or its own repo under the same owner). Do not put
   the Worker in a place that mixes it with the node skills.
2. Create a **fine-grained GitHub PAT**: repo access = **agent-mesh-bus only**,
   Contents: Read and write. No other permissions.
3. Generate a connector token: `openssl rand -hex 32`.
4. `npm install` then set secrets:
   `wrangler secret put CONNECTOR_TOKEN`, `wrangler secret put GITHUB_TOKEN`.
5. Confirm the `[vars]` in `wrangler.toml` match the live mesh
   (`BUS_OWNER`, `BUS_REPO`, `BUS_BRANCH`, `LIBRARIAN_ROLE`, `SENDER_ID`).
6. `wrangler deploy`. Run the three smoke-test curls in README.md; confirm the
   third produces a file under `tasks/roles/librarian/` in the bus.
7. Register the Worker `/mcp` URL as a custom connector on the **personal** Claude
   account. If the connector UI offers only OAuth (no static bearer/header field),
   STOP and flag it — a small OAuth shim is needed before this can register.

## Verified against the live protocol
These were the open questions from the drafting session; they are now resolved
against `product/spec/PROTOCOL.md` and `product/skills/mesh-on/poller-prompt.md`:
- **Queue + type.** The librarian ingests a **`library.submit`** from its own role
  queue **`tasks/roles/librarian/`** and *drains* it (no status file, no claim, no
  outbox) — it does NOT curate a generic `task.request`. The Worker was reworked to
  emit `type: library.submit` with the library-record header (`category`, `title`,
  `provenance`, `discovered_by`/`_on`, `retention`) instead of a task body. The
  protocol's former separate `mailbox/roles/librarian/` was collapsed into this one
  queue (one inbox per role).
- **Sender id.** `from: op-phone` is a sanctioned operator id (the `mesh-post`
  skill reserves `op-phone` for mobile); no `agents/*.yaml` manifest entry is
  needed for a bare operator id.
- **Schema.** `schema_version: 1` is current.

## Still to confirm at deploy time
- That the node holding `librarian` is actually online and polling; an unstaffed
  queue just accumulates (correct, not a fault) until a librarian runs.
- The `DEFAULT_CATEGORY` (`lore`) suits the notes you expect from the phone, or
  pass `category` per call.

## Do NOT
- Write to Research Notes directly. Only the bus.
- Broaden the PAT beyond the bus repo.
- Commit `CONNECTOR_TOKEN` or `GITHUB_TOKEN` (use `wrangler secret`).
