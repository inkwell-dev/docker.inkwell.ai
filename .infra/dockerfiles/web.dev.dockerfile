# Development image for the Next.js frontend (src/frontend.inkwell.ai).
#
# Deliberately NOT the Dockerfile inside the app repo: that one has base/deps/
# build/runner stages for shipping a compiled image, and no development target.
# Dev needs the opposite — dependencies installed, source left on a bind mount,
# and the dev server as the entrypoint.
#
# WHY THIS FILE EXISTS AT ALL. The dev services used to run the stock
# node:22-alpine image with
#     command: sh -c "corepack pnpm install && corepack pnpm dev"
# which re-ran a full install on EVERY `make dci-web`. Here the install is a
# cached layer, so it re-runs only when package.json or the lockfile changes.
#
# It also fixes the node_modules permission failure. Compose mounts a named
# volume at /app/node_modules; Docker seeds an empty named volume from the
# image, ownership included. Previously nothing existed at that path in the
# image, so the volume was created owned by root:root while the container ran as
# ${DOCKER_UID} — every start died on
#     EACCES: permission denied, mkdir '/app/node_modules/.pnpm'
# Installing as the runtime user below means the seeded volume is already owned
# by that user.
FROM node:22.22.3-alpine AS development

# Must match the host user, or files written into the bind-mounted repo (.next/,
# dist/) come out owned by someone else and the host can no longer build. Passed
# from compose as DOCKER_UID/DOCKER_GID.
ARG UID=1000
ARG GID=1000

ENV PNPM_HOME="/pnpm" \
    PATH="/pnpm:$PATH" \
    # Corepack defaults its home to $HOME; keep it on a path that is writable
    # whatever UID we end up running as.
    COREPACK_HOME=/tmp/corepack \
    NEXT_TELEMETRY_DISABLED=1

RUN corepack enable && mkdir -p /pnpm && chmod 0777 /pnpm

# node:22-alpine already ships a `node` user at 1000:1000, so that UID/GID is
# taken and adduser would fail for the common case. Drop it first, then recreate
# the account at exactly the host's ids.
RUN deluser node 2>/dev/null || true; \
    delgroup node 2>/dev/null || true; \
    addgroup -g ${GID} app && \
    adduser -u ${UID} -G app -D -h /home/app app

WORKDIR /app
RUN chown ${UID}:${GID} /app
USER app

# Manifests only — the source itself arrives at runtime on the bind mount. This
# is what keeps the install cached across ordinary code edits.
COPY --chown=${UID}:${GID} package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

EXPOSE 3000
CMD ["pnpm", "dev"]
