/**
 * agent-mesh-librarian-ingress
 *
 * A remote MCP server (Cloudflare Worker) exposing a single tool,
 * `note_to_librarian`, that writes a `library.submit` message addressed to
 * `role:librarian` into the agent-mesh-bus ledger via the GitHub contents API.
 * The message lands in the librarian's ordinary role queue
 * (`tasks/roles/librarian/`); the librarian drains it (it is never claimed) and
 * files it into `memory/<category>/` on its next poll. See product/spec/PROTOCOL.md
 * §5 and §7 (one queue per role; the `type` field distinguishes a claimable task
 * from a drain-and-curate submission).
 *
 * It is the single privileged writer: the phone (personal Claude account,
 * Android app) calls the tool; this Worker holds the one GitHub credential and
 * commits to the bus. Nothing is ever written to Research Notes directly — the
 * librarian curates that on its own poll.
 *
 * Transport: MCP Streamable HTTP (JSON-RPC 2.0 over POST /mcp), stateless.
 * Auth (connector -> Worker): static bearer token (CONNECTOR_TOKEN).
 * Auth (Worker -> GitHub): fine-grained PAT (GITHUB_TOKEN), contents:write,
 *                          scoped to the bus repo only.
 */

const SERVER_INFO = { name: "agent-mesh-librarian-ingress", version: "0.1.0" };
const DEFAULT_PROTOCOL = "2025-06-18";

const TOOL_DEF = {
  name: "note_to_librarian",
  description:
    "Hand a small document to the mesh librarian for thoughtful filing into the " +
    "Research Notes knowledge base. Use when the operator learns something worth " +
    "persisting. Returns immediately; the librarian files it on its next poll — " +
    "no blocking wait.",
  inputSchema: {
    type: "object",
    properties: {
      title: {
        type: "string",
        description: "Short human title; also used as the filename slug.",
      },
      body: {
        type: "string",
        description: "The note itself, in Markdown. A small document (<= 64 KB).",
      },
      category: {
        type: "string",
        description:
          "Optional memory category to file under (e.g. 'lore', 'experiments', " +
          "'research-notes'). Defaults to the server's DEFAULT_CATEGORY. The " +
          "library category set is open; the librarian creates the category if new.",
      },
      tags: {
        type: "array",
        items: { type: "string" },
        description: "Optional filing hints (topics, project names).",
      },
      source: {
        type: "string",
        description: "Where it was learned: a URL, paper id, or 'phone convo'.",
      },
      filing_hint: {
        type: "string",
        description: "Optional steer on where in Research Notes it might live. Advisory only.",
      },
      idempotency_key: {
        type: "string",
        description: "Optional client key to dedupe retries (requires the IDEMPOTENCY KV binding).",
      },
    },
    required: ["title", "body"],
  },
};

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, server: SERVER_INFO });
    }

    if (url.pathname === "/mcp" || url.pathname === "/") {
      if (request.method === "OPTIONS") {
        return new Response(null, { status: 204 });
      }
      // Streamable HTTP GET opens a server->client SSE stream; we never push
      // server-initiated messages, so decline it.
      if (request.method === "GET") {
        return new Response("Method Not Allowed", { status: 405, headers: { Allow: "POST" } });
      }
      if (request.method !== "POST") {
        return new Response("Method Not Allowed", { status: 405 });
      }

      // --- auth: connector -> Worker ---
      const auth = request.headers.get("authorization") || "";
      if (!env.CONNECTOR_TOKEN || auth !== `Bearer ${env.CONNECTOR_TOKEN}`) {
        return json(
          { jsonrpc: "2.0", id: null, error: { code: -32001, message: "Unauthorized" } },
          401
        );
      }

      let msg;
      try {
        msg = await request.json();
      } catch {
        return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, 400);
      }

      const isNotification = msg && msg.id === undefined;
      const reply = await handleRpc(msg, env, ctx, isNotification);
      if (reply === null) {
        // notification: acknowledge with no body
        return new Response(null, { status: 202 });
      }
      return json(reply);
    }

    return new Response("Not Found", { status: 404 });
  },
};

async function handleRpc(msg, env, ctx, isNotification) {
  const { id, method, params } = msg || {};
  const ok = (result) => ({ jsonrpc: "2.0", id, result });
  const fail = (code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });

  switch (method) {
    case "initialize":
      return ok({
        protocolVersion: (params && params.protocolVersion) || DEFAULT_PROTOCOL,
        capabilities: { tools: {} },
        serverInfo: SERVER_INFO,
      });

    case "notifications/initialized":
    case "notifications/cancelled":
      return null;

    case "ping":
      return ok({});

    case "tools/list":
      return ok({ tools: [TOOL_DEF] });

    case "tools/call": {
      const name = params && params.name;
      const args = (params && params.arguments) || {};
      if (name !== "note_to_librarian") return fail(-32602, `Unknown tool: ${name}`);
      try {
        const out = await noteToLibrarian(args, env);
        return ok({
          content: [{ type: "text", text: out.text }],
          structuredContent: out.data,
        });
      } catch (e) {
        // Tool-level error surfaced to the model, not a protocol error.
        return ok({ content: [{ type: "text", text: `Error: ${e.message}` }], isError: true });
      }
    }

    default:
      return isNotification ? null : fail(-32601, `Method not found: ${method}`);
  }
}

async function noteToLibrarian(args, env) {
  const title = String(args.title || "").trim();
  const body = String(args.body || "");
  if (!title) throw new Error("title is required");
  if (!body) throw new Error("body is required");

  const maxBytes = Number(env.MAX_BODY_BYTES || 65536);
  if (byteLen(body) > maxBytes) {
    throw new Error(`body exceeds MAX_BODY_BYTES (${maxBytes})`);
  }

  const owner = req(env, "BUS_OWNER");
  const repo = req(env, "BUS_REPO");
  const branch = env.BUS_BRANCH || "main";
  const role = env.LIBRARIAN_ROLE || "librarian";
  const sender = env.SENDER_ID || "op-phone";
  const category = slugify(String(args.category || env.DEFAULT_CATEGORY || "lore"));

  // Optional idempotency guard (needs the IDEMPOTENCY KV binding).
  const idemKey = args.idempotency_key ? `idem:${args.idempotency_key}` : null;
  if (idemKey && env.IDEMPOTENCY) {
    const seen = await env.IDEMPOTENCY.get(idemKey);
    if (seen) {
      const data = JSON.parse(seen);
      return { text: `Already queued (idempotent): ${data.message_id}\nPath: ${data.path}`, data };
    }
  }

  const now = new Date();
  const ts = utcStamp(now); // YYYYMMDDTHHMMSS (UTC)
  const iso = now.toISOString();
  const day = iso.slice(0, 10); // YYYY-MM-DD (UTC)
  const slug = slugify(title);

  // Stateless uniqueness: try seq 0001..; GitHub returns 422 if the path
  // already exists, so bump the sequence and retry (mirrors mesh-post's
  // rebase-retry ethos).
  let lastBody = "";
  for (let seq = 1; seq <= 5; seq++) {
    const seqStr = String(seq).padStart(4, "0");
    const messageId = `${ts}-${seqStr}`;
    const path = `tasks/roles/${role}/${messageId}-${slug}.md`;
    const content = renderMessage({
      messageId, sender, role, iso, day, title, category, tags: args.tags,
      source: args.source, filingHint: args.filing_hint, body,
    });

    const res = await ghPutFile({
      owner, repo, branch, path, content,
      token: req(env, "GITHUB_TOKEN"),
      commitMsg: `post library.submit to role ${role} ${messageId}`,
    });

    if (res.ok) {
      const data = { status: "queued", message_id: messageId, path, commit_url: res.commitUrl };
      if (idemKey && env.IDEMPOTENCY) {
        await env.IDEMPOTENCY.put(idemKey, JSON.stringify(data), { expirationTtl: 86400 });
      }
      return {
        text:
          `Queued for the librarian as ${messageId}.\n` +
          `Path: ${path}\n` +
          `Commit: ${res.commitUrl}\n` +
          `The librarian will file it into Research Notes on its next poll.`,
        data,
      };
    }

    lastBody = res.body;
    if (res.status === 422) continue; // path exists -> bump seq
    throw new Error(`GitHub write failed (${res.status}): ${truncate(res.body, 300)}`);
  }
  throw new Error(`Could not allocate a unique message id after 5 tries: ${truncate(lastBody, 300)}`);
}

async function ghPutFile({ owner, repo, branch, path, content, token, commitMsg }) {
  const api = `https://api.github.com/repos/${owner}/${repo}/contents/${encodePath(path)}`;
  const res = await fetch(api, {
    method: "PUT",
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.github+json",
      "content-type": "application/json",
      "user-agent": "agent-mesh-librarian-ingress",
      "x-github-api-version": "2022-11-28",
    },
    body: JSON.stringify({ message: commitMsg, content: b64utf8(content), branch }),
  });

  if (res.ok) {
    const j = await res.json();
    return { ok: true, commitUrl: (j.commit && j.commit.html_url) || (j.content && j.content.html_url) };
  }
  return { ok: false, status: res.status, body: await res.text() };
}

function renderMessage(
  { messageId, sender, role, iso, day, title, category, tags, source, filingHint, body }
) {
  // Message envelope + inline library-record header (product/spec/PROTOCOL.md §5,
  // §7). A library.submit rides the librarian role queue and is drained, not
  // claimed, so it carries none of the task fields (priority/credentials/
  // depends_on/timeout). The librarian assigns the final record id and sets any
  // category verification (e.g. lore's verified_on/confidence); this supplies the
  // header fields the operator can provide plus the note body.
  const fm = [
    "---",
    "schema_version: 1",
    `id: ${messageId}`,
    `from: ${sender}`,
    `to: role:${role}`,
    "type: library.submit",
    `created: ${iso}`,
    `category: ${category}`,
    `title: ${JSON.stringify(String(title))}`,
    "provenance: human",
    `discovered_by: ${sender}`,
    `discovered_on: ${day}`,
    "retention: permanent-until-superseded",
  ];
  if (Array.isArray(tags) && tags.length) {
    fm.push(`tags: [${tags.map((t) => JSON.stringify(String(t))).join(", ")}]`);
  }
  if (source) fm.push(`source: ${JSON.stringify(String(source))}`);
  fm.push("---", "");

  const parts = [fm.join("\n")];
  if (filingHint) parts.push(`> filing hint: ${filingHint}`, "");
  parts.push(String(body).trim(), "");
  return parts.join("\n");
}

// --- helpers ---

function req(env, key) {
  const v = env[key];
  if (v === undefined || v === null || v === "") throw new Error(`Missing config: ${key}`);
  return v;
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function encodePath(p) {
  return p.split("/").map(encodeURIComponent).join("/");
}

function b64utf8(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function byteLen(str) {
  return new TextEncoder().encode(str).length;
}

function slugify(s) {
  const out = String(s)
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^\w\s-]/g, "")
    .trim()
    .replace(/[\s_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
  return out || "note";
}

function utcStamp(d) {
  const p = (n) => String(n).padStart(2, "0");
  return (
    `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}` +
    `T${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`
  );
}

function truncate(s, n) {
  s = String(s || "");
  return s.length > n ? s.slice(0, n) + "…" : s;
}
