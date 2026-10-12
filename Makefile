DUNE ?= dune
.PHONY: build check test examples

build:
	$(DUNE) build @all @install

check: build test
	git diff --check

test:
	$(DUNE) runtest

examples:
	$(DUNE) exec examples/console.exe
