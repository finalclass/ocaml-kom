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

module Codec = Codec

module type Data = Typed_api.Data

module Route = struct
  include Typed_api.Route

  let define ports split = protect (fun () -> define ports split)
end

module type Route = Typed_api.Route

module Msg = struct
  include Typed_api.Msg

  let of_json ?id body = protect (fun () -> of_json ?id body)

  let define ?id fields = of_json ?id (`Assoc fields)

  let decode codec message = protect (fun () -> decode codec message)

  let encode codec data = protect (fun () -> encode codec data)
end

module Output = struct
  include Typed_api.Output

  let patch ?remove codec = protect (fun () -> patch ?remove codec)

  let fresh codec = protect (fun () -> fresh codec)

  let patch_selected ?remove codec =
    protect (fun () -> patch_selected ?remove codec)

  let patch_route ?remove route = protect (fun () -> patch_route ?remove route)

  let fresh_route route = protect (fun () -> fresh_route route)
end

module Cell = struct
  include Typed_api.Cell

  let define ?views ?revision spec =
    protect (fun () -> define ?views ?revision spec)

  let transformer ~id ~input ~output ~impl =
    protect (fun () -> transformer ~id ~input ~output ~impl)

  let expander ~id ~input ~output ~impl =
    protect (fun () -> expander ~id ~input ~output ~impl)

  let joiner ~id ~input ~output ~impl =
    protect (fun () -> joiner ~id ~input ~output ~impl)

  let router ~id ~input ~output ~impl =
    protect (fun () -> router ~id ~input ~output ~impl)
end

module Flow = struct
  type spec = Native_contract.flow_spec =
    { id: string
    ; input: Schema.fields
    ; output: Schema.fields
    ; body: string }

  type definition = Native_contract.flow

  let explicit ?version spec =
    protect (fun () -> Flow_access.define ?version spec)

  let define ?version ~id ~body () =
    let flow = explicit ?version {id; input= []; output= []; body} in
    {flow with inferred= true}

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

  let call ?request_id system ~flow ~msg =
    protect (fun () ->
        Execution_manager.call ?request_id system ~flow (Msg.message msg)
        |> Msg.of_message )

  let call_json ?request_id system ~flow body =
    let msg = Msg.of_json ?id:request_id body in
    call ?request_id system ~flow ~msg |> Msg.raw

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
