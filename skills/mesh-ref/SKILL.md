---
name: mesh-ref
description: Ingest one or more URLs into the mesh library as `refs` records, each with a companion summary. Research papers, slide decks, and images are RETRIEVED and stored in the bus (LFS) with a separate companion metadata/summary record; general web pages are kept as a pointer-only record with the summary in its body. If you hold the `librarian` role the records are written to `memory/refs/` directly; otherwise a `library.submit` is posted for the librarian to promote. Use when a human (operator or node) wants to file a web resource into durable memory with a summary. Each URL in a list is handled separately.
allowed-tools: Read, Write, Bash, Glob, Grep, WebFetch
---

# mesh-ref — ingest a URL into the library as a reference + summary

Turn each URL into a durable `refs` record (PROTOCOL §7). Two shapes, chosen per
URL by whether the source is worth storing:

- **Retrieve & store** — research papers (PDF), slide decks, images, and similar
  fixed documents worth preserving. Download the artifact into `memory/refs/`
  (LFS-tracked) and write a **separate companion `.md`** record — metadata plus the
  summary — because the artifact itself is binary and cannot carry front-matter.
- **Pointer-only** — a general web page (blog, docs site, news). Do NOT download it;
  write a single `.md` record whose front-matter points at the URL, with the
  summary as its body.

Given several URLs, handle each independently — one record (or record + artifact)
per URL, its own id and summary; a failure on one does not abort the rest.

`memory/**` has a single writer, the `librarian` role, so there are two execution
paths (Step 1): hold `librarian` → write to `memory/refs/` directly; otherwise →
post a `library.submit` and let the librarian promote it.

## Inputs

- **urls** — one or more URLs, from the skill args or asked for if none were given.
  Accept a whitespace/newline-separated list; de-duplicate before processing.
- **tags** (optional) — extra subject keywords to add to what the skill derives.

## Step 1 — resolve who you are, the repo, and the path

```bash
test -f ~/.agent-identity.env && cat ~/.agent-identity.env || echo "NO_IDENTITY"
```

- **Node** (identity present): repo is its `REPO_PATH`; `discovered_by` is its
  `AGENT_ID`. Direct-write path only if `AGENT_ROLES` includes `librarian`; else the
  submit path.
- **Operator interface** (no identity): `discovered_by` is the reserved operator id
  (`op-main`/`op-phone`); repo is the bus clone in this session. An operator never
  holds `librarian`, so always the submit path (operators may not write `memory/`).

Confirm git-lfs is available if you will store an artifact: `git lfs version`. If it
is missing, do not store raw — fall back to a pointer-only record and note it.

Emit every git command with a **literal absolute repo path** (`git -C /abs/repo …`);
keep commit messages plain text (no `;`, `&&`, `|`, `$(...)`, backticks).

## Step 2 — pull

```bash
git -C /abs/repo pull --rebase
```

## Step 3 — for EACH url: classify, fetch, summarize

1. **Classify** retrieve vs pointer-only:
   - **Retrieve** if the URL resolves to a document/binary: a PDF (by `.pdf`, or an
     arXiv/DOI paper — for an arXiv `abs/` page resolve to its `pdf/` URL), an image
     (`.png/.jpg/.jpeg/.gif/.webp`), or a slide/doc (`.pptx/.docx`). Confirm with the
     content type when unsure (`curl -sSI <url>` → `content-type`).
   - **Pointer-only** for `text/html` pages and anything not worth preserving as a
     file.
2. **Summarize**: read the content with `WebFetch` and derive `title`, `slug` (short
   kebab-case), and `tags` (3–8 subject keywords; `contexts` stays `[]`). For a
   research paper the exposition is TWO summaries at two altitudes (§4) — the
   abstract/intro alone is not enough for the deeper one, so read into the body
   (methods, results) to write it. If fetch fails (404, timeout, blocked), record
   the failure and move to the next URL.
3. **Provenance**: `retrieved_on` = current UTC (`date -u +%Y-%m-%dT%H:%M:%SZ`).

## Step 4 — build the record(s)

Body sections (the companion summary), numbers with units and UTC times per
best-practices §24/§25:

```
## What it is
One line: kind of resource, author/source, date if known.

## Semi-technical overview
Written for a bright non-specialist (calculus + basic linear algebra, but not an
expert in this subfield). Plain language: what problem it tackles, the core idea,
and why it matters. Define jargon on first use. Terse — a few tight paragraphs,
no hype. This is the wider-audience altitude; write it FIRST.

## Technical summary
Written for a specialist / graduate reader already fluent in the field. Assume the
vocabulary; go deeper than the overview: the actual method and its machinery, the
key equations or algorithm, complexity/resource claims, the experimental setup and
results, and where it sits relative to prior work. Precise, not padded.

## Key points
- Specifics worth remembering (findings, claims, APIs, numbers with units).

## Relevance
Optional: the topic/work this serves; link related library records by `id`.
```

The paper itself is the standard; the **technical summary** is the specialist
distillation and the **semi-technical overview** is the wider-audience one. A
non-paper resource (page, slide, image) may collapse these into a single
`## Summary` when a two-altitude split adds nothing.

**Retrieve case** — two files, shared `id` and `slug`:
- artifact `memory/refs/<id>-<slug>.<ext>` (the downloaded file)
- companion `memory/refs/<id>-<slug>.md` with front-matter:

```markdown
---
schema_version: 1
id: <ref-YYYYMMDD-NNNN>
title: <title>
category: refs
provenance: human
contexts: []
tags: [<keywords>]
discovered_by: <AGENT_ID or operator id>
discovered_on: <UTC date>
artifact: <id>-<slug>.<ext>        # local pointer to the stored file
source_path: <origin URL>
source_sha256: <sha256 of the stored file>   # sha256sum the downloaded file
retrieved_on: <UTC ISO-8601>
retention: permanent-until-superseded
---
```

**Pointer-only case** — one file `memory/refs/<id>-<slug>.md`, same header minus
`artifact` and `source_sha256`, `source_path` = the URL.

## Step 5 — write it (per path)

**Direct-write (you hold `librarian`):**
- Assign `id` = `ref-<UTC-YYYYMMDD>-<NNNN>` — next unused 4-digit seq for that date;
  list `memory/refs/` and scan `ref-<date>-*` filenames (id is the filename prefix,
  §7), max + 1 (`0001` if none today).
- Retrieve case: download the artifact (`curl -L -o memory/refs/<id>-<slug>.<ext>
  <url>`), `sha256sum` it into `source_sha256`, then write the companion `.md`.
- Pointer-only case: write the single `.md`.

**Submit (you do not hold `librarian`):**
- Write `tasks/roles/librarian/<UTC-YYYYMMDDTHHMM>-<seq>-ref-<slug>.md` as a
  `library.submit`, `category: refs`, with the record header + summary inline and,
  for a retrieve case, `source_path` plus a `retrieve: true` flag so the librarian
  fetches and stores the artifact on promotion (it, not you, writes `memory/`).
  Leave `id` unset (the librarian assigns it). Write no `status/` file.

## Step 6 — commit (plain text) and push

Three separate commands, literal repo path; on rejection `pull --rebase` then push,
up to 3 attempts then back off. Stage the artifact and its companion together.

```bash
git -C /abs/repo add /abs/repo/memory/refs/<files>
git -C /abs/repo commit -m "ingest refs <n> url(s) into library"
git -C /abs/repo push origin HEAD
```

(Submit path: stage the queue message; message e.g. `submit refs library.submit <n> url(s)`.)

## Step 7 — report

One line per URL: the URL, whether it was retrieved-and-stored or pointer-only, the
record id and path(s) (or, on the submit path, the submission path and that the
librarian will assign the id and promote it next cycle), and the one-line summary.
List any URLs that failed to fetch, with the reason. You do NOT wait for the
librarian on the submit path.

## Relationship to the other mesh verbs

- **mesh-post** — SEND a task/query to a role or node.
- **mesh-check** — READ what came back from the ledger.
- **mesh-ref** — INGEST a URL into the library as a reference + summary (this skill).
