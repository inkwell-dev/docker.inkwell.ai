# inkwell.ai — start here

This is the **superproject**. It owns Docker, nginx and deploy configuration, and
carries the other three repositories as git submodules:

```
docker.inkwell.ai/              ← you are here
├── spec.inkwell.ai/            submodule — specs, report, diagrams, screenshots
└── src/
    ├── backend.inkwell.ai/     submodule — NestJS API + worker (.env, .env.test)
    └── frontend.inkwell.ai/    submodule — Next.js app, and capture/
```

**The submodules are gitlinks, not folders.** This repo stores a commit pointer
for each, not their files. A clone without `--recurse-submodules` leaves three
empty directories and reports no error. `make check-submodules` verifies them;
`make git-spull` populates them.

Everything else is driven by the `Makefile`. Run `make` with no arguments.

## Which door to go through

| The task | Read this first |
|---|---|
| change the product — a feature, a bug, a ticket | the **`inkwell-ticket` skill**, `.claude/skills/inkwell-ticket/SKILL.md` |
| run, test or verify anything at all | `.claude/skills/inkwell-ticket/references/environment.md` |
| bring a brand-new session up to speed, or set up another machine | **`spec.inkwell.ai/START-HERE.md`** |
| the PFE report — chapters, figures, screenshots | **`spec.inkwell.ai/REPORT-CONTEXT.md`** |
| repo map, branches, commits, PRs, code style | `.claude/skills/inkwell-ticket/references/conventions.md` |
| how the system is built | `docs/ARCHITECTURE.md`, `docs/RAG.md`, and `spec.inkwell.ai/4-system-architecture.md` |

The skill is the authority on process and environment. Prefer it over any note,
memory or summary that disagrees with it — it is versioned with the code.

## Three rules that are not negotiable

**Nothing verifies host-side.** `node_modules/` is an empty docker volume mount
in *both* app repos, so a lint, typecheck or test run on the host has silently
not run and will report success. Always `docker exec -w /app inkwell-api-1 …` or
`inkwell-web-1 …`, and check the exit code rather than reading stdout.
`references/environment.md` has the exact commands and the flags that are not
optional.

**Seed with the `full` preset.** A bare `make dci-seed` uses `demo` and silently
replaces the corpus with a tiny one. Use
`make dci-seed SEED_ARGS="--preset=full"`.

**Never name an assistant.** No `Co-Authored-By`, and no mention of Claude,
Copilot, ChatGPT or "AI-generated" in any commit message, PR title or body,
changelog entry or code comment. The user is the sole author of every commit.
A hookify rule enforces this — but only when the session was launched from this
directory with the `hookify` plugin installed, so hold it by hand otherwise.

## Launch the session here

`.claude/skills/` is discovered relative to the working directory. A session
opened in this repo's **parent** never sees the `inkwell-ticket` skill or the
five hookify rules beside it — they will not appear in the skills list and will
not fire. If you are already one level up, read `SKILL.md` and all three
`references/` files by hand.
