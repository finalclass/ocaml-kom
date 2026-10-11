DUNE ?= dune
PYTHON ?= python3
export PATH := $(CURDIR)/.local/bin:$(PATH)
TODO_PORT ?= 8080
TODO_DB ?= todo.sqlite
.PHONY: build check test examples todo test-todo

build:
	$(DUNE) build @all @install

check: build test
	git diff --check

test:
	$(DUNE) runtest
	$(MAKE) test-todo

test-todo:
	$(DUNE) build examples/main.exe
	$(PYTHON) test/todo_http.py

todo examples:
	$(DUNE) exec examples/main.exe -- --port $(TODO_PORT) --db $(TODO_DB)
