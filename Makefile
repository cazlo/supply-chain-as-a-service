.PHONY: source-check source-check-backend source-check-chart source-check-web source-smoke source-smoke-compose vendor-check vendor-status vendor-update

source-check:
	ci/check-clean-snapshots.sh all

# K8s-native smoke (PR gate): ephemeral chart install + native client Jobs.
source-smoke:
	ci/smoke-k8s.sh

# Local Docker Compose smoke, kept for workstation use without a cluster.
source-smoke-compose:
	ci/smoke-test.sh

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
