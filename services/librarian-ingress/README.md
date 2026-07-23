# agent-mesh-librarian-ingress

A remote **MCP server** (Cloudflare Worker) that lets the **Android phone on the
personal Claude account** hand a small document to the mesh **librarian**. It
exposes one tool, `note_to_librarian`, and writes a `library.submit` addressed to
`role:librarian` into the **agent-mesh-bus** ledger via the GitHub contents API.
The submission rides the librarian's ordinary role queue (`tasks/roles/librarian/`);
the librarian drains it — it is never claimed as a task — and files it into
`memory/<category>/` on its next poll (see `product/spec/PROTOCOL.md` §5, §7).

It is the single privileged writer. The phone holds no git credential and is not
a mesh node — it only calls a tool. Curation into Research Notes stays behind the
librarian; this server only fills the librarian's queue.

```
phone ──note_to_librarian()──▶ this Worker ──GitHub API──▶ agent-mesh-bus:
                                                            tasks/roles/librarian/<id>-<slug>.md
                                                                    │ polled
                                                            librarian node ──▶ Research Notes
```

## Prerequisites

- A Cloudflare account with Workers, and `wrangler` (`npm i`).
- A **fine-grained GitHub PAT**: repository access = **agent-mesh-bus only**,
  permission **Contents: Read and write**. Nothing else.
- A long random **connector token** (e.g. `openssl rand -hex 32`).
- A **personal Claude plan that supports custom connectors** (Pro/Max). If your
  plan does not, this path is closed — stop here and ask for an alternative.

## Deploy

```bash
npm install

# secrets (never committed)
wrangler secret put CONNECTOR_TOKEN   # paste the random token
wrangler secret put GITHUB_TOKEN      # paste the fine-grained PAT

# optional: idempotency store, then uncomment the kv block in wrangler.toml
# wrangler kv namespace create IDEMPOTENCY

wrangler deploy
```

Confirm `BUS_OWNER` / `BUS_REPO` / `BUS_BRANCH` / `LIBRARIAN_ROLE` / `SENDER_ID`
in `wrangler.toml` match your mesh. Deploy prints the Worker URL, e.g.
`https://agent-mesh-librarian-ingress.<subdomain>.workers.dev`. The MCP endpoint
is that URL + `/mcp`.

## Smoke test (before wiring the phone)

```bash
URL=https://agent-mesh-librarian-ingress.<subdomain>.workers.dev/mcp
TOK=<CONNECTOR_TOKEN>

# handshake
curl -s $URL -H "authorization: Bearer $TOK" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'

# list tools
curl -s $URL -H "authorization: Bearer $TOK" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# post a real note (creates a commit in agent-mesh-bus)
curl -s $URL -H "authorization: Bearer $TOK" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"note_to_librarian","arguments":{"title":"Smoke test","body":"hello from curl","tags":["test"]}}}'
```

The third call should return a `queued` result and a commit URL; verify the file
landed under `tasks/roles/librarian/` in the bus.

## Register the connector (personal account)

claude.ai → **Settings → Connectors → Add custom connector** → URL =
`https://…workers.dev/mcp`.

**Auth caveat:** this Worker authenticates with a **static bearer token**. Verify
your connector UI lets you attach that token (a bearer/custom-header field). If
the UI offers **only OAuth**, this static-token design won't register as-is —
stop and request the small OAuth shim (a follow-up), rather than weakening auth.

Once registered, the tool appears in the **Android Claude app**. Say something
like *"librarian, keep this: …"* and Claude calls `note_to_librarian`.

## Configuration reference

| Key | Where | Default | Meaning |
|---|---|---|---|
| `CONNECTOR_TOKEN` | secret | — | Bearer token the phone presents. |
| `GITHUB_TOKEN` | secret | — | Fine-grained PAT, bus repo, contents:write. |
| `BUS_OWNER` | var | `agallojr` | Owner of the bus repo. |
| `BUS_REPO` | var | `agent-mesh-bus` | Bus repo name. |
| `BUS_BRANCH` | var | `main` | Branch to commit to. |
| `LIBRARIAN_ROLE` | var | `librarian` | Role queue: `tasks/roles/<role>/`. |
| `SENDER_ID` | var | `op-phone` | `from:` id on messages. |
| `DEFAULT_CATEGORY` | var | `lore` | `memory/<category>/` used when a call omits `category`. |
| `MAX_BODY_BYTES` | var | `65536` | Reject bodies larger than this. |
| `IDEMPOTENCY` | KV (optional) | — | Enables `idempotency_key` dedupe. |

## Design notes / limits

- **Stateless IDs:** id is `<UTC-seconds>-<seq>`; on a GitHub 422 (path exists)
  the Worker bumps `seq` and retries up to 5. Single-user + seconds granularity
  makes collisions vanishingly rare.
- **Idempotency** is opt-in via the KV binding + a client `idempotency_key`;
  without KV the key is ignored.
- **No session state** (no `Mcp-Session-Id`); every call is independent.
- **Writes only the bus**, never Research Notes — the librarian is the gate.
- **`library.submit`, not `task.request`.** The message rides the librarian's role
  queue but is drained, not claimed: the Worker writes no `status/` file and the
  librarian produces no outbox result — the `memory/<category>/` record is the
  outcome. `category` is a tool argument (default `DEFAULT_CATEGORY`); the library
  category set is open.
- The librarian's task-completion/ack convention is unchanged and lives on the
  librarian side; this server only produces well-formed input for it.
