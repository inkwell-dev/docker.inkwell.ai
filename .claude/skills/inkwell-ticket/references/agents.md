# The agent roster

Which agent for which stage, and what a prompt has to carry. The prompts matter
more than the choice of agent — a cold agent knows nothing about this
environment, and everything it has to rediscover is time and tokens spent twice.

## Contents

- [What every prompt must carry](#what-every-prompt-must-carry)
- [Planning](#planning)
- [Building](#building)
- [Review](#review)
- [Optional passes](#optional-passes)
- [When an agent dies](#when-an-agent-dies)

## What every prompt must carry

Regardless of stage:

1. **The path to `references/environment.md`**, or its contents inline. Without
   it an agent will try to run things on the host, invent `npx jest`, or spend
   twenty minutes trying to open a browser.
2. **Its working tree, absolutely**, and an explicit instruction not to touch
   the other repos. Parallel agents editing the same tree is the one way this
   pipeline corrupts itself.
3. **"Do not commit, branch, push, or open a PR."** The orchestrator owns git,
   because the attribution rule is easiest to enforce in one place.
4. **The house rules**: comment the code, match the surrounding voice, never
   mention an assistant in a comment.
5. **What to do when uncertain** — flag it rather than guessing, and say so in
   the report. An agent that hides a doubt costs more than one that raises a
   false alarm.
6. **What to report**: what changed, gate results *with exit codes*, what it
   could not verify, and where it deviated from the plan. Not a narration.

## Planning

`Plan` for most tickets. `feature-dev:code-architect` when the change is mostly
structural and the question is where things should live.

Give it the ticket in the user's own words — not your paraphrase, since the
phrasing often carries the requirement — plus the decisions already settled and
everything stage 1 established.

Demand two things specifically:

- **The API contract first**, unambiguously. Two agents build against it
  independently.
- **The silent-breakage risks** for this particular change. The general list is
  in `references/environment.md`; the plan should say which apply here and
  where.

Treat the returned plan as a draft. Read it critically, correct what is wrong,
and note the corrections at the top of the file so build agents trust the file
over their own instincts.

`superpowers:writing-plans` covers plan structure if you want a second opinion
on shape.

## Building

Two `general-purpose` agents, spawned **in the same message** so they run
concurrently. One per repo.

Give each the plan's *path*, not its contents. Name the sections that are
theirs.

The frontend agent should be told which parts are logic-verifiable and which are
not, so it does not go looking for a browser.

Useful additions by ticket shape:

- **`typescript-lsp`** — real go-to-definition and find-references. On a
  codebase this size that is meaningfully better than grep for tracing a symbol.
- **`docker.inkwell.ai:impeccable`** — for substantially visual work.
- **`superpowers:test-driven-development`** — when the behaviour is easy to
  state as a test before writing the code.
- **`superpowers:subagent-driven-development`** and
  **`superpowers:dispatching-parallel-agents`** — the generic discipline this
  stage is a specialisation of.

## Review

A `general-purpose` agent told, in those words, to **be adversarial: find
defects, not confirm good work**.

It needs:
- the plan's review checklist and risk list
- the build agents' self-reports, framed explicitly as **claims to verify**
- the product decisions, so it can recognise a deviation from a choice
- an instruction to **re-run every gate itself**
- an instruction **not to modify code** — it reports, you fix

Push it toward ground truth. The best review this pipeline has produced dumped
the generated SQL by intercepting the database pool, rather than reading the
query builder and reasoning about it. Ask for that kind of evidence wherever the
question is "does this actually do what it looks like".

Ask for findings ranked by severity, each with `file:line` and a **concrete
failure scenario** — the input or sequence that produces the wrong result. A
finding without one is usually a style preference wearing a bug's clothes.

Second opinions, when the diff is large or the area is sensitive:
- **`code-review:code-review`** or **`feature-dev:code-reviewer`** — different
  checklists, different findings.
- **`security-review`** — on anything touching auth, access control, payments or
  personal data.
- **`code-simplifier:code-simplifier`** — a quality pass, not a bug hunt. Worth
  it when the diff grew organically across two agents.

`superpowers:requesting-code-review` and `superpowers:receiving-code-review`
cover the etiquette of both ends.

## Optional passes

**Spec drift.** Usually cheap enough to do yourself, but on a large change a
dedicated agent asking "what does this diff make false in `spec.inkwell.ai/`?"
catches contradictions that adding-only misses.

**`plugin-dev:skill-reviewer`** — when this skill itself changes.

## When an agent dies

Rate limits have killed several mid-task. The failure mode to avoid is
restarting blind.

1. **Look at the disk first.** `git status` in the affected repo shows exactly
   how far it got.
2. **Resume with an explicit inventory**: what is confirmed done, what remains.
3. **Tell the replacement to verify, not trust.** An interrupted file looks
   finished because it exists. Name the specific things most likely to be
   half-done — a helper written but not yet wired up, a list of edits where only
   some are applied.

If the limit blocks replacement entirely, finishing the work yourself is
legitimate — but say so in the final report, because a stage that was supposed
to be independent no longer was.
