module Schema = Schema

type msg = Native_contract.msg

type error = Native_contract.error =
  { code: string
  ; message: string
  ; path: string option }

exception Error = Native_contract.Error

let protect f =
  try f () with
  | exn -> raise (Error (Native_contract.error_of_exn exn))

module Db = struct
  include Db

  let view spec = protect (fun () -> view spec)

  let get db ~id = protect (fun () -> get db ~id)

  let put db ~id row = protect (fun () -> put db ~id row)

  let delete db ~id = protect (fun () -> delete db ~id)

  let query ?from_key ?to_key ?after ?limit db view f =
    protect (fun () -> query ?from_key ?to_key ?after ?limit db view f)
end

module Cell = struct
  type 'state state = 'state Native_contract.state =
    { version: int
    ; init: unit -> 'state
    ; to_string: 'state -> string
    ; of_string: string -> ('state, string) result }

  type 'state operation = 'state Native_contract.operation =
    | Transformer of
        { op: string
        ; input: Schema.fields
        ; output: Schema.fields
        ; impl: Db.t -> 'state -> msg -> 'state * msg }
    | Expander of
        { op: string
        ; input: Schema.fields
        ; output: Schema.fields
        ; impl: Db.t -> 'state -> msg -> 'state * msg list }
    | Joiner of
        { op: string
        ; input: Schema.fields
        ; output: Schema.fields
        ; impl: Db.t -> 'state -> msg list -> 'state * msg }
    | Router of
        { op: string
        ; input: Schema.fields
        ; output: (string * Schema.fields) list
        ; impl: Db.t -> 'state -> msg -> 'state * (string * msg) }

  type 'state spec = 'state Native_contract.cell_spec =
    { id: string
    ; state: 'state state
    ; operations: 'state operation list }

  type definition = Native_contract.cell

  let define ?(views = []) ?(revision = 1) spec =
    protect (fun () ->
        let cell = Native_contract.Cell (views, revision, spec) in
        Cell_code_access.validate cell ;
        cell )

  let unit_state = Native_contract.unit_state
end

module Flow = struct
  type spec = Native_contract.flow_spec =
    { id: string
    ; input: Schema.fields
    ; output: Schema.fields
    ; body: string }

  type definition = Native_contract.flow

  let define ?version spec =
    protect (fun () -> Flow_access.define ?version spec)

  let of_json json = protect (fun () -> Flow_access.of_json json)
end

module Storage = struct
  type range = Db.range =
    { prefix: string
    ; first: string option
    ; last: string option
    ; after: string option
    ; limit: int }

  type backend = Db.backend =
    { get: string -> string option
    ; scan: range -> (string * string) list
    ; commit: (string * string option) list -> unit
    ; close: unit -> unit }

  type t = Native_contract.storage

  let memory = Native_contract.Memory

  let backend open_ = Native_contract.Backend open_

  let wrap f storage =
    backend (fun id ->
        let raw =
          match storage with
          | Native_contract.Memory -> Db.memory_backend ()
          | Backend open_ -> open_ id
        in
        try f ~id raw with
        | exn ->
            raw.close () ;
            raise exn )
end

module System = struct
  type definition = Native_contract.definition

  type t = Execution_manager.t

  let define ~cell_kinds ?init_flow ~flows () =
    protect (fun () -> Revision_manager.define ~cell_kinds ?init_flow ~flows ())

  let create
      ~sw
      ~domain_mgr
      ?(id = "main")
      ?(workers = 4)
      ?(storage = Storage.memory)
      definition =
    protect (fun () ->
        Execution_manager.create
          ~sw
          ~domain_mgr
          ~workers
          ~storage
          ~id
          definition )

  let call ?request_id system ~flow message =
    protect (fun () -> Execution_manager.call ?request_id system ~flow message)

  let replace system definition =
    protect (fun () -> Execution_manager.replace system definition)

  let catalog system =
    system.Execution_manager.definition.Native_contract.catalog

  let close system = protect (fun () -> Execution_manager.close system)
end

let run ?id ?workers ?storage definition f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let system =
    System.create
      ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ?id
      ?workers
      ?storage
      definition
  in
  Fun.protect (fun () -> f system) ~finally:(fun () -> System.close system)
