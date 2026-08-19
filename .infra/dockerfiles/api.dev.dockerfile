# Development image for the NestJS backend (src/backend.inkwell.ai).
#
# Shared by BOTH the api and worker services — same repo, same dependencies,
# different entrypoint (see the `command:` on each service in the dev compose
# file). Compose builds it once and both services reference the same tag.
#
# See web.dev.dockerfile for the full rationale; it applies verbatim here:
# the install is a cached layer rather than something re-run on every container
# start, and installing as the runtime user is what stops the node_modules named
# volume from being seeded root-owned and failing with EACCES.
FROM node:22.22.3-alpine AS development

# Must match the host user — this container compiles into the bind-mounted repo,
# and tsconfig sets `incremental: true`, so a root-owned dist/tsconfig.buildinfo
# makes even `tsc --noEmit` fail EACCES on the host afterwards.
ARG UID=1000
ARG GID=1000

ENV PNPM_HOME="/pnpm" \
    PATH="/pnpm:$PATH" \
    COREPACK_HOME=/tmp/corepack

RUN corepack enable && mkdir -p /pnpm && chmod 0777 /pnpm

# node:22-alpine ships a `node` user at 1000:1000; free that id before creating
# the account at the host's own UID/GID.
RUN deluser node 2>/dev/null || true; \
    delgroup node 2>/dev/null || true; \
    addgroup -g ${GID} app && \
    adduser -u ${UID} -G app -D -h /home/app app

WORKDIR /app
RUN chown ${UID}:${GID} /app
USER app

COPY --chown=${UID}:${GID} package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

EXPOSE 3000
# Overridden per service in the compose file: `pnpm start:dev` for api,
# `pnpm start:worker:dev` for worker. This default is the api.
CMD ["pnpm", "start:dev"]
