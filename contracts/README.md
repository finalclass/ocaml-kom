# Kom architecture

The Kom facade exposes cells, flows and Systems.
Contracts use native OCaml types and serializable JSON descriptors.

| Owner | Responsibility |
|---|---|
| RevisionManager | Definition preparation, System restoration and initialization. |
| ExecutionManager | Flow admission, execution, recovery and completion. |
| FlowEngine | AST validation and interpretation, grouping and routing. |
| CellEngine | Operation execution on candidate state and result validation. |
| ExecutionAccess | Atomic persistence of states, instances, checkpoints and completions; exclusive instance access. |
| Db | Private document handles, view mapping, ranges, cursors and version rebuilds. |
| FlowAccess | DSL/AST parsing, flow definitions and the JSON catalog for editors. |
| CellCodeAccess | Cell kinds and their operation contracts. |
| Eio | Standard domain pool, fibers, promises and synchronization. |
| Schema | Private Yojson validation and Schema.t contracts. |
| NativeContract | Shared native types. |

SQLite adapts ExecutionAccess. SQL belongs to the adapter, outside Managers,
Engines and application code. ExecutionManager composes FlowEngine,
CellEngine and Access components. The facade delegates flow execution.
Flow contains no application closures or predicates; implementations belong
to the application's code catalog. An embedding Eio program owns the scope
and creates the System. A standalone program can instead use `Kom_main.run`,
which owns the event loop and closes the System when its callback finishes.

The distribution contains the kom library, the optional kom-sqlite adapter
and the optional kom-main entry point. Only kom-main requires eio_main at
runtime; kom keeps its explicit Eio integration API.
HTTP/WebSocket servers, JSON-RPC, application hosting, plugin loading and
application file storage are outside Kom's scope. Integrations use its public
API. The CLI example is specified in [examples.md](../docs/examples.md).
