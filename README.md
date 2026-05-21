# docker.inkwell.ai

Infrastructure repository for **Inkwell.ai** — owns all Docker, Nginx, and deploy configuration.

## Services

| Service | Image | Port |
|---------|-------|------|
| `nginx` | nginx:1.27-alpine | 80, 443 |
| `web` | ghcr.io/inkwell-dev/frontend.inkwell.ai | internal |
| `api` | ghcr.io/inkwell-dev/backend.inkwell.ai | internal |
| `worker` | ghcr.io/inkwell-dev/backend.inkwell.ai | — |
| `db` | pgvector/pgvector:pg16 | internal |
| `redis` | redis:7-alpine | internal |
| `minio` | minio/minio | 9001 (console) |

## Local Development

```bash
# 1. Copy and fill in the env file
cp .env.example .env

# 2. Start everything (builds from source)
docker compose up --build

# Services available at:
# - Web app:       http://localhost
# - API + Swagger: http://localhost/api/docs
# - MinIO console: http://localhost:9001
```

## Environment Variables

See [`.env.example`](.env.example) — copy to `.env` and fill in secrets before running.

## Architecture

```
Browser → Nginx (:80)
              ├── /api/* → NestJS API (:3001)
              └── /*     → Next.js web (:3000)

NestJS API ──► PostgreSQL (pgvector) + Redis + MinIO
Worker     ──► PostgreSQL + Redis (BullMQ jobs)
```
