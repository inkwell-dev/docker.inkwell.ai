# The agent roster

Which agent for which stage, and what a prompt has to carry. The prompts matter
more than the choice of agent — a cold agent knows nothing about this
environment, and everything it has to rediscover is time and tokens spent twice.

## Contents

- [Choosing a model](#choosing-a-model)
- [What every prompt must carry](#what-every-prompt-must-carry)
- [Planning](#planning)
- [Building](#building)
- [Review](#review)
- [Optional passes](#optional-passes)
- [When an agent dies](#when-an-agent-dies)

## Choosing a model

Do not put every agent on the largest model. It is not only the cost — running
several large agents concurrently is what exhausts a session's rate limit, and a
build agent killed at 70% has to be resumed by another cold agent that re-reads
everything. Cheaper agents where cheaper is enough makes the pipeline *finish
more often*, which matters more than the saving.

The rule of thumb: **spend on judgement, economise on execution.**

| Stage | Default | Why |
|---|---|---|
| Exploration / search | Haiku or Sonnet | Fan-out reading. Use the `Explore` agent — it exists for this and keeps file dumps out of your context. |
| Planning | Opus | Highest leverage in the pipeline; everything downstream inherits its mistakes. Sonnet is fine for a genuinely small ticket. |
| Backend build | Sonnet, Opus when earned | See the escalation triggers below. |
| Frontend build | Sonnet | By this point the plan has made the hard calls. This stage is wiring against a written contract. |
| Review | **Opus, always** | The one stage where a miss ships a defect. It has earned it every time. |
| Spec reconciliation | Sonnet | Mechanical once you know what changed — the judgement was in noticing it was needed. |
| Resuming a dead agent | Same as, or one tier below, the original | It works from an explicit inventory of what remains, so the ambiguity is lower. |

**Escalate the backend to Opus when the ticket involves** a schema change, a new
paginated list (the `countRows` trap), a transaction boundary, concurrency, an
access-control rule, or a query whose correctness is not obvious by reading. Keep
it on Sonnet for CRUD that mirrors an existing module.

**Escalate the frontend to Opus** only when the ticket is genuinely novel
interaction or state design rather than following an established pattern.

Two things worth knowing about the mechanics: an explicit `model` on the Agent
call overrides whatever the agent definition specifies, so you are opting out of
a considered default — check the definition before overriding it. And a `fork`
subagent always runs on the parent's model, so the parameter is ignored there.

If you find yourself reaching for Opus everywhere, the honest test is: *would a
careful engineer following the plan need to make a hard judgement call here, or
just execute it carefully?* Only the first is worth the larger model.

## What every prompt must carry

Regardless of stage:

1. **The path to `references/environment.md`**, or its contents inline. Without
   it an agent will try to run things on the host, invent `npx jest`, or miss
   that the app can be opened in a browser at all.
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

The frontend agent should be told which parts are logic-verifiable by `tsc` and
`eslint` and which are only observable by eye — and that the second kind **can**
be observed, through the Chrome extension at `http://frontend.inkwell.ai/`.

Telling an agent there is no browser is how a ticket ends up reported as
unverified when it was not. If you would rather do the visual pass yourself,
say so explicitly instead: the agent should know the check is owned, not
impossible.

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
