# docker.inkwell.ai

Infrastructure repository for **Inkwell.ai** — owns all Docker, Nginx, and deploy configuration.

Everything here is driven by the `Makefile`. Run `make` with no arguments for the target list.

## Services

| Service | Image | Published on host |
|---------|-------|-------------------|
| `nginx` | nginx:1.27-alpine | `127.0.0.2:80` + `127.0.0.1:8080` |
| `web` | node:22 (dev) / ghcr.io/inkwell-dev/frontend.inkwell.ai (prod) | — (behind nginx) |
| `api` | node:22 (dev) / ghcr.io/inkwell-dev/backend.inkwell.ai (prod) | — (behind nginx) |
| `worker` | same image as `api`, different entrypoint | — |
| `db` | pgvector/pgvector:pg16 | `5433` |
| `redis` | redis:7-alpine | `6379` |
| `minio` | minio/minio | `9000` (S3), `9001` (console) |

## Prerequisites

**All five repos must be siblings in the same parent directory.** The dev compose
file bind-mounts `../../../frontend.inkwell.ai` and `../../../backend.inkwell.ai`;
a different layout fails at startup.

```
inkwell.ai/
├── docker.inkwell.ai/     ← you are here
├── frontend.inkwell.ai/
├── backend.inkwell.ai/
├── mobile.inkwell.ai/
└── spec.inkwell.ai/
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

Add this line to `/etc/hosts` (needs `sudo`):

```
127.0.0.2  frontend.inkwell.ai backend.inkwell.ai storage.inkwell.ai
```

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

### 4. Run it — four terminals

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

### 5. URLs

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
