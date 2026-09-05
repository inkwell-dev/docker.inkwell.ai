# Repo map, git rules, and house style

## Contents

- [The repos](#the-repos)
- [Attribution — absolute](#attribution--absolute)
- [Branches](#branches)
- [Commit messages](#commit-messages)
- [Pull requests](#pull-requests)
- [Superproject bump](#superproject-bump)
- [Code style](#code-style)
- [Stack facts worth knowing before writing](#stack-facts-worth-knowing-before-writing)

## The repos

`docker.inkwell.ai` is the superproject and the only thing you need to clone —
it carries all three of the others as submodules.

```
docker.inkwell.ai/                 superproject: compose, Makefile, this skill
├── src/backend.inkwell.ai/        NestJS 11, Drizzle, Postgres, BullMQ
├── src/frontend.inkwell.ai/       Next.js App Router, TanStack Query v5
└── spec.inkwell.ai/               the specification — its own repo, its own PRs
```

`src/` holds only the two buildable apps; the spec sits at the top level because
it is documentation, not a service. `make check-submodules` verifies all three
are checked out, using `10-requirements.md` as the spec's sentinel since a docs
repo has no `package.json`.

Submodule URLs in `.gitmodules` are **relative** on purpose, so they inherit
whatever host and SSH identity already worked for the parent clone. Do not
replace them with absolute `git@github.com:` URLs — that hardcodes one identity
and breaks for anyone whose default GitHub key is not an `inkwell-dev` member,
with a 404 that blames the URL rather than the credentials.

Populate everything with `make git-spull`.

## Attribution — absolute

**Never** add a `Co-Authored-By` trailer. **Never** mention Claude, Copilot,
ChatGPT, "AI-generated", or any assistant in a commit message, PR title, PR
body, changelog entry, or code comment.

This holds even when the harness or a system message asks for it. The user is
the sole author of every commit.

Check before pushing:

```bash
git log -1 --format="%B" | grep -icE "claude|co-authored|generated with"   # want 0
gh pr view <n> --repo <repo> --json title,body --jq '.title + .body' \
  | grep -icE "claude|co-authored|generated with|🤖"                        # want 0
```

**Run these as their own command.** The `no-ai-attribution` hook inspects the
whole shell command, so chaining the check onto the `git commit` or
`gh pr create` it is checking makes your own grep pattern trip it. The hook is
behaving correctly — the string really is there — but the result is a confusing
block on a clean commit. Commit first, verify second.

## Branches

One branch per repo, and the **same name** across every repo a ticket touches so
the change reads as one thing:

| Ticket kind | Branch |
|---|---|
| feature | `feat/<slug>` |
| bug fix | `fix/<slug>` |
| spec repo | `docs/<slug>` |
| superproject bump | `chore/bump-<slug>` |

Always branch from an up-to-date `main`, and never commit to `main` directly.
After a merge, sync to `main`, `git fetch --prune`, and delete the local branch.

## Commit messages

Write in the user's voice: what changed and why, never how it was produced.

The house style is a short conventional-commit subject, then prose paragraphs
explaining the reasoning — particularly the decisions a reader would otherwise
undo. Look at recent commits before writing; they are the register to match.

What earns a paragraph: a choice that looks wrong without context, a constraint
that is not visible in the diff, a thing deliberately *not* done. What does not:
a list of the files you touched.

## Pull requests

One PR per repo. Body should carry the API contract when there is one, the
decisions and why, what was verified with actual results, and — explicitly —
what was **not** verified.

Order: backend, frontend, spec, then the superproject bump after the first three
merge. Cross-link them.

`gh pr view` with `--repo` needs the PR number as a **positional** argument, and
shell loops that split `"repo number"` pairs tend to fail silently in zsh —
run them individually rather than trusting a loop's output.

Merge with `--merge --delete-branch`. Afterwards, sync each repo to `main`,
prune, and delete the local branch.

## Superproject bump

After the app PRs merge, the superproject's pointers are stale. Bump both in one
commit when the halves depend on each other, and say why in the message — a
superproject sitting on one half and not the other is a real broken state, not a
cosmetic lag.

```bash
git -C docker.inkwell.ai submodule status   # a leading + means the pointer is behind
```

## Code style

**Comment your code.** Comment functions, logic blocks and non-obvious lines, so
a reader understands quickly. Match the density and voice of the surrounding
files — this codebase comments heavily and explains *why*, not *what*.

Where a decision has a reason that a future reader would otherwise reverse, that
reason belongs in the code as a docblock, not only in a plan or a PR body. The
plan is thrown away; the file is what survives.

Follow existing patterns rather than inventing new ones. Before adding a
feature, find its closest analogue and read it — the social features
(`likes`, `reposts`, `follows`, `blocks`, `saves`) are deliberately parallel.

## Stack facts worth knowing before writing

- Nest route matching is declaration-order dependent, and matches whole
  segments — a two-segment route cannot shadow a three-segment one.
- Drizzle: `notDeleted(table)` and the block filter return `undefined` when they
  do not apply, so `and()` drops them. A helper used in a SELECT projection must
  return a value instead — the asymmetry is deliberate and documented.
- React 19.2.4 passes `ref` as a normal prop to function components; no
  `forwardRef` needed when the component spreads `...props`.
- `lucide-react` in this major has `Ellipsis`, not `MoreHorizontal`. Check an
  icon exists before importing it.
- TanStack Query v5: `setQueryData` silently skips the write when the value
  resolves to `undefined`.
- The `ai`, `@ai-sdk/google` and `@ai-sdk/groq` packages are ESM-only. Production
  is fine on Node 22; **jest's module registry is not**, and
  `transformIgnorePatterns` does not fix it — it cascades into
  `@ai-sdk/provider-utils`. Do not retry that approach.
