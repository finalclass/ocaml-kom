open Native_contract

let protect f =
  try f () with
  | exn -> raise (Error (error_of_exn exn))

type 'state state = 'state Native_contract.state =
  { version: int
  ; init: unit -> 'state
  ; to_string: 'state -> string
  ; of_string: string -> ('state, string) result }

type 'state operation = 'state Native_contract.raw_operation =
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

type 'state spec =
  { id: string
  ; state: 'state state
  ; operations: 'state operation list }

type definition = Native_contract.cell

let define ?(views = []) ?(revision = 1) (spec : _ spec) =
  protect (fun () ->
      let native =
        Native_contract.
          { id= spec.id
          ; state= spec.state
          ; operations= List.map (fun op -> Raw op) spec.operations }
      in
      let cell = Native_contract.Cell (views, revision, native) in
      Cell_code_access.validate cell ;
      cell )

let unit_state = Native_contract.unit_state
