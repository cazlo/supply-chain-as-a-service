# Playwright test-runner image for the private web E2E lane
# (ci/web-e2e-k8s.sh). It carries only the vendored web repo's test source
# and dependencies -- no application build; the application itself runs from
# the signed staging images deployed by the chart. Built with rootless
# BuildKit on the daemonless runners (see ci/web-e2e-image-build.sh).
#
# The base image tag must match @playwright/test in
# artifact-keeper-web/package-lock.json, otherwise the preinstalled browsers
# are rejected at runtime; ci/web-e2e-image-build.sh derives the version from
# the lockfile and passes it here. Pin the base by digest after the first
# green canary, per the runner-image policy.
ARG PLAYWRIGHT_VERSION
FROM mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble

WORKDIR /work

# Dependency layer first so test-source edits don't invalidate npm ci.
COPY artifact-keeper-web/package.json artifact-keeper-web/package-lock.json ./
RUN npm ci --no-audit --no-fund

# Test source: the Playwright config and suites, plus src/ because some e2e
# fixtures import types through the tsconfig "@/*" path alias.
COPY artifact-keeper-web/tsconfig.json artifact-keeper-web/playwright.config.ts ./
COPY artifact-keeper-web/src ./src
COPY artifact-keeper-web/e2e ./e2e
