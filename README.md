# Kom

An OCaml 5 library for stateful cells and declarative message flows.
Typed OCaml records define operation contracts and constrain implementations.
The `kom.ppx` deriver generates codecs and structural schemas from those records.
Messages retain their full JSON payload and identity; cells get a typed view.
State and document storage remain private to each cell.

The public API consists of `Kom.run`, `Cell.define`, `Flow.define` / `Flow.of_json`,
`System.define/create/call/replace/catalog/close` and the cell-private `Db`.
Execution modules are private. Messages use Yojson internally; generated `Schema.t` values describe their
contracts. `Storage` connects a backend, with SQLite provided by the separate
`kom-sqlite` package. `Kom.run` starts and closes a System
for standalone programs without exposing Eio setup in application code.

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
input. The [example](examples/counter/) separates the [cell](examples/counter/counter_cell.ml),
[flows](examples/counter/system.ml) and [terminal interface](examples/counter/console.ml).
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

You can also run `dune exec examples/counter/console.exe` and pipe commands into it.
Results go to stdout; invalid commands report errors on stderr and leave the
session running. EOF closes the System.

## Typed cells and inferred flows

The `kom.ppx` preprocessor derives a codec and structural descriptor from the
same OCaml type. The operation's input and output modules constrain its handler
at compile time. JSON remains the storage and transport representation.

```ocaml
open Kom

module State = struct
  type t = { last_greeted_person : string } [@@deriving yojson]
  let version = 1
  let init () = { last_greeted_person = "" }
end
module Input = struct
  type t = { user : string } [@@deriving kom]
end
module Greeting = struct
  type t = { greeting : string } [@@deriving kom]
end

let greeter = Cell.define {
  id = "Greeter";
  state = (module State);
  operations = [
    Cell.transformer ~id:"greet"
      ~input:(module Input)
      ~output:(Output.patch (module Greeting))
      ~impl:(fun _db _state msg ->
        let input = Msg.data msg in
        State.{ last_greeted_person = input.user },
        Greeting.{ greeting = "Hello, " ^ input.user });
  ];
}

let definition = System.define
  ~cell_kinds:[greeter] ~init_flow:"init"
  ~flows:[
    Flow.define ~id:"init" ~body:"!reproduce Greeter as @greeter" ();
    Flow.define ~id:"greet" ~body:"greet @greeter" ();
  ] ()

let () = Kom.run definition @@ fun system ->
  System.call system ~flow:"greet"
    ~msg:(Msg.define ["user", `String "John"])
  |> Msg.decode (module Greeting)
  |> Msg.data
  |> fun result -> print_endline result.Greeting.greeting
```

Use `(libraries kom yojson)` and
`(preprocess (pps kom.ppx ppx_deriving_yojson))` in Dune. The latter deriver is
used for State; `kom.ppx` generates message codecs itself. For SQLite, add
`kom-sqlite` and pass `~storage:(Kom_sqlite.storage "state.sqlite")` to `Kom.run`.

`Msg.data` exposes the checked record, `Msg.raw` the entire JSON object, and
`Msg.id` an identity separate from payload fields. Undeclared fields may be
inspected through `raw`, but any dependency on them must be checked at runtime;
flow analysis only knows the declared input. `Msg.encode (module Input) value`
constructs a message from a typed value. `Msg.decode` preserves identity.

Derived codecs support immutable records, nested records, aliases, primitive
values, tuples, lists, arrays, options, ordinary tagged variants, and named type
parameters. A type named `t` produces `kom`; other types produce `<name>_kom`.
Declare dependencies before types that reference them. Recursive types, GADTs,
inline variant records and field attributes are rejected with a PPX error.
Message roots must describe an object (a record or `unit`, encoded as `{}`).
Record option fields accept absence or null as `None`; encoding writes null.
Variants use JSON arrays such as `["Waiting", 3]`. Hand-written `Codec.make`
implementations are an explicit trusted escape hatch.

### Decorated cell modules and operations

The same `kom.ppx` preprocessor can generate operation registration and the
cell definition. Functions remain ordinary callable functions:

```ocaml
module Greeter = struct
  module State = struct
    type t = int [@@deriving yojson]
    let version = 1
    let init () = 0
  end
  module Input = struct
    type t = { name : string } [@@deriving kom]
  end
  module Output = struct
    type t = { greeting : string } [@@deriving kom]
  end

  let format name = "Hello, " ^ name

  let greet _db (state : State.t) (msg : Input.t Kom.Msg.t)
      : State.t * Output.t =
    state + 1, { greeting = format (Kom.Msg.data msg).name }
  [@@kom.transformer { output = patch }]
end
[@@kom.cell]
```

This generates `Greeter.greet_operation` immediately after the function and
`Greeter.cell` at the end of the module.

A file can be a cell as well. OCaml has no place to attach `[@@kom.cell]` to
a compilation unit, so put the floating form at the top of the file instead:

```ocaml
(* greeter.ml *)
[@@@kom.cell]

module State = struct ... end
module Input = struct ... end
module Output = struct ... end

let greet _db (state : State.t) (msg : Input.t Kom.Msg.t)
    : State.t * Output.t = ...
[@@kom.transformer { output = patch }]
```

The file then exposes `Greeter.cell` and `Greeter.greet_operation` like a
decorated module, and the file's module name (`Greeter`) is the default cell ID.
`[@@@kom.cell]` also works inside `module M = struct ... end`, where it is
equivalent to `[@@kom.cell]` on the binding; a module may use only one form. Only directly declared, decorated
functions are registered; helpers and operations inside nested modules are not
implicitly included. The module must declare one `State` module matching
`Kom.Cell.State`. All registered operations are checked against that state.

The module/function names are the default cell/operation IDs. Override stable
identities with `[@@kom.cell { id = "Greeter" }]` or
`[@@kom.transformer { id = "greet"; output = patch }]`.
A generated name colliding with a declared value is rejected. Decorated operations
also work outside decorated cells, exposing `<function>_operation` for manual
registration. Module aliases, functors, recursive or grouped operation bindings
are not supported by these attributes.

Functions must declare three positional arguments: db, annotated state, and
annotated message(s). They must have an explicit result annotation after the
arguments. PPX reads these annotations before OCaml type checking; it does not
infer types from function bodies. Input/output types must name modules as
`Some_module.t`, whose codecs are normally derived with `[@@deriving kom]`.

| Attribute | Message argument | Result annotation |
| --- | --- | --- |
| `kom.transformer` | `Input.t Kom.Msg.t` | `State.t * Output.t` |
| `kom.expander` | `Input.t Kom.Msg.t` | `State.t * Output.t list` |
| `kom.joiner`, fresh | `Input.t Kom.Msg.t list` | `State.t * Output.t` |
| `kom.joiner`, selected | `Input.t Kom.Msg.t list` | `State.t * (Input.t Kom.Msg.t * Output.t)` |
| `kom.router` | `Input.t Kom.Msg.t` | `State.t * (string * Output.t)` |

Specify `output = patch`, `fresh` or `patch_selected`. Patch policies accept
`remove = ["temporary"]`. Routers additionally require
`ports = ["Found"; "Missing"]`. The PPX rejects missing annotations, unknown
options, duplicate ports and policies incompatible with the operation kind.
Use an empty derived module (`type t = unit [@@deriving kom]`) for an empty
contract, and refer to it as `Empty.t` in annotations.

### Output policies and groups

- `Output.patch (module O)` replaces the declared **top-level** fields and
  preserves all others, including the message ID. A nested output record replaces
  that entire field; patching is not a recursive merge.
- `Output.patch ~remove:["temporary"] (module O)` also removes those top-level
  fields. Removal and output field names must be disjoint. Kom performs both
  changes; handlers only return the typed output record.
- `Output.fresh (module O)` creates a new payload and ID.
- `Output.patch_selected (module O)` is for Joiners. The handler returns an
  input message and its output record. Kom verifies the selected message belongs
  to that invocation, patches it and preserves its ID. An empty group has no base;
  the handler must reject it or use a fresh-output policy instead.

A Transformer receives one `Input.t Msg.t` and returns one output value. An
Expander returns a list of output values; each child receives a new ID, even with
patch output. A Joiner receives `Input.t Msg.t list`, including empty groups,
and returns one output value (or a base/output pair for selected patching).
Single-input patch policies cannot be passed to a Joiner: that is a type error.

`Cell.router` takes `~ports:["A"; "B"]` and a handler returning a port and a
typed output value. Its declared output policy applies to each port. Undeclared
ports fail before committing. For heterogeneous port schemas the explicit raw
Router API remains available.

### Flow syntax and inference

Separate instructions with a newline or `;`. Spaces alone and commas are not
statement separators. Trailing separators and blank lines are allowed; the final
statement needs no separator before the end of the flow or a closing parenthesis.

```text
!reproduce Greeter as @first
!reproduce Greeter as @second
greet @first; greet @second
```

Each reproduction creates a new instance. Addresses must be unused; repeating
`!reproduce Greeter as @first` fails with `CellExists`. `@first` is an instance
address, not a local variable. Address templates such as `@task.{$.task_id}`
remain supported.

`!sequence(...)` and top-level statements execute sequentially.
`!parallel(...)` passes the same message to each branch. `!parallel_each(...)`
processes each element of a flat group. Groups retain order and stay nested until
`!flatten`. Branch clauses also need separators:

```text
!branch(
  choose @greeter
  A(greet @first)
  B(greet @second)
)
```

`Flow.define ~id ~body ()` needs no hand-written input/output declarations.
`System.define` infers the required external fields and guaranteed output from
operation contracts, output policies, address templates, groups and branches.
Requirements supplied by earlier steps are not external inputs. Deleted or
replaced data cannot be recovered by adding it to the inferred external input.
Requirements shared by untouched nested records are combined structurally.
Contradictory requirements or incompatible group shapes fail during definition.

This is structural validation by Kom, not OCaml compile-time typing of a string
DSL. Input/Output modules can remain local to their cells. Handlers are checked by
the OCaml compiler; incoming JSON and codecs are checked at runtime. This does not
prove business logic or dependencies hidden in arbitrary access to `Msg.raw`.

`System.catalog` exports inferred contracts, output policies and AST as JSON.
`Flow.of_json` imports the catalog AST with explicit contracts, using the same
validator. `Flow.explicit` retains manually declared flow contracts when needed.

### Runtime and migration

`Kom.run` returns the callback's result and closes the system on success or
exception. It owns the Eio event loop; existing Eio applications should use
`System.create`. Blocking IO is not automatically asynchronous.

The previous JSON operation API is available under `Cell.Raw`.
`Cell.raw` includes such an operation in a typed cell. Raw operations retain
runtime schema and preservation checks. `System.call_json` provides the previous
JSON-in/JSON-out call style; the main `System.call` takes `~msg`.

Message IDs are persisted in checkpoints and completed outcomes. Retrying with a
`request_id` requires the same flow and input message (including its ID); reuse
the original message. The JSON compatibility call derives the message ID from
an explicit request ID. The store format is now **4**. Format 3 stores are rejected
explicitly; this experimental API change does not migrate existing databases.

## Errors

Kom automatically registers a `Printexc` printer for `Kom.Error`. Both
`Printexc.to_string` and the runtime's unhandled-exception output include the
error's `code`, `message` and, when present, `path`. No application-level
`try/with` is needed to enable these diagnostics. For example:

```text
Fatal error: exception Kom.Error {code = "Contract"; message = "Expected an integer"; path = "orders/0/amount"}
```

The exception remains `Kom.Error of Kom.error`, with the unchanged record
`{code : string; message : string; path : string option}` for programmatic
handling. Other exceptions retain their existing printers.

`System.define` validates the optional `init_flow` immediately, before
`Kom.run` starts. If `~init_flow:"init"` is specified, a flow with `id = "init"`
must be included in `flows`. Add that flow or omit `init_flow` if the system
does not need initialization; the error message includes the missing name
and both remedies.

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
`revision`. `System.replace` checks existing states with the new codecs and
atomically publishes the new catalog; failure preserves the old definition.
State.version migration remains out of scope.

SQLite stores individual KV records and writes only changes. Documents and
whole indexes are not loaded into memory. Cell states and execution history
remain in memory; history compaction is future work. The adapter permits one
active owner per database and System ID. Incompatible stored formats are
rejected without deleting data.
