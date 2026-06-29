.PHONY: ci-publish source-check source-check-backend source-check-chart source-check-web source-smoke source-smoke-compose backend-quality-ci vendor-check vendor-status vendor-update vendor-sync local-ci-build local-test local-coverage local-integration local-ci-down

LOCAL_CI := docker compose -f ci/local-ci/docker-compose.yml

ci-publish:
	ci/build-images.sh

source-check:
	ci/check-clean-snapshots.sh all

# K8s-native smoke (PR gate): ephemeral chart install + native client Jobs.
source-smoke:
	ci/smoke-k8s.sh

# Local Docker Compose smoke, kept for workstation use without a cluster.
source-smoke-compose:
	ci/smoke-test.sh

# Runner-native DB integration + coverage lane (rootless BuildKit + ak-smoke).
backend-quality-ci:
	ci/backend-quality-k8s.sh

source-check-backend:
	ci/check-clean-snapshots.sh backend

source-check-web:
	ci/check-clean-snapshots.sh web

source-check-chart:
	ci/check-clean-snapshots.sh chart

vendor-check:
	ci/subtree-sync.sh check

vendor-status:
	ci/subtree-sync.sh status

vendor-update:
	@test -n "$(NAME)" || (echo "NAME is required" >&2; exit 2)
	@test -n "$(REF)" || (echo "REF is required" >&2; exit 2)
	ci/subtree-sync.sh update "$(NAME)" "$(REF)" "$(or $(TAG),-)"

# Local dry-run of the scheduled sync: import fast-forward upstreams without
# pushing or opening a PR. Needs GITEA_SERVER/GITEA_TOKEN in the environment.
vendor-sync:
	DRY_RUN=1 ci/upstream-sync.sh

# Local mirror of the upstream backend CI (test-backend-unit + coverage jobs),
# for iterating on the age-gate work with the reviewer's gates. See
# ci/local-ci/README.md.
local-ci-build:
	$(LOCAL_CI) build

local-test:
	$(LOCAL_CI) run --rm ci bash /work/ci/local-ci/run.sh test

local-coverage:
	$(LOCAL_CI) run --rm ci bash /work/ci/local-ci/run.sh coverage

# DB-backed tests/ suites that `--lib` does not build (default: age_gate_tests;
# override with TEST=<name>). This is what actually runs patches/0003.
local-integration:
	$(LOCAL_CI) run --rm -e TEST ci bash /work/ci/local-ci/run.sh integration

local-ci-down:
	$(LOCAL_CI) down -v
