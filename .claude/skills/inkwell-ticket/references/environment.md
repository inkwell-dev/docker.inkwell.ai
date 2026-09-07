# Environment — how to run anything, and what will lie to you

Read this before your first command in a session. Nothing here is discoverable
by reading the repo, and every item cost real time to learn.

## Contents

- [The one rule](#the-one-rule)
- [Commands](#commands)
- [Traps that look like broken code](#traps-that-look-like-broken-code)
- [Talking to the API](#talking-to-the-api)
- [The database](#the-database)
- [Verifying in a browser](#verifying-in-a-browser)
- [Starting and resetting the stack](#starting-and-resetting-the-stack)
- [Schema changes](#schema-changes)
- [Tests](#tests)
- [Silent-breakage patterns in this codebase](#silent-breakage-patterns-in-this-codebase)

## The one rule

**Nothing runs on the host.** `node_modules/` is an empty volume mount in both
app repos. A lint or test run that appears to work host-side has silently not
run. Every command goes through `docker exec`.

## Commands

Backend (`inkwell-api-1`):

```bash
docker exec -w /app inkwell-api-1 npx tsc --noEmit    # the ONLY gate covering test/
docker exec -w /app inkwell-api-1 npm run lint        # scoped script
docker exec -w /app inkwell-api-1 npm run build
docker exec -w /app inkwell-api-1 npm test
```

Frontend (`inkwell-web-1`):

```bash
docker exec -w /app inkwell-web-1 npx tsc --noEmit
docker exec -w /app inkwell-web-1 npx eslint . --max-warnings=0
```

Capture exit codes explicitly:

```bash
docker exec -w /app inkwell-api-1 npx tsc --noEmit; echo "exit: $?"
```

Check the stack is up before starting: `docker ps` should show `inkwell-api-1`,
`inkwell-web-1`, `inkwell-db-1`, `inkwell-worker-1`, `inkwell-redis-1`,
`inkwell-nginx-1`, `inkwell-minio-1`.

## Traps that look like broken code

**`npm test`, never bare `npx jest`.** Jest dies at `globalSetup` with
`DATABASE_URL_TEST is not set`, because the env file is loaded by the npm script
(`node --env-file-if-exists=.env.test …`), not by jest.

**`npm run lint`, never bare `eslint .`.** The bare form lints compiled `dist/`
output and reports hundreds of phantom errors.

**`SKIP_DB_PUSH=1` only when the schema has not changed.** It skips the schema
push, so a new table or enum value never reaches `inkwell_test` and every spec
touching it fails on a missing relation. This reads as a broken harness rather
than a missing table, and it has cost a long debugging detour twice — once on
`blocks` (3 suites / 17 tests red), once on `saves`.

**`tsc --noEmit` is the only gate covering `test/`.** Jest compiles via SWC
without typechecking, and `build` excludes `test/`. A type error in a spec file
is invisible to every other gate.

**Jest needs `.env.test`** (gitignored) with `DATABASE_URL_TEST` pointing at a
database whose name ends in `_test`. `test/global-setup.ts` refuses anything
else, because it runs `drizzle-kit push --force`, which auto-approves
`DROP TABLE` and would otherwise wipe the seeded dev database.

## Talking to the API

The API listens on **port 3000 inside the container**, with no host binding.
`curl` is **not installed**. Use `node` with an `.mjs` file and `fetch`.

Never mix `require` with top-level `await` in an `.mjs` — it will not parse.

**Delete every probe file you create.** Agents have left `probe.mjs`,
`probe2.mjs` and `probe-sql.mjs` behind; they then show up in `git status` at
commit time.

Seeded accounts, password `InkwellDemo123!`:
`tomas@example.com`, `marina-beatty@example.com`, `liliane-davis@example.com`.

## The database

```bash
docker exec inkwell-db-1 psql -U inkwell -d inkwell -c "SELECT ..."
```

Use `docker exec -i` with a heredoc for multi-statement SQL; without `-i`, stdin
is not attached and the command silently produces nothing.

There is no `postgres` role — always pass `-U inkwell`.

PostgreSQL is **16.14**. `ALTER TYPE ... ADD VALUE` runs fine inside a
transaction; what fails is *using* the new value in the same transaction
(`unsafe use of new value`). Migrations that add an enum value and a table
together are therefore safe, as long as nothing writes a row using the value.

**Clean up after live testing.** Rows written by smoke tests stay in the seeded
demo database and will show up in a demo. Check for them before finishing.

## Verifying in a browser

**Corrected 2026-09-07. This section previously said "There is no browser" and
told you not to try. That was wrong, and it cost a whole ticket's visual
verification** — two build agents and a review were instructed not to attempt a
visual step, and the frontend shipped described as source-level only when it
could have been watched working.

### What works

The **Claude Chrome extension** (`mcp__claude-in-chrome__*`) against
**`http://frontend.inkwell.ai/`**. The app loads, signed in, with live data.

**The API works too, with no env change and no container restart.**
`NEXT_PUBLIC_API_URL` is `http://frontend.inkwell.ai/api` — the *same origin*,
proxied by nginx. The old note's premise was that the inlined API URL made the
app undrivable; in fact loading the hostname gets you the API for free. It was
the *loopback* origins that could not reach it, and the fix is to stop using
them.

`docker ps` first: the stack must be up, or you will diagnose a blank page as a
code fault.

### What does not work

Headless or automated Chromium launched **on the host** — `agent-browser`,
Playwright, raw CDP — gets `net::ERR_BLOCKED_BY_CLIENT` on the `*.inkwell.ai`
names, reproducibly and in a clean profile. `/etc/hosts` maps them to
`127.0.0.2`, so the likely cause is a public hostname resolving to loopback.
That finding is real; it simply never applied to the extension driving the
user's own Chrome. Do not spend time fighting it — use the extension.

### Never authenticate as someone

**Do not type a password into the login form, and do not send one in an API
call**, seeded demo accounts included. Work with whichever account is already
signed in, and choose test subjects to match that session — query the database
for a user in the state you need rather than guessing usernames, which wastes a
round trip on a 404.

```bash
docker exec inkwell-db-1 psql -U inkwell -d inkwell -t -A -F'|' \
  -c "SELECT u.username, count(*) FROM articles a JOIN users u ON u.id = a.author_id
      WHERE a.placement = 'marketplace' AND a.deleted_at IS NULL
      GROUP BY u.username ORDER BY 2 DESC LIMIT 5;"
```

### Testing a second account

One Chrome **profile** holds exactly one session: auth lives in `localStorage`
(canonical, read by the Axios interceptor) plus a cookie for the proxy, and both
are origin-scoped, so every tab in a profile shares it. There is no per-tab
isolation to exploit and no first-party Chrome container feature.

So **ask the user** to open a second Chrome profile, sign in there, and say
which account it is. Each profile runs its own extension instance, so it appears
in `list_connected_browsers` as a separate device; switch with `select_browser`.
Note two limits: it is **sequential**, not side by side — selecting a browser
switches the whole session — and site permissions are **per profile**, so the
new one needs `frontend.inkwell.ai` granted again.

Signed-out is cheaper: an **incognito window** is a clean storage partition and
needs no credentials at all, provided the extension is allowed in incognito.

Before acting on a multi-browser list, `list_connected_browsers` requires you to
ask the user which one — never pick for them.

### What a browser still does not give you

**There is no frontend test suite.** A browser check is a manual observation, not
regression protection: it proves the behaviour today and guards nothing
tomorrow. Report what was *seen* as seen, and keep saying that `tsc` and
`eslint` are the only automated frontend coverage.

## Starting and resetting the stack

From `docker.inkwell.ai`, via the Makefile — `make help` lists everything:

```
make dciup-dev      bring up the dev stack
make dciup-all      up, migrate and seed in one go
make dci-migrate    apply migrations to the dev database
make dci-seed       reseed the demo corpus
make dci-reset      tear down and rebuild from scratch
make git-spull      populate/advance every submodule
```

`make check-submodules` verifies all three submodules are checked out. Run it
first on a fresh machine — an empty submodule produces errors that look like
missing code rather than a missing checkout.

## Schema changes

Drizzle generates migrations from the schema files; do not hand-write them.

```
# 1. edit src/database/schema/*.ts
docker exec -w /app inkwell-api-1 npx drizzle-kit generate
# 2. review the emitted drizzle/NNNN_*.sql before applying — read it, do not skim
make dci-migrate
# 3. confirm against the database
docker exec inkwell-db-1 psql -U inkwell -d inkwell -c "\d <table>"
```

Commit all three artefacts: the `.sql`, the `meta/NNNN_snapshot.json`, and the
`meta/_journal.json` entry.

Adding an enum value and a table in one migration is safe (see the Postgres note
above), provided nothing *writes* a row using the new value in the same
transaction. `ALTER TYPE ... ADD VALUE` should be the first statement.

After any schema change, the test database needs the push — see the
`SKIP_DB_PUSH` trap above.

## Tests

Backend specs live in `test/<area>/<name>.spec.ts` and run against a real
database inside a transaction that is rolled back (`withRollback`). A ticket that
adds backend behaviour is expected to add specs; look at a recent one for the
house style, particularly the habit of asserting against independently written
SQL rather than against the ids the fixture just created — the difference between
a test that catches a bug and one that agrees with itself.

Run a single suite with `npm test -- test/<area>/<name>.spec.ts`.

**There is no frontend test suite.** `tsc` and `eslint` are the only frontend
gates, which is why frontend correctness leans on the backend's integration tests
and on careful reading. Say so when reporting rather than implying more coverage
than exists.

## Silent-breakage patterns in this codebase

These pass every gate and are still wrong. Rather than walking all of them every
time, check the ones the change actually invites:

| If the change… | check |
|---|---|
| adds or alters a paginated list | `countRows` drift, the frozen envelope, grow-the-limit |
| reuses an existing query's `where` | copying a feed's filter wholesale |
| adds a public or auth-aware read | `@Auth()` vs `JwtOptionalGuard` |
| adds a query parameter | `forbidNonWhitelisted` |
| adds an enum or notification type | exhaustiveness, and the fallbacks the compiler cannot see |
| adds viewer-specific client state | viewer-scoped cache keys |
| adds a protected route | the two-place proxy edit |
| seeds a cache from a list response | the staleness guard's timestamp |

When a ticket exposes a new pattern of this kind, add a row and a section — this
list is the most valuable thing in the file, and it only stays that way if it
grows.

**`countRows` drift.** `countRows(db, table, where)` selects from a **single**
table. Any predicate reaching into another table must be a self-contained
`EXISTS` subquery, and the *identical* value must go to both the page query and
the count. Otherwise `total` describes a different set than `items`: a header
saying 20 above 19 rows, and a final page that renders empty while `hasMore` is
true. This has bitten the follow lists, the block list and the saved list.

**Copying a feed's `where` wholesale.** `findFeed` filters
`placement = 'public'` because it *is* the public feed. Carried into a
viewer-scoped list, it silently removes marketplace articles — and because the
count uses the same predicate, the numbers agree, so it presents as data loss
rather than a filter bug.

**`@Auth()` where `JwtOptionalGuard` belongs.** `@Auth()` composes
`JwtAuthGuard` and 401s anonymous readers. A public read that is merely
*auth-aware* must use `JwtOptionalGuard`, or the page breaks for logged-out
visitors and any "prompt them to sign in" path becomes unreachable.

**`forbidNonWhitelisted`.** The global `ValidationPipe` rejects any query
parameter a DTO does not declare — with a 400, not by ignoring it. Adding a
filter means extending the DTO.

**Exhaustiveness that the compiler cannot see.** Adding a notification type
breaks three exhaustive switches, which is good — and silently mis-renders in
two `??` fallback chains, which is not. Grep for the *other* values of the enum
to find every place that lists them.

**The frozen pagination envelope.** Paginated endpoints return exactly
`{ items, page, limit, total, hasMore }`. The frontend's `Paginated<T>` and
every `getNextPageParam` assume it.

**Grow-the-limit pagination.** The API caps `limit` at 100. A list that grows
its limit instead of stepping pages silently stops at 100 rows while `hasMore`
is still true. Use `useInfiniteQuery` with page stepping.

**Viewer-scoped cache keys.** A status key for a signed-out visitor and for
whoever signs in next hash to the same string. Anything viewer-specific belongs
in `VIEWER_SCOPED_KEYS` in `query-keys.ts`, or a shared browser shows one
person's state to the next.

**The two-place proxy edit.** Protecting a route needs both `PROTECTED_PATHS`
and a matching pattern in `config.matcher` in `src/proxy.ts`. One without the
other is completely inert.

**Seeding a cache from a list.** When a list seeds per-row cache entries,
capture the timestamp **before** the request. Captured after, the staleness
guard can never fire, and a slow list response overwrites a user's optimistic
update.
