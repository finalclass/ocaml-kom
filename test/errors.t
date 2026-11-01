The minimal application fails during System.define, before its callback runs.
Capture stderr separately and disable backtraces for stable runtime output:

  $ OCAMLRUNPARAM=b=0 ./error_worker.exe init-flow >stdout 2>stderr
  [2]
  $ cat stdout
  $ cat stderr
  Fatal error: exception Kom.Error {code = "Flow"; message = "Unknown init_flow \"init\": no flow with this id is defined in flows. Add the flow to flows or omit the optional init_flow argument."}

Errors without a path still expose the code and message:

  $ OCAMLRUNPARAM=b=0 ./error_worker.exe no-path >stdout 2>stderr
  [2]
  $ cat stdout
  $ cat stderr
  Fatal error: exception Kom.Error {code = "Contract"; message = "Expected an integer"}

A supplied path appears in the runtime diagnostic:

  $ OCAMLRUNPARAM=b=0 ./error_worker.exe path >stdout 2>stderr
  [2]
  $ cat stdout
  $ cat stderr
  Fatal error: exception Kom.Error {code = "Contract"; message = "Expected an integer"; path = "orders/0/amount"}

Unrelated exceptions retain the standard runtime diagnostic:

  $ OCAMLRUNPARAM=b=0 ./error_worker.exe other >stdout 2>stderr
  [2]
  $ cat stdout
  $ cat stderr
  Fatal error: exception Failure("ordinary failure")
