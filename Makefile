# Envee — Per-directory environment variable manager
# See docs/adr/ for architecture decisions.

# ---- Configuration ---------------------------------------------------------

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "0.0.0-dev")
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DATE    ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

ZIG      := zig
ZIG_META := -Dversion=$(VERSION) -Dcommit=$(COMMIT) -Ddate=$(DATE)

.PHONY: help build test fmt release examples sdk-test tag clean

help: ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# --- Build ---

build: ## Build envee and envee-plugin-env into zig-out/bin (ReleaseSafe).
	$(ZIG) build -Doptimize=ReleaseSafe $(ZIG_META)

release: ## Cross-compile stripped binaries for every target into zig-out/release/.
	$(ZIG) build release $(ZIG_META)

# --- Test ---

test: ## Check formatting and run the test suite.
	$(ZIG) fmt --check src build.zig
	$(ZIG) build test --summary all

fmt: ## Format the Zig sources.
	$(ZIG) fmt src build.zig

examples: build ## Static-check every example config.
	@for f in examples/*/envee.toml; do \
		echo "Checking $$f..."; \
		./zig-out/bin/envee check "$$f" || exit 1; \
	done

sdk-test: ## Test the Go plugin SDK (its own module in pkg/sdk-go).
	cd pkg/sdk-go && go vet ./... && go test -shuffle=on ./...

# --- Release ---

# The only supported way to cut a release. Tags the head of the branch a
# release of that kind is cut from (main for stable, staging for -rc/-beta/
# -alpha) and refuses while a pull request into that branch is still open:
# the tag would land on the pre-merge head and publish the wrong code, which
# is exactly what happened to v0.4.0 and v0.4.1.
tag: ## Tag and push a release: make tag V=0.4.3 (stable, from main) or V=0.4.3-rc.1 (from staging).
	@test -n "$(V)" || { echo "usage: make tag V=0.4.3 | V=0.4.3-rc.1"; exit 1; }
	@case "$(V)" in v*) echo "V without the leading v"; exit 1;; esac
	@case "$(V)" in *-*) branch=staging;; *) branch=main;; esac; \
	git fetch -q origin "$$branch" --tags; \
	open="$$(gh pr list --base "$$branch" --state open --json number,title --jq '.[] | "#\(.number) \(.title)"')"; \
	if [ -n "$$open" ]; then echo "open pull request(s) into $$branch; merge or close them first:"; echo "$$open"; exit 1; fi; \
	if git rev-parse -q --verify "refs/tags/v$(V)" >/dev/null; then echo "tag v$(V) already exists; tags are never reused"; exit 1; fi; \
	head="$$(git rev-parse --short "origin/$$branch")"; \
	echo "tagging v$(V) at origin/$$branch ($$head): $$(git log -1 --format=%s "origin/$$branch")"; \
	git tag -a "v$(V)" "origin/$$branch" -m "envee $(V)" && git push origin "v$(V)"

# --- Cleanup ---

clean: ## Remove build artifacts.
	rm -rf zig-out .zig-cache
