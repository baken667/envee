# Envee — Per-directory environment variable manager
# See docs/adr/ for architecture decisions.

# ---- Configuration ---------------------------------------------------------

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "0.0.0-dev")
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DATE    ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

ZIG      := zig
ZIG_META := -Dversion=$(VERSION) -Dcommit=$(COMMIT) -Ddate=$(DATE)

.PHONY: help build test fmt release examples sdk-test clean

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

# --- Cleanup ---

clean: ## Remove build artifacts.
	rm -rf zig-out .zig-cache
