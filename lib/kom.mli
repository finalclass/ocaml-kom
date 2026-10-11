type msg = Yojson.Safe.t

module Schema : sig
  type t =
    | Any
    | Null
    | String
    | Int
    | Number
    | Bool
    | List of t
    | Object of fields
    | Dict of t
    | Any_of of t list
    | Optional of t

  and fields = (string * t) list
end

type error =
  { code: string
  ; message: string
  ; path: string option }

exception Error of error

module Db : sig
  type t

  type 'a key

  val int : int key

  val string : string key

  val pair : 'a key -> 'b key -> ('a * 'b) key

  type 'key spec =
    { id: string
    ; version: int
    ; key: 'key key
    ; map: msg -> ('key * msg) option }

  type 'key view

  type packed_view = View : 'key view -> packed_view

  type 'a page =
    { items: 'a list
    ; cursor: string option }

  val view : 'key spec -> 'key view

  val get : t -> id:string -> msg option

  val put : t -> id:string -> msg -> unit

  val delete : t -> id:string -> unit

  val query :
       ?from_key:'key
    -> ?to_key:'key
    -> ?after:string
    -> ?limit:int
    -> t
    -> 'key view
    -> ('key * msg -> 'a option)
    -> 'a page
end

module Cell : sig
  type 'state state =
    { version: int
    ; init: unit -> 'state
    ; to_string: 'state -> string
    ; of_string: string -> ('state, string) result }

  type 'state operation =
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

  type definition

  val define :
    ?views:Db.packed_view list -> ?revision:int -> 'state spec -> definition

  val unit_state : unit state
end

module Flow : sig
  type spec =
    { id: string
    ; input: Schema.fields
    ; output: Schema.fields
    ; body: string }

  type definition

  val define : ?version:int -> spec -> definition

  val of_json : Yojson.Safe.t -> definition
end

module Storage : sig
  type range =
    { prefix: string
    ; first: string option
    ; last: string option
    ; after: string option
    ; limit: int }

  type backend =
    { get: string -> string option
    ; scan: range -> (string * string) list
    ; commit: (string * string option) list -> unit
    ; close: unit -> unit }

  type t

  val memory : t

  val backend : (string -> backend) -> t

  val wrap : (id:string -> backend -> backend) -> t -> t
  (** Decorate a backend at the host boundary, e.g. to include host metadata
      in the same commit as an execution catalog. *)
end

module System : sig
  type definition

  type t

  val define :
       cell_kinds:Cell.definition list
    -> ?init_flow:string
    -> flows:Flow.definition list
    -> unit
    -> definition

  val create :
       sw:Eio.Switch.t
    -> domain_mgr:_ Eio.Domain_manager.t
    -> ?id:string
    -> ?workers:int
    -> ?storage:Storage.t
    -> definition
    -> t

  val call : ?request_id:string -> t -> flow:string -> msg -> msg

  val replace : t -> definition -> unit

  val catalog : t -> Yojson.Safe.t

  val close : t -> unit
end
