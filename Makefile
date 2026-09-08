# Envee — Per-directory environment variable manager
# See docs/adr/ for architecture decisions.

# ---- Configuration ---------------------------------------------------------

BINARY          := envee
DAEMON_BINARY   := enveed
VERSION         ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "0.0.0-dev")
COMMIT          ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DATE            ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
# NOTE: the import path here must match the module path in go.mod exactly.
# Go silently ignores -X for a symbol it cannot find, so a typo here does not
# fail the build -- it just produces a binary that reports 0.0.0-dev.
MODULE          := github.com/baken667/envee
LDFLAGS         := -s -w \
                   -X $(MODULE)/internal/version.Version=$(VERSION) \
                   -X $(MODULE)/internal/version.Commit=$(COMMIT) \
                   -X $(MODULE)/internal/version.Date=$(DATE) \
                   -X $(MODULE)/internal/version.GoVersion=$(shell go version | cut -d' ' -f3)

# Directories
CMD_DIR         := ./cmd/$(BINARY)
DAEMON_CMD_DIR  := ./cmd/$(DAEMON_BINARY)
BIN_DIR         := bin
DIST_DIR        := dist
COVERAGE_DIR    := coverage

# Go flags
GO              := go
GOFLAGS         := -trimpath
GOOS            ?= $(shell go env GOOS)
GOARCH          ?= $(shell go env GOARCH)
CGO_ENABLED     ?= 0

# ---- Targets ----------------------------------------------------------------

.PHONY: help all build build-daemon install test test-race test-coverage lint fmt vet \
        clean docs completions manpages run run-debug \
        goreleaser-check goreleaser-snapshot release-snapshot \
        homebrew-tap-test examples

help: ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# --- Build ---

all: build completions manpages ## Build everything.

build: ## Build envee binary.
	@echo "==> Building $(BINARY) $(VERSION) (commit $(COMMIT))"
	@mkdir -p $(BIN_DIR)
	CGO_ENABLED=$(CGO_ENABLED) $(GO) build $(GOFLAGS) -ldflags='$(LDFLAGS)' -o $(BIN_DIR)/$(BINARY) $(CMD_DIR)
	@echo "==> Built $(BIN_DIR)/$(BINARY)"

build-daemon: ## Build enveed daemon.
	@echo "==> Building $(DAEMON_BINARY) $(VERSION)"
	@mkdir -p $(BIN_DIR)
	CGO_ENABLED=$(CGO_ENABLED) $(GO) build $(GOFLAGS) -ldflags='$(LDFLAGS)' -o $(BIN_DIR)/$(DAEMON_BINARY) $(DAEMON_CMD_DIR)
	@echo "==> Built $(BIN_DIR)/$(DAEMON_BINARY)"

install: build ## Install to $$GOBIN.
	CGO_ENABLED=$(CGO_ENABLED) $(GO) install $(GOFLAGS) -ldflags='$(LDFLAGS)' $(CMD_DIR)
	@echo "==> Installed to $$($(GO) env GOBIN)/$(BINARY)"

# --- Test ---

test: ## Run unit tests.
	$(GO) test -shuffle=on ./...

test-race: ## Run tests with race detector.
	CGO_ENABLED=1 $(GO) test -race -shuffle=on ./...

test-coverage: ## Run tests with coverage report.
	@mkdir -p $(COVERAGE_DIR)
	$(GO) test -coverprofile=$(COVERAGE_DIR)/coverage.out -covermode=atomic ./...
	$(GO) tool cover -html=$(COVERAGE_DIR)/coverage.out -o $(COVERAGE_DIR)/coverage.html
	@echo "==> Coverage report: $(COVERAGE_DIR)/coverage.html"

# --- Quality ---

lint: ## Run golangci-lint.
	@command -v golangci-lint >/dev/null || { echo "golangci-lint not installed. Run: brew install golangci-lint"; exit 1; }
	golangci-lint run ./...

fmt: ## Format Go source.
	$(GO) fmt ./...

vet: ## Run go vet.
	$(GO) vet ./...

# --- Docs ---

docs: completions manpages ## Generate docs artifacts.

completions: ## Generate shell completions.
	@mkdir -p completions
	@$(GO) run ./cmd/gen-docs completions --output completions/

manpages: ## Generate man pages.
	@mkdir -p manpages
	@$(GO) run ./cmd/gen-docs man --output manpages/

# --- Run ---

run: build ## Run envee with default args.
	./$(BIN_DIR)/$(BINARY)

run-debug: build ## Run envee in debug mode.
	ENVEE_LOG=debug ENVEE_DEBUG=1 ./$(BIN_DIR)/$(BINARY) --debug

# --- Release ---

goreleaser-check: ## Verify goreleaser config.
	@command -v goreleaser >/dev/null || { echo "goreleaser not installed. Run: brew install goreleaser"; exit 1; }
	goreleaser check

release-snapshot: ## Build a local snapshot release (no publish).
	@command -v goreleaser >/dev/null || { echo "goreleaser not installed"; exit 1; }
	goreleaser release --snapshot --clean --skip=sign,publish,announce

goreleaser-snapshot: goreleaser-check release-snapshot

# --- Homebrew tap ---

homebrew-tap-test: ## Test the Homebrew formula locally.
	@command -v brew >/dev/null || { echo "brew not installed"; exit 1; }
	brew audit --online --except=style,version --formula ../homebrew-tap/Formula/envee.rb

# --- Examples ---

examples: ## Verify examples parse correctly.
	@for f in examples/*/envee.toml; do \
		echo "Checking $$f..."; \
		$(GO) run $(CMD_DIR) check "$$f" || exit 1; \
	done

# --- Cleanup ---

clean: ## Remove build artifacts.
	rm -rf $(BIN_DIR) $(DIST_DIR) $(COVERAGE_DIR)
	rm -f completions/* manpages/*
