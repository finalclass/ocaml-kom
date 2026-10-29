# Kom

An OCaml 5 library for stateful cells and declarative JSON message flows.
An operation's contract and implementation live together in its cell definition.
State is private and has an explicit text codec. Contracts use native OCaml
and JSON descriptors, without code generation.
The shared message type is `Kom.msg = Yojson.Safe.t`, or `msg` after `open Kom`.

The public API consists of `Cell.define`, `Flow.define` / `Flow.of_json`,
`System.define/create/call/replace/catalog/close` and the cell-private `Db`.
Execution modules are private. Messages use Yojson; `Schema.t` describes their
contracts. `Storage` connects a backend, with SQLite provided by the separate
`kom-sqlite` package. The optional `kom-main` package starts and closes a System
for standalone programs without exposing Eio setup in application code.
See the [architecture](contracts/README.md) for the scope.

## Build and test

Requires Dune **3.24.2**, Git, Make, a C toolchain, pkg-config and SQLite headers
(such as `libsqlite3-dev` on Debian). The library supports OCaml **5.1.0 or
newer** and Eio **0.14 or newer**. Eio 0.14 introduced the executor pool used
by Kom and requires OCaml 5.1; earlier OCaml 5 releases are not supported.
For development in this repository, Dune restores OCaml **5.4.1** and the
pinned dependencies from `dune.lock`. That lock does not constrain projects
which depend on Kom; they choose compatible versions in their own lockfiles.

```sh
make build
make test
make check
```

Tests cover contracts, routing, groups, cell exclusivity, parallel execution,
SQLite rollback, recovery after `SIGKILL`, catalog replacement and the CLI.
SQLite tests also verify serialized access to each backend and independent
System connections to the same database file. Standalone entry-point tests
cover callback results, initialization failure, exception cleanup and reopening
SQLite after a run.
Automated architecture analysis with Szaniec requires a profile for native
contracts; `make check` does not claim that analysis has run.

## CLI example

Two independent counters run in one System and receive commands on standard
input. The [example](examples/) separates the [cell](examples/counter_cell.ml),
[flows](examples/system.ml) and [terminal interface](examples/console.ml).
State is held in memory; every process starts with both counters at zero.

```sh
make examples
```

Enter commands such as:

```text
add a 3
3
add a 2
5
show b
0
show a
5
quit
```

You can also run `dune exec examples/console.exe` and pipe commands into it.
Results go to stdout; invalid commands report errors on stderr and leave the
session running. EOF closes the System. The full behavior is specified in
[the example contract](docs/examples.md).

## Define a cell and a flow

```ocaml
open Kom

let counter = Cell.define {
  id = "counter";
  state = {
    version = 1;
    init = (fun () -> 0);
    to_string = string_of_int;
    of_string = (fun text ->
      match int_of_string_opt text with
      | Some n -> Ok n | None -> Result.Error "Invalid counter");
  };
  operations = [
    Cell.Transformer {
      op = "increment";
      input = [];
      output = ["count", Schema.Int];
      impl = (fun _db state msg ->
        let next = state + 1 in
        next, `Assoc (("count", `Int next) ::
          List.remove_assoc "count" (Yojson.Safe.Util.to_assoc msg)));
    };
  ];
}

let definition = System.define
  ~cell_kinds:[counter]
  ~init_flow:"init"
  ~flows:[
    Flow.define {id = "init"; input = []; output = [];
      body = "!reproduce counter as counter"};
    Flow.define {id = "increment"; input = []; output = ["count", Schema.Int];
      body = "increment @counter"};
  ] ()

let () = Kom_main.run definition @@ fun system ->
  System.call system ~flow:"increment" (`Assoc [])
  |> Yojson.Safe.to_string |> print_endline
```

Use `(libraries kom kom-main yojson)` in Dune. For SQLite, add `kom-sqlite`
and pass `~storage:(Kom_sqlite.storage "state.sqlite")` to `Kom_main.run`.
Optional `id` and `workers` have the same defaults as `System.create`.

`Kom_main.run` returns the callback's result and closes the System on both
normal return and exceptions. Use the System only inside the callback.
This is a program entry point which owns the event loop; do not nest it inside
another `Kom_main.run` or `Eio_main.run`. Eio remains an implementation
dependency. Blocking IO is not automatically made asynchronous; the CLI uses
ordinary standard IO because it processes one command at a time.

For integration with an existing Eio application, depend on `kom` and keep
using `System.create ~sw ~domain_mgr definition`. The application supplies its
switch and domain manager and closes the System when finished. The core `kom`
library does not depend on `eio_main` at runtime.

A Transformer processes one message. An Expander produces a list of messages.
A Joiner receives a whole flat group once, including an empty group. A Router
chooses one declared port. Contracts are checked before execution and before
committing the result.

`!parallel` passes the same input to each branch. `!parallel_each` processes
each group element. Both wait for their branches and preserve order; nested
groups remain nested until an explicit `!flatten`. `!branch` selects a Router port.

`System.catalog` exports contracts and AST as JSON, without state or closures.
`Flow.of_json` accepts the same AST and uses the DSL's validator, providing
an integration point for a future graphical editor.

## Persistence and concurrency

An operation atomically commits cell state and its checkpoint. Operations on
one instance are exclusive; independent cells and flows can run concurrently.
Handlers run without holding a System-wide lock or a SQLite transaction for
their entire duration. Backend access uses short serialized operations.

Each open System has its own SQLite connection, including Systems with
different IDs in the same file. Cells in one System share its connection.
ExecutionAccess serializes backend reads, scans and commits with a per-System
mutex, held across SQLite IO. Initialization and catalog replacement exclude
active execution; closing waits for accepted work. SQLite calls run in Eio
system threads. There is no connection per cell. SQLite coordinates concurrent
writers from different connections to the same file.

`!transaction(fragment)` commits states, documents, indexes, new cells and
checkpoints together. Cells see their own writes. A concurrent change to a
read cell produces `Conflict`; handlers are not automatically retried.
Outside a transaction, earlier committed steps survive a later failure.
After a crash, an unfinished transactional fragment starts again; ordinary
flows resume from checkpoints. An optional `request_id` retrieves a completed
call's stored result without repeating its operations.

A handler receives a `Db.t` scoped to its instance and valid only during the
operation. `Db.get/put/delete` manage private JSON documents. `Db.put` stages
changes for the operation's atomic commit. `Db.view` maps documents to indexed
keys and values:

```ocaml
let finished_tasks = Db.view {
  id = "finished_tasks";
  version = 1;
  key = Db.int;
  map = (fun row ->
    let open Yojson.Safe.Util in
    if row |> member "done" |> to_bool then
      Some (row |> member "priority" |> to_int, row)
    else None);
}
```

Register the view with `Cell.define ~views:[Db.View finished_tasks]`.
Inside a handler, `Db.query ~from_key:3 ~limit:20 db finished_tasks
(fun (_, row) -> Some row)` reads a page. The view changes atomically with
the document. Queries scan index entries in batches, support ranges and
cursors, and filter before applying the limit. Increase `version` when
changing the mapping or key type; the new view is rebuilt before the System
becomes available. Documents are private to their owning cell.

External handler effects do not participate in rollback. A codec must restore
independent state. Changing an operation's implementation requires a new
`revision`. `System.replace` changes the catalog under the rules in the
[public API](docs/public-api.md); state.version migration remains out of scope.

SQLite stores individual KV records and writes only changes. Documents and
whole indexes are not loaded into memory. Cell states and execution history
remain in memory; history compaction is future work. The adapter permits one
active owner per database and System ID. Incompatible stored formats are
rejected without deleting data.

Further reading: [API](docs/public-api.md), [architecture](contracts/README.md),
[test scenarios](docs/stp.md), [extension boundaries](docs/open-questions.md).
