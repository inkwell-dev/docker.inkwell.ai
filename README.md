# docker.inkwell.ai

Infrastructure repository for **Inkwell.ai** — owns all Docker, Nginx, and deploy configuration.

Everything here is driven by the `Makefile`. Run `make` with no arguments for the target list.

## Services

Every datastore publish is bound to `127.0.0.1` deliberately — those ports exist
for `psql`/`redis-cli`/a GUI client on this machine, and nothing off it needs
them. A bare `"5433:5432"` would publish on every interface and put the database
on whatever café or campus network the laptop happens to join.

| Service | Image | Published on host |
|---------|-------|-------------------|
| `nginx` | nginx:1.27-alpine | `127.0.0.2:80` + `127.0.0.1:8080` |
| `web` | `.infra/dockerfiles/web.dev.dockerfile` (dev) / ghcr.io/inkwell-dev/frontend.inkwell.ai (prod) | — (behind nginx) |
| `api` | `.infra/dockerfiles/api.dev.dockerfile` (dev) / ghcr.io/inkwell-dev/backend.inkwell.ai (prod) | — (behind nginx) |
| `worker` | same image as `api`, different entrypoint | — |
| `db` | pgvector/pgvector:pg16 | `127.0.0.1:5433` |
| `redis` | redis:7-alpine | `127.0.0.1:6379` |
| `minio` | minio/minio | `127.0.0.1:9000` (S3), `127.0.0.1:9001` (console) |

## Prerequisites

**The app repos are git submodules under `src/`.** The dev compose file
bind-mounts `../../src/frontend.inkwell.ai` and `../../src/backend.inkwell.ai`,
so nothing outside this repository is required — clone it recursively and the
layout is correct by construction.

```
docker.inkwell.ai/         ← you are here
├── .infra/                infra config (compose, nginx)
└── src/
    ├── frontend.inkwell.ai/   submodule → Next.js app
    └── backend.inkwell.ai/    submodule → NestJS API + worker
```

Fresh clone:

```bash
git clone --recurse-submodules git@github.com:inkwell-dev/docker.inkwell.ai.git
```

Already cloned without `--recurse-submodules`? The `src/` directories will be
empty and every app container exits immediately on start:

```bash
make git-spull
```

### `Repository not found` on the submodules

The submodule URLs in `.gitmodules` are **relative** (`../frontend.inkwell.ai.git`),
so they resolve against whatever `origin` this repo was cloned from and reuse the
same host and SSH identity. Clone with an account that belongs to `inkwell-dev`
and the submodules follow it — including through a `Host` alias in
`~/.ssh/config`, if you keep work and personal GitHub accounts separate:

```bash
# ~/.ssh/config
Host github-work
  HostName github.com
  IdentityFile ~/.ssh/id_work
  IdentitiesOnly yes
```

```bash
git clone --recurse-submodules git@github-work:inkwell-dev/docker.inkwell.ai.git
```

If the parent repo clones but the submodules fail, the identity is the cause, not
the URL — GitHub answers `404 Repository not found` rather than a permission error
for private repos you cannot see. Check who git is authenticating as:

```bash
ssh -T git@github.com     # "Hi <user>!" — is that the account in the org?
```

Both submodules track `main` (declared in `.gitmodules`). A submodule pins an
exact **commit**, not a branch tip — so after pulling new work in a submodule,
commit the updated pointer here too, or the next clone gets the older revision.

```bash
make git-spull    # pull this repo + fast-forward both submodules to origin/main
```

## Local Development

### 1. Environment file

```bash
cp .env.example .env
```

Then fill in the secrets. Two settings deserve attention:

- **`DOCKER_UID` / `DOCKER_GID`** — set to your own `id -u` / `id -g` if you are
  not `1000:1000`. The `web`/`api`/`worker` containers compile into the
  bind-mounted repos; running as root leaves `dist/` and `.next/` root-owned on
  the host, and `pnpm build` / `tsc` then fail with `EACCES`.
- **Comments must be on their own line, never trailing a value.** Docker Compose
  does not strip a trailing `# ...` from an env file — it assigns the comment
  text as the value.

### 2. Hostnames

```bash
make setup-hosts     # needs sudo; idempotent, safe to re-run
```

That appends the following to `/etc/hosts`, which you can also add by hand:

```
127.0.0.2  frontend.inkwell.ai backend.inkwell.ai storage.inkwell.ai
```

`make dciup-dev` warns if the entry is missing but does not fail — the app is
still reachable at http://localhost:8080 without it.

`127.0.0.2` rather than `127.0.0.1` so port 80 cannot collide with anything else
already bound there (ddev-router, a host nginx, Apache). Every address in
`127.0.0.0/8` is loopback on Linux.

### 3. Google OAuth (optional, only if you use social login)

In Google Cloud Console, add this authorized redirect URI:

```
http://localhost:8080/api/auth/google/callback
```

It must stay on `localhost` — Google rejects `http://` redirect URIs for any
other hostname. That is why nginx keeps its second publish on
`127.0.0.1:8080` alongside the named hosts.

### 4. Build the dev images (first run, and after dependency changes)

```bash
make dci-dev-build
```

The `web`, `api` and `worker` services build from `.infra/dockerfiles/`, which
install dependencies into a **cached image layer**. A container start is then
just the dev server — a few seconds, not a full `pnpm install`.

The trade-off: `package.json` and the lockfile are baked into that layer, so
after changing a dependency you must rebuild before the container can see it.
`make dci-dev-build` is cached and takes seconds; `make dci-dev-rebuild` ignores
the cache entirely and is only for a wedged build.

These are separate from the `Dockerfile` in each app repo — those build the
compiled production images used by CI and have no development target.

### 5. Database schema

Nothing to run: `make dci-api`, `make dci-worker` and `make dciup-all` all wait
on a one-shot `migrate` service that applies the versioned migrations in
`src/backend.inkwell.ai/drizzle/` and installs the pgvector extension. It is the
same runner the deploy uses, so dev and production apply the schema by identical
means.

This is worth knowing about because its absence used to be a bug. Dev had no
migrate service and no target, so a fresh clone booted the API against a
completely empty database and died on the first query with
`relation "article_tags" does not exist` — which reads like a missing table and
was in fact a missing step.

After generating a **new** migration, apply it to a running stack yourself:

```bash
make dci-migrate
```

The `depends_on` gate is satisfied by a migrate container that has already
exited 0, so restarting the API alone will not pick up a migration added since.

### 6. Run it — four terminals

Application services do **not** start automatically. They sit behind the `apps`
compose profile so each one can run in its own terminal, be restarted on its own,
and have a debugger attached without disturbing the rest of the stack.

```bash
# Terminal 0 — infrastructure: nginx, db, redis, minio
make dciup-dev

# Terminal 1 — NestJS API
make dci-api

# Terminal 2 — Next.js
make dci-web

# Terminal 3 — BullMQ worker
make dci-worker
```

`Ctrl+C` in any app terminal stops only that service; the rest keeps running.

Prefer everything at once (demo, first-run smoke test)?

```bash
make dciup-all      # whole stack, detached
make dci-logs-dev   # follow all logs, app services included
```

### 7. Demo data

Two commands, in this order:

```bash
# Writers, articles, a subscribed magazine, marketplace listings and purchases,
# engagement, notifications and a moderation queue. No API keys needed.
docker compose -f .infra/compose/docker-compose.dev.yml --env-file .env \
  --profile apps exec api pnpm db:seed

# Embeds the corpus so RAG has something to retrieve. Needs GEMINI_API_KEY.
docker compose -f .infra/compose/docker-compose.dev.yml --env-file .env \
  --profile apps exec api pnpm db:embed-backfill --all
```

The seed is deliberately offline — it touches only Postgres, so it works with no
keys configured and re-running it during a demo takes seconds. Embedding is the
separate step because it makes real API calls; **skip it and the AI assistant
still answers, but retrieves nothing**, which looks like a broken feature rather
than a missing setup step.

Re-running the seed is safe. It removes exactly what a previous run created,
identified by the seeded usernames, and leaves hand-made accounts and articles
alone. It also refuses to finish if the credit ledger it wrote does not balance.

Sign in as any seeded account with the password `InkwellDemo123!`:

| | |
|---|---|
| Writer | `nadia@example.com` |
| Magazine | `editors@longformreview.example.com` |
| Admin | `admin@inkwell.ai` |

### 8. URLs

| | |
|---|---|
| App | http://frontend.inkwell.ai |
| API + Swagger | http://backend.inkwell.ai/api/docs |
| Object storage (S3 endpoint) | http://storage.inkwell.ai |
| MinIO console | http://localhost:9001 |
| Legacy origin (OAuth, `api:codegen`) | http://localhost:8080 |

The browser app calls `/api` and `/storage` on its **own** origin, not on the
`backend`/`storage` hosts — same-origin, exactly as production behaves. Those two
extra hostnames exist for Swagger, curl, Postman, and as the presigned-upload
target.

### Common tasks

```bash
make dci-migrate     # apply schema migrations to a running stack
make dci-ps          # what is running
make dci-api-shell   # shell into the api container (must already be running)
make dci-db-shell    # shell into postgres
make dci-down        # stop everything
make dci-down-clean  # stop everything and drop volumes (destroys data)
```

Note that `dci-api-shell` attaches to a container whose dev server is **already
running** in another terminal. Starting a second one inside the shell is what
produces `EADDRINUSE :::3000`.

## Architecture

```
Browser
  ├─ http://frontend.inkwell.ai ─┐
  ├─ http://backend.inkwell.ai ──┤
  └─ http://storage.inkwell.ai ──┤
                                 ▼
                          Nginx (:80)
        frontend.inkwell.ai  ├── /api/*     → NestJS api (:3000)
                             ├── /storage/* → MinIO (:9000)
                             └── /*         → Next.js web (:3000)
        backend.inkwell.ai   └── /*         → NestJS api (:3000)
        storage.inkwell.ai   └── /*         → MinIO (:9000)

NestJS API ──► PostgreSQL (pgvector) + Redis + MinIO
Worker     ──► PostgreSQL + Redis (BullMQ jobs)
```

Nginx resolves upstreams at *request* time (`resolver 127.0.0.11` plus a variable
in `proxy_pass`, see `.infra/nginx/dev.conf`). That is what lets it boot while
`web`/`api` are stopped — a stopped service returns 502 instead of preventing
nginx from starting.

## Configuration files

| File | Purpose |
|------|---------|
| `.infra/compose/docker-compose.dev.yml` | Local dev: bind mounts, hot reload, `apps` profile |
| `.infra/dockerfiles/*.dev.dockerfile` | Dev images — dependencies as a cached layer, source via bind mount |
| `.infra/compose/docker-compose.production.yml` | VPS deployment, images from GHCR |
| `.infra/nginx/dev.conf` | Dev reverse proxy — three vhosts, lazy upstream DNS |
| `.infra/nginx/default.conf` | Production reverse proxy — single vhost |

## Environment Variables

See [`.env.example`](.env.example) — copy to `.env` and fill in secrets before
running. Production secrets live only on the VPS and are never committed.

## Production

### Build-time vs runtime — the one thing that trips everyone up

`NEXT_PUBLIC_*` values are **inlined into the browser bundle by `next build`**.
Setting them in `.env` or the compose `environment:` block changes nothing the
browser executes. They are passed as Docker build args from CI, sourced from
GitHub repository variables (Settings → Secrets and variables → Variables):

```
NEXT_PUBLIC_API_URL=https://inkwell-ai.me/api
NEXT_PUBLIC_SITE_URL=https://inkwell-ai.me
NEXT_PUBLIC_STORAGE_URL=https://inkwell-ai.me
NEXT_PUBLIC_SENTRY_DSN=https://<key>@<org>.ingest.sentry.io/<project>
```

All three URL values are the **apex**, including the storage one: images are read
through nginx's same-origin `/storage/` proxy. Only the *upload* path uses the
`storage.` subdomain, and that is `MINIO_ENDPOINT` — runtime config, not a build
arg. See the DNS table below.

Changing one requires **rebuilding the frontend image**, not restarting it.

Everything else (`FRONTEND_URL`, `CORS_ORIGINS`, `MINIO_*`,
`GOOGLE_CALLBACK_URL`) is ordinary runtime config in the VPS `.env` — see the
production block at the bottom of `.env.example`.

### DNS

Three A records are needed, all pointing at the VPS. All three must resolve
*before* certbot runs, because one certificate covers all of them:

| Record | Purpose |
|---|---|
| `inkwell-ai.me` | the app, the API (`/api`) and image reads (`/storage`) |
| `www.inkwell-ai.me` | redirected to the apex; included in the certificate |
| `storage.inkwell-ai.me` | presigned upload target (`MINIO_ENDPOINT`) |

The upload host is separate because MinIO addresses objects as `/<bucket>/<key>`,
and on the apex domain that path is claimed by the Next.js catch-all route.

### The MinIO console

Bound to `127.0.0.1:9001` on the VPS, not published publicly: it authenticates
with `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`, the credentials that grant full
access to every bucket. Reach it over an SSH tunnel:

```bash
ssh -L 9001:127.0.0.1:9001 <vps>   # then open http://localhost:9001
```

The S3 API is not published on the host at all — nginx proxies it.

### TLS

Nginx terminates TLS on 443 and redirects all of port 80 except the ACME
challenge path. It will **not start** unless both files exist:

```
.infra/nginx/certs/fullchain.pem
.infra/nginx/certs/privkey.pem
```

Issue them with certbot, including every hostname in one certificate:

```bash
certbot certonly --webroot -w /var/www/certbot \
  -d inkwell-ai.me -d www.inkwell-ai.me -d storage.inkwell-ai.me
```

Then copy (or symlink) the resulting `fullchain.pem` and `privkey.pem` into
`.infra/nginx/certs/`. Renewal uses the `certbot_webroot` volume, so
`certbot renew` works without stopping the proxy — reload nginx afterwards:

```bash
docker compose -f .infra/compose/docker-compose.production.yml exec nginx nginx -s reload
```
