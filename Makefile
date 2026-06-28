.PHONY: vendor-check vendor-status vendor-update

vendor-check:
	ci/subtree-sync.sh check

vendor-status:
	ci/subtree-sync.sh status

vendor-update:
	@test -n "$(NAME)" || (echo "NAME is required" >&2; exit 2)
	@test -n "$(REF)" || (echo "REF is required" >&2; exit 2)
	ci/subtree-sync.sh update "$(NAME)" "$(REF)" "$(or $(TAG),-)"
