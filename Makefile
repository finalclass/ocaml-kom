DUNE ?= dune
DENO ?= deno
export PATH := $(CURDIR)/.local/bin:$(PATH)
.PHONY: build check test examples check-contracts generate tools check-architecture complexity todo test-todo
TODO_PORT ?= 8080
TODO_PERMISSIONS = --allow-run=_build/default/examples/todo/backend.exe --allow-read=examples/todo --allow-net=127.0.0.1

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
	$(MAKE) test-todo

examples:
	$(DUNE) exec examples/main.exe -- all

todo:
	$(DUNE) build examples/todo/backend.exe
	$(DENO) run $(TODO_PERMISSIONS) examples/todo/server.ts $(TODO_PORT)

test-todo:
	$(DUNE) build examples/todo/backend.exe
	$(DENO) fmt --check examples/todo/*.ts examples/todo/app.js
	$(DENO) check examples/todo/server.ts examples/todo/server_test.ts
	$(DENO) test $(TODO_PERMISSIONS) examples/todo/server_test.ts

generate:
	$(DENO) run --allow-run --allow-read --allow-write tools/contracts.ts --write

tools:
	$(DENO) run --allow-run --allow-read --allow-write --allow-env tools/szaniec.ts

check-architecture: tools
	szaniec check --project-root . --rebuild --json --no-callgraph

complexity: tools
	szaniec complexity --project-root . --sort complexity
