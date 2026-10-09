DUNE ?= dune
DENO ?= deno
export PATH := $(CURDIR)/.local/bin:$(PATH)
.PHONY: build check test examples check-contracts generate tools check-architecture complexity

build:
	$(DUNE) build

check-contracts:
	$(DUNE) exec -- cyrograf format --check contracts examples/contracts
	$(DUNE) exec -- cyrograf check contracts
	$(DUNE) exec -- cyrograf check examples/contracts
	$(DENO) run --allow-run --allow-read --allow-write tools/contracts.ts

check: check-contracts build test check-architecture

test:
	$(DUNE) runtest
	$(DUNE) exec examples/main.exe -- all

examples:
	$(DUNE) exec examples/main.exe -- all

generate:
	$(DENO) run --allow-run --allow-read --allow-write tools/contracts.ts --write

tools:
	$(DENO) run --allow-run --allow-read --allow-write --allow-env tools/szaniec.ts

check-architecture: tools
	szaniec check --project-root . --rebuild --json --no-callgraph

complexity: tools
	szaniec complexity --project-root . --sort complexity
