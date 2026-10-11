DUNE ?= dune
PYTHON ?= python3
export PATH := $(CURDIR)/.local/bin:$(PATH)
TODO_PORT ?= 8080
TODO_DIR ?= todo-data
.PHONY: build check test examples todo test-todo

build:
	$(DUNE) build @all @install

check: build test
	git diff --check

test:
	$(DUNE) runtest
	$(MAKE) test-todo

test-todo:
	$(DUNE) build bin/main.exe examples/todo.cmxs
	$(PYTHON) test/todo_http.py
	$(DUNE) build test/plugins/v1/fixture_v1.cmxs test/plugins/v2/fixture_v2.cmxs test/plugins/incompatible/fixture_incompatible.cmxs test/plugins/broken/fixture_broken.cmxs test/plugins/empty/fixture_empty.cmxs
	$(PYTHON) test/runtime_http.py

todo examples:
	$(DUNE) build bin/main.exe examples/todo.cmxs
	$(DUNE) exec kom -- start --foreground --directory $(TODO_DIR) --port $(TODO_PORT) --plugin _build/default/examples/todo.cmxs --assets examples
