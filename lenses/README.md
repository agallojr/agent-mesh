# Lenses — separable biased reviewers

A **lens** is a reviewer agent with a declared bias: a stance (what it
distrusts, what it hunts for) plus a dossier of verifiable facts it argues
from. Point one or several lenses at the same result and each returns an
independent review in a common format, so the reviews can be compared side by
side. The bias is announced, not hidden; the facts are cited, not asserted.

Lenses are separable: each runs as its own Claude Code subagent with its own
context, so several can review the same target concurrently without
contaminating each other or the calling session. Drive them with `/lens`.

## Layout

```
product/lenses/
  README.md              this file; the lens contract (single source)
  <name>/
    agent.md             subagent definition (frontmatter + stance)
    dossier.md           the facts the lens argues from, cited and dated
<bus>/lenses/<name>/     optional deployment overlay; same shape, wins on name
```

The installer links each `agent.md` to `~/.claude/agents/lens-<name>.md`
(product first, then bus overlay), so the subagent type is `lens-<name>`.

## Contract — every lens obeys this

1. **Stance vs facts.** The stance in `agent.md` sets priors and what to look
   for. Facts come only from `dossier.md` entries (cite the id, e.g. `QCS-004`)
   or from a source the lens fetched and read this session (cite it in full).
   Anything else is labelled `unverified`. A lens never invents a number or a
   citation to win a point.
2. **Steelman, then attack.** State the strongest version of the target's
   claim before objecting to it.
3. **Concede what is established.** A lens that concedes nothing is ignored.
4. **Read-only on the target.** A lens writes exactly one file: its review, at
   the path it is given. Single writer per file, so lenses run in parallel.
5. **Stay in lane.** Review through the lens; leave other concerns to other
   lenses. Do not soften a finding to be agreeable.
6. **Staleness.** Flag any dossier entry past its `stale-after` date.

## Review format

```markdown
---
lens: <name>
target: <absolute path(s)>
reviewed_at: <ISO 8601 UTC>
model: <model id>
verdict: holds | holds-with-caveats | overstated | unsupported
---

## Verdict
1-3 sentences.

## Objections
Ranked, most severe first. Each:
- **Claim:** quote + location (file:line or section)
- **Objection:** the argument
- **Evidence:** dossier id(s) or full citation; `unverified` if neither
- **Severity:** fatal | major | minor
- **Resolves it:** what result or citation would answer the objection

## Concessions
What the target gets right, with evidence.

## What would change my mind
Concrete results, not "more research".

## Unverified / out of lane
Points raised but not grounded, or outside this lens.
```

## Dossier entry format

```markdown
### <ID> — <short claim>
- claim: one sentence, falsifiable
- numbers: with units and conventions
- source: full citation, DOI or arXiv id, URL
- verified: <ISO date> — what was read (abstract only / section / full)
- strength: strong | moderate | contested
- counter: strongest rebuttal from the other side, cited
- applies-to: tags
- stale-after: <ISO date>
```

The `counter` field is mandatory: a lens armed with facts knows the best
answer to each of them.

## Adding a lens

Copy `qc-skeptic/`, rename, rewrite the stance and dossier, set `name:
lens-<name>` in the frontmatter, re-run the installer link step (or
`ln -sfn <dir>/agent.md ~/.claude/agents/lens-<name>.md`). Private lenses go in
`<bus>/lenses/`.
