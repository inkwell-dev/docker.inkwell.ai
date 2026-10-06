# The browser that takes the report's screenshots, on the capture stack's clock.
#
# Playwright's own image, pinned to the @playwright/test version the frontend
# installs (its browsers must match it exactly), plus libfaketime so Chromium
# reads the same shifted clock as the services it photographs. Cookies, "3 days
# ago" labels and token expiry are then all computed against one notion of now.
#
# Runs on the compose network, where nginx answers to frontend/backend/storage
# .inkwell.ai — so the app is reached under its real hostnames, with none of the
# host-side ERR_BLOCKED_BY_CLIENT trouble environment.md records.
FROM mcr.microsoft.com/playwright:v1.62.1-noble

RUN apt-get update \
 && apt-get install -y --no-install-recommends libfaketime \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s "$(dirname "$(dpkg -L libfaketime | grep 'libfaketime.so.1$')")" /usr/lib/faketime
