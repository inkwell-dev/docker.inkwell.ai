# Architecture

## The shape of it

Four git repositories. `docker.inkwell.ai` is the superproject and the only one
you clone; the other three are submodules of it.

```
docker.inkwell.ai/            compose, Makefile, nginx config, these docs
├── src/backend.inkwell.ai/   NestJS 11 · Drizzle · BullMQ
├── src/frontend.inkwell.ai/  Next.js 16 App Router · TanStack Query v5
└── spec.inkwell.ai/          the specification, versioned alongside the code
```

The specification is a repository rather than a folder because it is reconciled
with every change and reviewed like code. A feature is not finished when it
works; it is finished when the document that describes it is true again.

## Runtime

Seven long-running services and a one-shot migration container.

```
                         ┌──────────┐
              browser ──▶│  nginx   │  TLS, routing, SSE pass-through
                         └────┬─────┘
                    ┌─────────┴──────────┐
                    ▼                    ▼
              ┌──────────┐         ┌──────────┐
              │   web    │────────▶│   api    │
              │ Next.js  │  /api   │ NestJS   │
              └──────────┘         └────┬─────┘
                                        │
                     ┌──────────────────┼──────────────────┐
                     ▼                  ▼                  ▼
               ┌──────────┐      ┌──────────┐       ┌──────────┐
               │    db    │      │  redis   │       │  minio   │
               │ Postgres │      │  BullMQ  │       │  S3 API  │
               │ +pgvector│      └────┬─────┘       └──────────┘
               └──────────┘           │
                     ▲                ▼
                     │          ┌──────────┐
                     └──────────│  worker  │  five queues, no HTTP
                                └──────────┘
```

**`migrate` is a separate one-shot container**, not a step inside the API's
startup. Migrations that run on boot race each other the moment there is more
than one API replica, and a failed migration then presents as a crash-looping
application rather than as a failed migration.

**The worker is the same codebase with a different entrypoint** (`worker.ts`
against `worker.module.ts`), so processors share the services and the schema
rather than reimplementing them. Processors are registered *only* there — a
`WorkerHost` in the API module would start a second consumer on the same queue
and jobs would be processed twice.

Five queues: `ai-tokens`, `ai-models`, `analytics`, `embeddings`, `marketplace`.

## The request path

1. **nginx** terminates TLS and routes. `/api` to the API, everything else to
   Next. It is also the reason `NEXT_PUBLIC_API_URL` is same-origin: the browser
   talks to one host and never learns there are two services.
2. **Next.js** renders. Route files stay server components so `generateMetadata`
   can exist; the interactive body is a client component beneath it.
3. **TanStack Query v5** owns all client state that came from the server.
   Zustand holds the little that did not.
4. **NestJS** applies a global `ValidationPipe` with `whitelist` and
   `forbidNonWhitelisted`, so an undeclared query parameter is a 400 rather than
   silently ignored.

## Authentication

JWT: a 15-minute access token and a 7-day refresh token.

The access token is stored **twice**, and the duplication is deliberate:

| Where | Read by | For |
|---|---|---|
| `localStorage` | the Axios request interceptor | every client-side API call |
| a cookie | Next's proxy middleware | guarding protected *routes* before render |

The proxy cannot read `localStorage`, and the Axios interceptor cannot read an
`httpOnly` cookie, so a single store cannot serve both. The cost is a real failure
mode worth knowing: the two expire independently, so a protected page can bounce
to the login screen while the session is perfectly alive. Loading any other page
refreshes both.

**Guards compose.** `@Auth()` is a decorator that stacks `JwtAuthGuard` with
role, plan, account-type and subscription guards as needed. Public but
viewer-aware reads use `JwtOptionalGuard` instead — it resolves a token when one
is present and lets anonymous callers through. The distinction matters: reaching
for `@Auth()` on a public page 401s every signed-out visitor, which is a mistake
this codebase has made and now documents at every such route.

## Data model, and the three invariants that hold it together

Postgres 16.14 with `pgvector`.

**The ledger.** Every credit movement writes a `transactions` row inside the same
transaction as the balance it changes. Balances are a cache; transactions are the
truth. Three invariants are asserted — in the test suite and by a background job:

- a writer's `earnings_balance` equals the sum of their completed payouts
- a magazine's `credit_balance` equals grants plus top-ups minus debits
- a purchase's `credits_paid` equals `platform_fee + writer_payout`

The negative tests corrupt a row deliberately and assert the check fires, because
an invariant nobody has watched fail is a guess.

**Pagination is a frozen envelope.** Every paginated endpoint returns exactly
`{ items, page, limit, total, hasMore }`. The client's `Paginated<T>` and every
`getNextPageParam` assume it.

The recurring hazard is `total` and `items` describing different sets. It is
subtle enough to have shipped four times here — a header saying 20 above 19 rows,
a final page that renders empty while `hasMore` is true — so the rule is now
structural: one `where` value, built once, handed to both the page query and the
count. A predicate reaching into another table must be a self-contained `EXISTS`.

**Soft deletes.** Articles, comments and users carry `deleted_at`. Deleted
content is hidden but retained for moderation audit and for linking integrity —
a licensed article cannot be deleted out from under the magazine that bought it.

## Search and AI

Hybrid retrieval: Postgres full-text (`tsvector`, weighted so a title match
outranks a body mention) and pgvector cosine similarity, fused by reciprocal rank
fusion on **position** rather than score, because `ts_rank` and cosine similarity
are incomparable scales.

`docs/RAG.md` covers the pipeline — chunking, embedding, retrieval and prompt
assembly — and the measured similarity threshold.

Model calls fail over across two Groq models and then Gemini. Every model id the
product uses lives in one inventory file, probed on a schedule, because a
provider has twice retired a model out from under a live feature and both times
the failure was silent for days.

## Real-time

Notifications stream over **Server-Sent Events**, not WebSockets: the traffic is
one-directional, SSE survives an HTTP/1.1 proxy without an upgrade dance, and
nginx needs only buffering disabled on that location.

Pushes are collected *inside* a transaction and emitted *after* it commits. A
push cannot be un-sent, so emitting during the transaction would announce a
purchase that then rolled back.

## Storage

MinIO, S3-compatible. Uploads go **browser → MinIO directly** via presigned POST,
never through the API, so a large image does not occupy an API worker for the
duration of the transfer.

## Environment

Build-time and runtime configuration are different things and the difference has
bitten. `next build` **inlines** `NEXT_PUBLIC_*` into the browser bundle, so
changing one requires rebuilding the frontend image, not restarting it. Server-
side secrets are ordinary runtime environment.

## What this architecture does not do

- **No horizontal scaling story.** One API container, one worker. The queue
  design would tolerate more workers; nothing has been tested that way.
- **No cache layer.** Redis is a queue broker here, not a read cache. Every read
  hits Postgres.
- **No production deployment.** The compose file exists and has never run against
  a real host; there has never been a production database.
- **No frontend test suite.** Typecheck and lint are the only automated frontend
  gates, which is why the backend carries integration tests against a real
  database rather than mocks — the confidence has to come from somewhere.
