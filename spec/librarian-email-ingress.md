# Email ingress (email-monitor role)

**schema_version: 1**
**Status: draft, v1 — extension to `spec/PROTOCOL.md`**

A second inbound path into the mesh **library**: the holder of a new
single-holder **`email-monitor`** role watches a Gmail mailbox. A message that is
provably from an allowed sender **and** carries the shared secret key is treated
as an instruction. For v1 the only instruction honored is **push a learning** —
the email-monitor validates the mail, strips the secret, and posts a sanitized
`library.submit` onto the bus; the `librarian` then drains it into the library
exactly as it drains any other submission. Attachments are included.

This is a companion to the existing `services/librarian-ingress/` Worker. That
path lets the phone (personal Claude account) hand a note to the librarian by
calling an MCP tool that writes a `library.submit` into the bus. This path needs
no Worker: the **email-monitor node reads the mailbox itself** and posts the same
`library.submit` the Worker would. All three of these — Worker, email-monitor,
and ordinary node self-submission — converge on the one `library.submit` queue
the librarian drains (PROTOCOL §5, §7).

**Why a separate role, not a librarian duty.** An earlier draft had the librarian
read the mailbox and write `memory/` inline. Splitting the mailbox-watcher into
its own role is strictly better:

- **Least privilege for credentials.** The Gmail OAuth token and the shared
  secret attach to `email-monitor`, not `librarian`. A node that is *only*
  librarian never holds an email credential; the secret has exactly one owner.
- **The secret never touches the bus by construction.** The email-monitor strips
  the `X-Mesh-Key` line before it composes the `library.submit`, so no bus path,
  commit, or record can ever carry it.
- **No PROTOCOL §7 exception.** "Only the librarian writes `memory/`, with no
  self-submission" stays literally true. The email-monitor is an ordinary
  *producer* — like the phone Worker — that submits and never writes `memory/`.
- **Auditability — the point of using the bus.** Every accepted email becomes a
  `library.submit` visible in the ledger, and every *rejected* email leaves a
  metadata-only audit breadcrumb (§9). Hostile attempts are visible on the bus,
  not just in a node-local log.
- **Separable later.** email-monitor and librarian are co-held on one node today
  (§4), but nothing forces that; the watch-mailbox duty can move to a different
  node from the curate-library duty without touching either's contract.

---

## 1. Why this exists

Posting to the bus from an arbitrary device is the problem the mesh keeps hitting:
a phone or a colleague's laptop has no git credential for the private bus and is
not a node. The phone case is solved by the ingress Worker. Email generalizes it:
anyone who can send mail — from any device, offline-composed, with attachments —
can hand the mesh a learning, **without** ever touching the bus, holding a bus
credential, or being a node. The email-monitor is the single privileged reader of
that mailbox; the librarian remains the single privileged writer of `memory/`;
email is just another producer feeding the one submission queue.

## 2. Scope

**In scope (v1):** a valid email becomes one `library.submit` message on the bus
(PROTOCOL §5), which the librarian folds into `memory/**` (PROTOCOL §7), plus any
attachments filed by pointer. Categories: `lore`, `experiments`, or any other
open library category (PROTOCOL §7), selectable per message, defaulting to a
configured category.

**Explicitly out of scope (v1), deferred until asked:**

- **Action requests** — email that asks the mesh to *do* something (originate a
  `task.request`, run a workflow). The design below leaves room for it (a message
  `intent`), but v1 accepts only `intent: learning` and **ignores** anything else,
  recording a one-line reject audit (no content, no secret).
- **KB queries by email** (ask a question, get a reply).
- **Replies / threading** back out by email.
- **Encrypted or signed-body mail** (PGP/S-MIME). v1 relies on transport auth
  (DKIM/DMARC) plus the shared secret, not message-body cryptography.

Adding any of these is a version bump of this document, mirroring PROTOCOL §10.

---

## 3. Trust model — the crux

**Email `From` is trivially spoofable. The sender allowlist alone MUST NOT be
trusted to authorize anything.** Authorization requires *all* of the following to
pass; any failure means the message is ignored and never acted upon:

1. **Transport authentication passes.** The message must show `dkim=pass` **and**
   `dmarc=pass` in Gmail's `Authentication-Results` header, with the DKIM/DMARC
   domain aligned to the `From` domain. This is what makes the `From` address
   meaningful at all. (Gmail computes these on receipt; the email-monitor reads
   the header — see §6.)
2. **Sender is on the allowlist.** The DKIM-verified `From` (not the raw display
   address) is a member of `LIBRARIAN_EMAIL_ALLOWED_SENDERS`. Match on the exact
   RFC-5321 address, case-insensitive, no substring or domain-suffix matching.
3. **Shared secret is present and correct.** The body carries the secret key on a
   dedicated line (§5), and it equals `LIBRARIAN_EMAIL_SECRET` under a
   **constant-time** comparison.

Only when 1 **and** 2 **and** 3 hold is the mail an instruction. This is
defense in depth: DKIM/DMARC stops `From` spoofing, the allowlist narrows *who*,
the secret proves the sender actually knows the pre-shared key (it defends
against a compromised-but-allowlisted account only weakly — see below — but
mainly against a look-alike that somehow passes 1–2).

**The mailbox is world-writable by definition** — anyone can send to it. Treat
every message as hostile until it clears all three checks. Additional hardening:

- **The secret is a credential.** It lives in `~/.agent-credentials.env` by
  **name** (`LIBRARIAN_EMAIL_SECRET`), value never in the bus, a message, a log,
  a status file, or a transcript (PROTOCOL §4.2/§4.4). The email-monitor **strips
  the secret line from the body before composing the `library.submit` or logging
  anything** and must never echo it. Because the secret is stripped upstream of
  the bus write, no bus path can carry it. Registration lists only the name in
  `credentials_available`.
- **Rotate the secret** on any suspicion, and on a fixed cadence. Rotation is a
  one-line edit to the credentials file on the email-monitor node; no bus change.
- **Content is still untrusted after auth.** Passing the three checks proves
  *origin*, not *intent safety*. Neither the email-monitor nor the librarian
  executes instructions embedded in the email body, follows links, or runs
  attachments — the payload is curated as data. v1's only action is "file this as
  a learning."
- **Prefer a dedicated ingress address** (e.g. a `+ingress` alias or a
  purpose-made account) so the watched surface is narrow and the allowlist +
  secret are the whole contract.

---

## 4. Mailbox conventions

- **Watched surface:** a single Gmail address or alias, plus an optional Gmail
  label that a server-side filter applies to candidate mail
  (`LIBRARIAN_EMAIL_LABEL`, default `mesh-ingress`). A Gmail filter that labels
  only mail passing SPF/DKIM is a recommended first-line narrower, but is **not**
  a substitute for the in-code checks in §3 — it is defense in depth.
- **Idempotency and ordering via the mailbox itself** (no extra state store, in
  the mesh's "use the medium as state" spirit): the email-monitor processes only
  **unread** messages under the watched label, oldest first, and on successful
  submission marks the message **read** and applies a `mesh-processed` label (and
  optionally archives it). A message that fails validation gets a `mesh-rejected`
  label and is marked read, so it is never re-examined. A crash between "pushed
  the `library.submit`" and "marked read" re-presents the message next cycle; the
  email-monitor MUST therefore be idempotent on the mail's RFC `Message-ID` (see
  §7, step 6) so a re-seen message does not post a duplicate submission.
- **One mailbox, one email-monitor.** `email-monitor` is a single-holder role
  (PROTOCOL §2, §10), like `librarian` and `archiver`. Two nodes polling the same
  mailbox would double-submit; keep exactly one holder.
- **Co-holding with `librarian`.** On the current deployment one node holds both
  `email-monitor` and `librarian`, so an emailed learning is read, submitted, and
  curated on the same node in the same cycle. This is a deployment choice, not a
  requirement — the two roles communicate only through the `library.submit`
  queue, so they may live on different nodes (see the attachment coupling in §8).

---

## 5. Message format the sender uses

A sender composes an ordinary email. Structure the email-monitor expects:

- **Subject** → the record `title`.
- **First body line** → the secret: `X-Mesh-Key: <secret>`. Stripped before
  anything is composed or logged; never leaves the email-monitor node.
- **Optional directive lines** immediately after, each `X-Mesh-<Field>: value`,
  consumed and stripped:
  - `X-Mesh-Intent: learning` — v1 accepts only `learning` (default if omitted).
  - `X-Mesh-Category: lore` — target library category; default
    `LIBRARIAN_EMAIL_DEFAULT_CATEGORY`.
  - `X-Mesh-Tags: build, cmake, hdf5` — comma-separated filing hints.
  - `X-Mesh-Contexts: frontier-login` — comma-separated contexts for the record
    header; default the email-monitor node's own `AGENT_CONTEXT`.
- **Remaining body** (Markdown) → the record body.
- **Attachments** → handled per §8.

Everything after the directive block is treated as opaque prose. A sender who
omits every optional directive still produces a valid learning in the default
category. Directive parsing is line-oriented and tolerant: an unrecognized
`X-Mesh-*` line is dropped with a logged warning, not a rejection.

---

## 6. Credentials and configuration

All values by **name** only; nothing below ever enters the bus. Non-secret
config rides `~/.agent-identity.env` (PROTOCOL §4.1); secrets ride
`~/.agent-credentials.env` (PROTOCOL §4.2) and appear in registration by name.
These are configured on the **email-monitor** node (which may also be the
librarian node).

**Non-secret (`~/.agent-identity.env`):**

```sh
LIBRARIAN_EMAIL_ENABLED=true
LIBRARIAN_EMAIL_ADDRESS=mesh-ingress@example.com        # the watched address/alias
LIBRARIAN_EMAIL_LABEL=mesh-ingress                       # Gmail label/query scope
LIBRARIAN_EMAIL_ALLOWED_SENDERS=alice@lab.org,bob@lab.org # exact addresses, csv
LIBRARIAN_EMAIL_DEFAULT_CATEGORY=lore
LIBRARIAN_EMAIL_POLL_SEC=300         # optional; defaults to POLL_INTERVAL_SEC
LIBRARIAN_EMAIL_MAX_ATTACH_MB=25     # per-attachment ceiling the node will fetch
```

(The `LIBRARIAN_EMAIL_*` prefix is kept for continuity with the credential names
below and the deployment's existing config; the *duty* is the email-monitor's.)

**Secret (`~/.agent-credentials.env`), listed by name in registration:**

```sh
GMAIL_LIBRARIAN_OAUTH=...    # mailbox read/modify credential (see below)
LIBRARIAN_EMAIL_SECRET=...   # the shared key senders must include
```

**Mailbox access mechanism (implementer's choice, but):** prefer the **Gmail API
with a narrowly-scoped OAuth token** (`gmail.modify` is enough: read, label, mark
read) over IMAP app passwords, because it exposes `Authentication-Results` cleanly
and supports precise label queries. Whatever is chosen, the credential is scoped
to this one mailbox and to the minimum permission that supports read + label +
mark-read. If the required credential name is absent, the email-monitor logs the
missing **name** and disables the email duty for the session (mirrors PROTOCOL
§4.2's "blocked on missing credential name" posture) — it does not crash the poll
loop.

**TLS interception (corporate proxies).** A node behind a TLS-inspecting proxy
(e.g. Zscaler) is served Google endpoints re-signed by the proxy's CA, which
OpenSSL 3 may reject (`CERTIFICATE_VERIFY_FAILED: Basic Constraints ... not marked
critical`). Do NOT disable verification — verify against the OS trust store, which
already trusts the MDM-installed proxy CA. On macOS the email-monitor calls
`truststore.inject_into_ssl()` (verify via the Keychain) before any Gmail request;
on Linux, point `SSL_CERT_FILE` at the exported proxy root CA. Verification stays
ON either way. Note the proxy may intercept the Gmail data plane
(`gmail.googleapis.com`) even when it lets the token endpoint
(`oauth2.googleapis.com`) through, so a working token exchange does not imply a
working mailbox read — test the data-plane call.

---

## 7. Ingest pipeline

Two roles, two stages, joined by the `library.submit` queue. Each runs inside the
existing poll loop (PROTOCOL §8) as a role-specific duty.

### 7a. Email-monitor duty (only if `email-monitor` held and `LIBRARIAN_EMAIL_ENABLED`)

Reuses the node's cadence; `LIBRARIAN_EMAIL_POLL_SEC` may throttle it
independently if set.

1. **List** unread messages under `LIBRARIAN_EMAIL_LABEL`, oldest first, bounded
   batch (e.g. ≤ 20/cycle to stay proportional to work).
2. **Authenticate (§3).** Read headers; require `dkim=pass` + `dmarc=pass` with
   aligned domain, `From` ∈ allowlist, and correct secret (constant-time). On any
   failure: write a reject audit (§9), label `mesh-rejected`, mark read, and
   continue. Never compose a `library.submit` for a rejected message.
3. **Parse (§5).** Extract title, directives, body; strip the secret and directive
   lines. Enforce `X-Mesh-Intent: learning` (else reject as out-of-scope for v1).
4. **Attachments (§8).** Fetch each (≤ `LIBRARIAN_EMAIL_MAX_ATTACH_MB`); route
   text vs. blob; produce pointers for anything that cannot enter the bus.
5. **Post the `library.submit`.** Compose the message envelope + inline library
   record header (below) and write it to `tasks/roles/librarian/<ts>-<seq>-<slug>.md`,
   then `sync` per PROTOCOL §8 (add/commit/push, literal `-C <REPO_PATH>`,
   pull-rebase-retry on rejection). This is an ordinary submission: **no status
   file, no claim** (PROTOCOL §5). The secret is already stripped (step 3), so it
   cannot appear here.
6. **Idempotency key.** Set `email_message_id: <RFC Message-ID>` in the submission
   header. Before posting, if a `library.submit` for this `email_message_id` was
   already queued or curated (scan `tasks/roles/librarian/` and a small
   `outbox/<email-monitor-id>/.ingested-emails` index the email-monitor maintains),
   skip the post and just mark the mail processed — this closes the
   crash-between-push-and-mark window (§4). See §10 for the librarian's own
   second-line dedup.
7. **Mark processed.** Label `mesh-processed`, mark read (and optionally archive).

**`library.submit` message the email-monitor posts (PROTOCOL §5 envelope + §7
record header, mirroring the Worker path):**

```yaml
---
schema_version: 1
id: <ts>-<seq>                           # the message id (queue filename stem)
from: <email-monitor AGENT_ID>
to: role:librarian
type: library.submit
created: <ISO8601 now>
category: <X-Mesh-Category | LIBRARIAN_EMAIL_DEFAULT_CATEGORY>
title: <email Subject>
provenance: human
contexts: <X-Mesh-Contexts | email-monitor AGENT_CONTEXT>
discovered_by: <sender address>          # the human origin, not the node
discovered_on: <email Date, UTC date>
retention: permanent-until-superseded
email_message_id: <RFC Message-ID>       # idempotency key; not a secret
tags: [<X-Mesh-Tags…>]                    # if present
source: "email:<sender address>"
artifacts: [<attachment pointers…>]       # if any (§8)
---

<the parsed Markdown body — secret and directive lines already stripped>
```

### 7b. Librarian duty — unchanged

The librarian drains `tasks/roles/librarian/` exactly as today (PROTOCOL §7,
poller-prompt): for each `library.submit` it dedupes, validates the header,
assigns the final `id`, sets any category-specific verification, writes
`memory/<category>/<slug>.md`, and updates `memory/index.md`. It does **not** know
or care that this submission came from email rather than the Worker or a node —
the envelope is identical. No librarian-side change is required.

For `category: lore`, the librarian sets the lore-specific fields per PROTOCOL §7
(`verified_on`, `confidence`, `supersedes`) using its normal curation judgment —
an emailed lore note is not auto-`verified`; it is treated like any submitted note.

---

## 8. Attachments — honoring the blob rule

Because the email-monitor reads Gmail directly, attachment bytes **never transit
the bus queue**. The single invariant that still binds is that the **bus itself
holds no blobs**: `memory/**` (and every queue message) is text and pointers, and
the git gate rejects blob-class files (blocked extensions, or > 5 MB) — see
PROTOCOL §7 and `hooks/git-gate.py`. So the email-monitor routes each attachment
as it composes the submission:

- **Text-class and small** (`.md`, `.txt`, `.json`, `.yaml`, within the gate's
  limits): may be inlined into the submission body (or referenced as its own
  intended `memory/<category>/` record) — it is exactly the kind of small text the
  library holds.
- **Blob-class** (binary, or over the gate's size/extension limits): filed into
  the **downstream file store** — the "Research Notes"/any-file store that lives
  **outside** the bus — and referenced from the submission by **pointer** in
  `artifacts[]` (a path, URL, or object id), per PROTOCOL §6/§7 "pointers, not
  payloads." The bus record captures the learning; the store holds the file; the
  pointer joins them.

The email-monitor decides the split by extension and size, mirroring the git
gate's own `BLOB_EXTS` / `BLOB_SIZE_LIMIT` so nothing that would be rejected at
the gate is ever staged. If a blob-class attachment arrives but no file store is
configured, the submission is still posted with a note that the attachment was
dropped and why — the learning is not lost for want of a place to put the binary.

**Coupling to flag when the roles are split across nodes.** The email-monitor
holds the attachment bytes, so **it** (not the librarian) must reach the external
file store to file a blob and mint its pointer. While email-monitor and librarian
are co-held (§4) this is moot. If they are ever separated, the file store must be
reachable by the email-monitor node; the librarian only ever sees the pointer in
`artifacts[]`.

---

## 9. Failure handling

Rejections are recorded on the bus, not just locally — that visibility is a
motivation for the role split. A **reject audit** is a metadata-only record the
email-monitor writes to its own `outbox/<email-monitor-id>/` (single-writer safe,
never `memory/`): `{email_message_id, dkim, dmarc, from, decision, category?,
ts}` — **never the body, never the secret, never attachment contents**. It shows
in the ledger diff like any other bus write.

- **Auth failure / spoof / missing secret:** write a reject audit
  (`decision: auth-failed` etc.), label `mesh-rejected`, mark read. No content,
  no secret. Silent to the sender otherwise — a hostile sender gets no oracle.
- **Out-of-scope intent (v1):** reject audit `decision: intent-unsupported`, same
  handling.
- **Missing mailbox credential name:** disable the email-monitor duty for the
  session, log the missing **name**, keep the rest of the poll loop running (no
  bus write — this is a node-config gap, not an ingress attempt).
- **Gmail API error / rate limit:** back off; leave the message unread so it is
  retried next cycle. Never mark read on a transient failure, and write no audit
  (nothing was decided).
- **Bus push rejection:** PROTOCOL §8 pull-rebase-retry; the mail stays unread
  until the `library.submit` is durably pushed, then it is marked processed.

## 10. Idempotency and single-writer

- **Two single-holder roles, two writers, no contention.** `email-monitor` is the
  sole writer of its own `outbox/**` and the sole poster of these `library.submit`
  messages; `librarian` remains the sole writer of `memory/**` (PROTOCOL §2, §10,
  writer table). Neither writes a path the other owns.
- **Two at-least-once boundaries collapse to exactly-once:**
  - *Mailbox → bus:* the email-monitor marks a mail read only **after** its
    `library.submit` is durably pushed, keyed on RFC `Message-ID` (§7a step 6), so
    a crash re-presents the mail and it is not double-posted.
  - *Bus → memory:* the librarian dedupes on `email_message_id` when draining
    (its normal submission dedup), so even a duplicate submission yields one
    `memory/` record.
- **No new bus *path* and no `.gitattributes` change.** `library.submit` rides the
  existing `tasks/roles/librarian/` queue; reject audits ride the existing
  `outbox/<agent-id>/`; `memory/index.md` stays union-merge-safe.
- **One new role name** (`email-monitor`) registered in `agents/<id>.yaml` like
  any other role; no protocol mechanism changes.

---

## 11. Changes required to the product

This feature is a new single-holder role plus config, not a new service. Landing
it touches:

1. **`spec/PROTOCOL.md`** — a short pointer under §7 (the library) noting email as
   a second ingress: the single-holder `email-monitor` role validates mail and
   posts a `library.submit`, which the librarian drains unchanged. The
   email-monitor always submits, never writes `memory/` — so §7's "only the
   librarian writes `memory/`, no self-submission" rule is unchanged.
2. **`skills/mesh-on/poller-prompt.md`** — add an `email-monitor` role-specific
   duty block (the §7a pipeline), guarded by `LIBRARIAN_EMAIL_ENABLED`. The
   `librarian` duty block is unchanged.
3. **`templates/*.env.template`** — add the §6 identity keys (non-secret) and the
   two credential **names** (commented, values filled per node, never committed),
   and note `email-monitor` in the `AGENT_ROLES` comment.
4. **Guidance** (`guidance/agent-operating.md`) — add `email-monitor` to the
   role-specific duties with a one-paragraph trust model (§3): allowlist is not
   authorization; DKIM/DMARC + secret are; the secret never touches the bus.
5. **No git-gate change** — the existing blob rejection already enforces §8.

---

## 12. Acceptance criteria / test plan

An implementation is correct when, on a node holding `email-monitor` (and, for the
end-to-end cases, `librarian`) with the duty enabled:

1. **Happy path (end to end).** An email from an allowlisted sender,
   DKIM/DMARC-passing, with the correct `X-Mesh-Key` and a Markdown body, produces
   a `library.submit` in `tasks/roles/librarian/` (secret stripped), which the
   librarian drains into a new `memory/<category>/<slug>.md` with the §7 header and
   an updated `memory/index.md`. The message is left read + `mesh-processed`. The
   secret appears in **no** file, message, commit, or log.
2. **Spoof rejected.** The same email with a forged `From` (DKIM/DMARC fail) posts
   **no** `library.submit`, writes a metadata-only reject audit to the
   email-monitor's outbox (no body, no secret), and is labeled `mesh-rejected`.
3. **Wrong/absent secret rejected.** Allowlisted, DKIM-passing, but missing or
   incorrect `X-Mesh-Key` → rejected, no submission posted.
4. **Non-allowlisted rejected.** DKIM-passing and correct secret but sender not on
   the allowlist → rejected. (Confirms the secret alone is not a bypass.)
5. **Attachment split.** An email with a `.md` attachment and a `.png` attachment
   inlines/points the `.md` and files the `.png` into the external store,
   referenced by an `artifacts[]` pointer in the submission; no blob is staged
   into the bus (the git gate does not fire because nothing blob-class was added).
6. **Idempotency.** Re-presenting the same `Message-ID` (simulated crash before
   marking read) posts no duplicate `library.submit`; and if one was already
   drained, the librarian's dedup yields no duplicate `memory/` record.
7. **Out-of-scope intent.** `X-Mesh-Intent: run-task` is rejected as unsupported
   in v1; no submission posted, reject audit `decision: intent-unsupported`.
8. **Missing credential name.** With `LIBRARIAN_EMAIL_SECRET` (or the OAuth name)
   absent, the email-monitor duty disables itself and logs the missing name; the
   rest of the poll loop — including the librarian duty — is unaffected.

## 13. Future (noted, not built)

- **Action intents** — `X-Mesh-Intent: task`/`workflow` that originate work into
  role queues, gated by a stricter authorization tier (per-intent allowlist, or a
  second secret) because the blast radius is larger than filing a note.
- **Email replies** — acknowledging back to the sender ("filed as `lore-0042`").
- **Signed bodies** (PGP/S-MIME) for senders whose provider can't guarantee
  DKIM alignment.
- **Splitting email-monitor and librarian across nodes** — supported by the
  design today (§4, §8); noted here as an untested deployment topology.
