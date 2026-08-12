---
name: mm
description: Spawn a same-or-one-lower-tier "mini-me" QA sub-agent that independently reloads the guidance and validates the primary's latest result against the user's request, returning a green/yellow/red confidence plus a terse reason. Invoke ONLY when the user types /mm (one-shot), or automatically on every turn while persistent mm mode is on (between /mm-on and /mm-off). Never self-invoke otherwise. The guidance stack is always binding independently of mm — it loads via the CLAUDE.md import chain, so "having" the guidance never requires this skill.
allowed-tools: Read, Bash, Glob, Grep, Task
---

# mm — mini-me QA validation

This skill runs ONLY when invoked: the user types `/mm` for a one-shot check, or
persistent mm mode is on (`/mm-on` … `/mm-off`) and the `mm-qa-gate.py` hook
re-injects it each turn. It is NOT an always-on behavior — do not spawn a QA
sub-agent on your own initiative.

On invocation it does two things: (1) reload the operator's guidance stack into
the primary agent (this session), and (2) spawn an independent "mini-me" QA
sub-agent that re-loads the same guidance and grades the primary's most recent
result.

Guidance is always binding regardless of this skill. The base rules + operator
overlay load into every session via the `CLAUDE.md` import chain; step 1 below
is a redundant in-session reload for when mm runs, not the mechanism by which
the guidance takes effect. An agent never needs to invoke mm to "have" the
guidance.

## 1. Reload the guidance stack (primary)

The canonical sources (base rules, then this operator's private overlay) are
imported directly below and always apply. They are the single source; do not
restate rules here.

@/Users/agallojr/proj/src/research-notes/bus/product/guidance/best-practices.base.md
@/Users/agallojr/proj/src/research-notes/bus/memory/best-practices.user.md

## 2. You are being watched — no bullshit

For this invocation (and every turn while mm mode stays on), treat the result
you produce as if it will be independently audited by the mini-me QA agent —
because it will be. Before you answer:

- State claims about code, data, config, or external behavior only after you
  have verified them against the actual source. If you have not verified, say so
  and mark it as unverified — do not dress a guess as a fact.
- Do not overreach beyond what was asked, and do not soften a bad result into a
  passing one.
- If the QA agent returns YELLOW or RED, that is a signal you cut a corner. Own
  it and fix it; do not argue the grade away.

The mini-me is a same-or-one-lower-tier copy of you with the same guidance. It
will catch unfounded confidence. Assume it will.

## 3. Pick the mini-me model tier

Tier ladder, highest to lowest: **Fable 5 → Opus (5 / 4.8) → Sonnet 5**.

Determine the primary's own tier from the running model identity (session
environment / system context), then spawn the QA agent one rung lower, floored
at Sonnet. This is the tunable knob — change the table to adjust QA rigor.

| Primary tier | Mini-me QA | Agent `model` |
|--------------|------------|---------------|
| Fable 5      | Opus       | `opus`        |
| Opus 5 / 4.8 | Sonnet     | `sonnet`      |
| Sonnet 5     | Sonnet     | `sonnet`      |

If the primary's tier can't be determined, default the QA agent to `sonnet`.

## 4. Spawn the mini-me QA agent

Run this only AFTER the primary has produced the result being graded — the QA
agent audits a completed work product, it does not run concurrently. If there is
no substantive primary result yet in the transcript, stop after step 1: report
that guidance was reloaded and there is nothing to validate.

Spawn ONE sub-agent via the Task tool, **synchronously** (not in the background —
the primary needs the verdict before replying), with:
- `subagent_type: general-purpose` — do NOT use Explore or Plan; those two skip
  CLAUDE.md, so they would not receive the guidance stack.
- `model` from the table in step 3.

A non-fork sub-agent inherits CLAUDE.md, the permission allowlist, and hooks
automatically, but it does NOT see this conversation. So pass the user request
and the primary's result **verbatim** in the prompt — the QA agent can only judge
what you hand it. Fill in this prompt:

> You are a mini-me QA validator — a peer-tier copy of the primary agent, bound
> by the same guidance. First, reload the guidance stack by reading these two
> files in full and treating them as binding:
> - /Users/agallojr/proj/src/research-notes/bus/product/guidance/best-practices.base.md
> - /Users/agallojr/proj/src/research-notes/bus/memory/best-practices.user.md
>
> You are given (a) the user's request and (b) the result the primary agent
> produced. Judge whether the result actually satisfies the request, and grade
> it adversarially on TWO axes — not form alone:
>
> - **FORM (grounding).** Hunt for claims asserted as fact but not verified
>   against code, data, or a cited source; overreach beyond what was asked; and
>   violations of the reloaded guidance.
> - **CONTENT (merits).** Judge the substance with a critical eye: is it
>   actually correct? Is the reasoning sound, or does it rest on a hidden bad
>   assumption or a non-sequitur? Does it address the user's real intent rather
>   than just the literal words? Is anything material missing, misleading, or
>   glossed? Is the chosen approach the right one, or is there an obviously
>   better alternative the primary ignored? A response can be perfectly
>   sourced and still wrong, shallow, incomplete, or beside the point — that
>   must NOT earn a GREEN.
>
> Stay scoped to the actual request: grade what was asked, do not invent new
> requirements or demand gold-plating the user did not want. You may read
> files, grep, or run read-only checks to confirm the primary's factual claims
> and to sanity-check its reasoning. Do not redo the work — grade it.
>
> --- USER REQUEST ---
> {verbatim user request}
> --- PRIMARY RESULT ---
> {verbatim primary result}
> --- END ---
>
> Return EXACTLY two lines and nothing else:
> Line 1: a colored verdict — one of `🟢 GREEN`, `🟡 YELLOW`, or `🔴 RED`
>   (include the leading circle glyph; it is the color the terminal renders).
> Line 2: one terse sentence (max ~25 words) explaining the verdict.

Verdict semantics (a verdict is the WORSE of the two axes — a form pass with a
content flaw is not GREEN):
- **🟢 GREEN** — sound on both axes: correct and responsive on the merits, and
  every claim is grounded; no material gaps.
- **🟡 YELLOW** — plausible but carries unverified claims, reasoning gaps,
  incompleteness, a questionable approach, or minor guidance slips; use with
  caution.
- **🔴 RED** — wrong on the merits, ungrounded, or fails the request.

## 5. Report

Relay the mini-me's verdict to the user verbatim (colored glyph + reason),
prefixed so it is clearly the QA agent speaking, e.g.
`mini-me (sonnet): 🟡 YELLOW — ...`. Keep the leading circle glyph
(🟢/🟡/🔴) — that is the color the terminal actually renders; raw ANSI is not
passed through the markdown output. Do not soften or reinterpret a YELLOW/RED
into a pass. Refine this protocol over time as we learn how the mini-me should
conduct itself.
