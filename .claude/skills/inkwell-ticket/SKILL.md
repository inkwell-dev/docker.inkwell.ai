---
name: inkwell-ticket
description: This skill should be used for any request to change the inkwell.ai product. It is the end-to-end pipeline — understand, plan in a subagent, build the affected repos as parallel subagents, adversarial review, reconcile the spec, verify by exit code, then commit, PR, merge and bump the superproject. Triggers include a numbered ticket ("ticket 6", "next ticket", "issue 12", "#12", "task 6"); a feature request ("we should add…", "can we make it…"); a bug report ("this is broken", "I can't find X", "that button is disabled"); resuming earlier work ("continue", "pick up where we left off", "where did we stop"); or a request to run one stage of it ("plan this", "review the diff", "update the spec", "open the PRs", "bump the submodules"). It should be used even when the word "ticket" is never said and the change sounds like a one-liner, because the container-only gates and the spec-reconciliation step still apply. It should not be used for questions about how the existing code works, or for git and Docker troubleshooting that is not part of shipping a change.
---

# Resolving a ticket on inkwell.ai

This encodes a pipeline that has shipped five tickets. Every stage exists
because skipping it once cost real time — the notes explain which, so you can
judge when a stage genuinely does not apply rather than skipping it by reflex.

**Read `references/environment.md` before running any command.** It holds facts
that are not discoverable by looking at the repo and that have each cost hours:
nothing runs on the host, two of the obvious test invocations fail in ways that
look like broken code rather than broken commands, and the browser story is the
opposite of what this file used to claim — the Chrome extension *can* drive the
app, and a stale note saying otherwise suppressed a ticket's worth of visual
verification.

## The one-screen version

1. **Understand** the ticket, and name the repos it touches. Investigate before asking.
2. **Plan** with a subagent. The plan goes to a *file*, not into your context.
3. **Build** — one subagent per repo the ticket touches, spawned together.
4. **Review** with a subagent that is told to be adversarial.
5. **Reconcile the spec** — a named step, because it is the one most often forgotten.
6. **Verify** every gate yourself, by exit code.
7. **Ship**: commit, PR, merge, bump the superproject.

Stages 3 and 7 scale to the ticket. A frontend-only change gets one build agent
and one app PR — spawning an agent with nothing to do wastes a cold start, and
the pipeline is not a ritual to perform in full.

## Where a ticket comes from

Tickets are given **conversationally** — there is no issue tracker and no
`tickets.md`. The user's own words are the requirement, so quote them into the
plan rather than paraphrasing; the phrasing usually carries a constraint.

Longer-range context lives in `spec.inkwell.ai/0-phase-plan.md` (the phase plan,
referred to elsewhere in this skill) and in `spec.inkwell.ai/10-requirements.md`
(the `FR-`/`US-` tables). Check both when a ticket sounds like it may already be
specified — sometimes the requirement exists and only the UI is missing.

## Context discipline — read this first

A session running this pipeline has run out of context mid-ticket. The cause was
not the work; it was the *orchestrator* holding everything the subagents
produced. Keep yourself thin:

- **The plan lives on disk**, at `.tickets/<slug>/plan.md` in this repo
  (gitignored). Not the session scratchpad — that path is per-session and
  per-machine, so it is exactly what a resumed session cannot find. Give build
  agents the path, never the contents: pasting a plan into two prompts is the
  same tokens twice, and the copies drift the moment either is edited.
- **Ask agents for findings, not narration.** A build agent should report what
  it changed, its gate exit codes, and what it could not verify. It should not
  replay its reasoning.
- **Never read a subagent's transcript file.** It is the full JSONL and it will
  bury you. The completion notification is the interface.
- **Do the small fixes yourself.** Spawning an agent to correct four review
  findings costs more than fixing them, because the agent must re-derive
  everything you already know.

A useful instinct: if you are about to type a long block that a file could hold,
put it in the file.

## Stage 1 — Understand

Investigate first, ask second. A question you could have answered with `grep`
spends the user's attention for nothing, and arriving with findings makes the
remaining questions sharper.

For anything broader than a couple of targeted greps, use the `Explore` agent
rather than reading files yourself. It sweeps many files and returns the
conclusion, so the file contents never enter your context — and it runs happily
on a small model, because locating code is not the part that needs judgement.
Read files directly only once you know which ones matter.

Establish, before asking anything:
- Does any of this already exist? Search all three repos. Features here are
  often half-built — a previous ticket's controls were already drawn and sitting
  `disabled`, waiting for the code behind them.
- Is there a close analogue to follow? Find the nearest existing feature and read
  it. The social features (`likes`, `reposts`, `follows`, `blocks`, `saves`) are
  deliberately parallel to each other, so if the ticket is one of those, start
  there; otherwise look for whatever is structurally closest.
- Does the spec already describe it? Sometimes the requirement exists and only
  the UI is missing.

Then ask only what genuinely changes the work. Use `AskUserQuestion` — it takes
at most 4 questions of at most 4 options, so choose them — and give each option a
description that states the *consequence*, not just the label. The questions
worth asking are the ones where two readings produce materially different code:
who a feature applies to, what is visible to whom, whether something is
destructive.

Resolve the rest yourself from precedent and **say what you assumed**. Listing
five assumptions is faster for the user than five questions, and they can correct
any of them in one line.

**Stage 1 ends when you can state three things**: the ticket in one sentence,
your assumptions, and **which of the three repos it touches**. That last one is
not bookkeeping — it decides how many build agents you spawn, whether an API
contract needs pinning at all, and how many PRs stage 7 opens. A copy change
touching one app repo runs the same pipeline at a fraction of the size.

## Stage 2 — Plan

Spawn a planning subagent (`Plan`, or `feature-dev:code-architect` when the
change is mostly structural). `references/agents.md` has the prompt checklist —
read it before spawning; the stage-specific parts are below.

Hand it the ticket in the user's own words, the decisions already settled, and
everything stage 1 established, so it investigates rather than rediscovers.

Two demands worth making explicitly:

- **If the change crosses the backend/frontend boundary, pin the API contract
  first** — routes, request and response shapes. Two agents then build against it
  independently, and any drift is a merge conflict at best and a silent bug at
  worst. For a single-repo ticket this is noise; skip it.
- **Name the silent-breakage risks for this change** — the mistakes that would
  pass every gate and still be wrong. `references/environment.md` catalogues the
  ones this codebase keeps producing, indexed by the kind of change that invites
  them.

Write the plan to `.tickets/<slug>/plan.md`, then **read it critically** — a plan
is a draft, not an oracle. Plans from this pipeline have shipped a column name
that did not exist and a test command that cannot work. Correcting them in the
file takes a minute and stops both build agents inheriting them. Note your
corrections at the top so agents trust the file over their own instincts.

## Stage 3 — Build

**One subagent per repo the ticket touches**, all spawned in the same message so
they run concurrently. Each gets the plan's *path*, the sections that are theirs,
and an explicit instruction not to touch the other repos.

`references/agents.md` has what every prompt must carry, the optional agents
worth adding by ticket shape, and the procedure for resuming a build agent that
died mid-task. That last one matters: an interrupted file looks finished because
it exists, so a replacement must be told to **verify** its predecessor's work
rather than trust it.

## Stage 4 — Review

Do not skip this. Across the tickets this pipeline has run, review has found a
real defect every time — including a gate reported green while it was red. The
one defensible exception is a change with no logic in it at all, such as a copy
or comment edit; if you take it, say so rather than staying quiet.

`references/agents.md` has the review prompt in full. The essentials: tell the
agent explicitly to be **adversarial**, frame the build agents' self-reports as
**claims to verify**, insist it **re-runs the gates itself**, and push it toward
ground truth — dumping the generated SQL beats reading the query builder.

On tickets touching **auth, access control, payments, or personal data**, add the
`security-review` skill. For a second opinion on a large diff,
`code-review:code-review` or `feature-dev:code-reviewer` runs a different
checklist and finds different things.

When findings come back, a finding worth fixing names a **concrete failure
scenario** — the input or sequence producing the wrong result. One without that
is usually a style preference wearing a bug's clothes.

Fix the real ones yourself, and **prove the fix**. If a test was too weak, break
the code deliberately and confirm the test now fails. A regression test nobody
has watched fail is a guess.

## Stage 5 — Reconcile the spec

`spec.inkwell.ai` is a submodule at `spec.inkwell.ai/` in this repo, and it gets
its own branch, PR and merge.

This is its own stage because it is the one that gets forgotten. A feature has
shipped here with no spec update at all, and it went unnoticed until the
following ticket.

Ask the question directly: **what does this change make false?** Not just "what
should I add" — a shipped feature usually contradicts something already written.
Then check every one of these:

- a new table → a section in `6-database-schema.md`
- new behaviour → a section in `2-features.md`
- a new capability → an `FR-` row, and usually a `US-` row, in `10-requirements.md`
- **ids are append-only.** Never renumber to close a gap; they are referenced
  from commit messages and the phase plan. Take the next number and place the
  row beside its topic.
- an enum value, a notification type, a route → find every place the old list is
  written out and fix it
- something on a "future extensions" list → delete it and record that it shipped
- a requirement row that is now *wrong* rather than merely incomplete

When you find drift you are not fixing, record it as a dated note rather than
silently correcting it — the repo's own convention, and the reason the drift
happened is usually the useful part. Verify claims against the running system
before writing them down. A long-standing spec claim about Postgres turned out to
be false, and executing the statement was what settled it — the spec is not
evidence about the system it describes.

## Stage 6 — Verify

`references/environment.md` has the commands. Three rules matter more than the
commands themselves:

**Take a baseline first.** Before touching anything, run the gates for the repos
you are about to change and record the exit codes. A gate that was already red —
`tsc --noEmit` accumulates unrelated failures, since it is the only one covering
`test/` — will otherwise look like your doing, and you will either chase it or
wrongly disown a real break.

**Capture exit codes explicitly.** Run the gate, then `echo "exit: $?"`. Piping
to `head` and echoing "done" unconditionally is how a red typecheck was once
reported as green; it survived every other gate because nothing else covers that
directory.

**Never report a gate you did not watch pass.** If you did not see it, say so.
`superpowers:verification-before-completion` spells out the discipline.

You do not need a third full run. The build agents run the gates, review re-runs
them because a self-report is not evidence, and that is enough — **unless you
changed code afterwards**, which fixing review findings means you did. Re-run
what your fixes could have touched; do not re-run the whole suite out of ritual.

State plainly what is *not* verified — and check whether it really is not.
Anything visual **can** be seen through the Chrome extension at
`http://frontend.inkwell.ai/`; `references/environment.md` has the procedure,
including how to get a second account in front of you and why you must never
type a password to do it.

What stays true is that there is **no frontend test suite**, so a browser check
is a manual observation rather than regression protection. Report what you
actually saw as seen, and say that `tsc` and `eslint` are the only automated
frontend coverage. A visual check you *could* have run and did not is not a
limitation to disclose — it is one to go and run.

## Stage 7 — Ship

`references/conventions.md` has the commit and PR rules in full, including the
absolute one: **no attribution, in anything, ever** — enforced by a hook, but
know it rather than relying on the hook.

**Branches.** One branch per repo, same name across the repos a ticket touches so
they read as one change: `feat/<slug>` for features, `fix/<slug>` for bugs,
`docs/<slug>` in the spec repo, `chore/bump-<slug>` for the superproject bump.
Always branch from an up-to-date `main`; never commit to `main` directly.

**Order.** App PRs first, then the spec PR, then — once those merge — the
superproject bump. Open only the PRs the ticket actually needs; a spec-only
change is one PR plus a bump, not four.

**The bump still applies to a spec-only change.** The spec is a submodule too, so
its pointer goes stale exactly like the apps'. `git submodule status` shows a
leading `+` on anything behind.

When two app halves depend on each other, move both pointers in one commit and
say why — a superproject on one half and not the other is a real broken state,
not a cosmetic lag.

Hold the merge unless the user has said to merge. Ask once; "go ahead" covers the
whole sequence.

`superpowers:finishing-a-development-branch` covers the generic branch-closing
mechanics.

## Resuming a ticket from an earlier session

The pipeline is designed to be re-enterable, because sessions die. To work out
where you are, in this order:

```bash
cat .tickets/<slug>/plan.md                    # does a plan exist, and how far did it get
git -C . submodule status                      # a leading + means a bump is pending
for r in src/backend.inkwell.ai src/frontend.inkwell.ai spec.inkwell.ai; do
  echo "== $r"; git -C $r status --short --branch
done
gh pr list --repo inkwell-dev/backend.inkwell.ai --state open   # and the other three
```

That tells you which stage to re-enter: uncommitted changes with no PR means
stage 4–6; open PRs mean stage 7; merged PRs with a `+` in `submodule status`
means only the bump remains.

**Do not trust a working tree that looks finished.** Re-run the gates before
believing anything — the previous session may have died mid-edit, and a file that
exists is not a file that is wired up.

## The hooks

Five rules in `.claude/hookify.*.local.md` catch the mistakes that have cost the
most time, at the moment they are made rather than in review:

| Rule | Action |
|---|---|
| `no-ai-attribution` | **blocks** a commit naming any assistant |
| `no-bare-jest` | **blocks** `npx jest`, which cannot work here |
| `verify-in-container` | warns on host-side verification, which silently does nothing |
| `skip-db-push-check` | warns that the flag is unsafe after a schema change |
| `backend-lint-script` | warns that bare `eslint .` lints `dist/` |

They need the `hookify` plugin installed to fire. Without it they are inert files
— the guidance still lives in this skill, but nothing enforces it.

### Plugins this skill expects

On a new machine, install these from `claude-plugins-official`; the skill names
them at various stages and degrades quietly if they are absent:

```
/plugin install hookify@claude-plugins-official          # required — the hooks above
/plugin install superpowers@claude-plugins-official      # planning, parallel agents, verification
/plugin install feature-dev@claude-plugins-official      # code-architect, code-explorer, code-reviewer
/plugin install code-review@claude-plugins-official      # second-opinion review
/plugin install code-simplifier@claude-plugins-official  # post-merge quality pass
/plugin install typescript-lsp@claude-plugins-official   # real go-to-definition
/plugin install plugin-dev@claude-plugins-official       # only when editing this skill
```

`security-review` is built in. `docker.inkwell.ai:impeccable` comes with this
repo. Nothing here is load-bearing except `hookify` — the pipeline runs without
the rest, just with fewer specialists.

They are committed rather than gitignored, against hookify's usual convention,
because their whole purpose is to survive a change of laptop. Prose in a skill
can be skimmed past; a blocked tool call cannot.

## Reference files

- **`references/environment.md`** — how to run anything, and the traps. Read
  before your first command, every session.
- **`references/conventions.md`** — repo map, commit and PR rules, code style.
- **`references/agents.md`** — the agent roster and what to put in each prompt.

## What good looks like

The user should end a ticket knowing three things: what shipped, what was
verified and how, and what was *not* verified. The third is the one that builds
trust — a confident report that hides an unrun check is worth less than an
honest one that names it.
