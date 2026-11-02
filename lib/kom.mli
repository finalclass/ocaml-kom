type msg = Yojson.Safe.t

module Schema : sig
  type t =
    | Any
    | Null
    | String
    | Int
    | Number
    | Bool
    | Tuple of t list
    | Tagged of (string * t list) list
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

module Codec : sig
  type 'a t

  val make :
       schema:Schema.t
    -> encode:('a -> Yojson.Safe.t)
    -> decode:(Yojson.Safe.t -> ('a, string) result)
    -> 'a t

  val schema : 'a t -> Schema.t

  val fields : 'a t -> Schema.fields

  val encode : 'a t -> 'a -> Yojson.Safe.t

  val decode : 'a t -> Yojson.Safe.t -> ('a, string) result

  val string : string t

  val int : int t

  val float : float t

  val bool : bool t

  val unit : unit t

  val json : Yojson.Safe.t t

  val list : 'a t -> 'a list t

  val array : 'a t -> 'a array t

  val option : 'a t -> 'a option t

  val field :
    'a t -> string -> (string * Yojson.Safe.t) list -> ('a, string) result

  val optional_field :
       'a t
    -> string
    -> (string * Yojson.Safe.t) list
    -> ('a option, string) result
end

module type Data = sig
  type t

  val kom : t Codec.t
end

module Msg : sig
  type 'a t

  val define : ?id:string -> (string * Yojson.Safe.t) list -> Yojson.Safe.t t

  val of_json : ?id:string -> Yojson.Safe.t -> Yojson.Safe.t t

  val data : 'a t -> 'a
  (** The decoded view specified by the operation's input module. *)

  val raw : 'a t -> Yojson.Safe.t
  (** Complete payload, including undeclared fields. Access to additional fields
      is dynamic and is not part of Flow contract inference. *)

  val id : 'a t -> string

  val decode : (module Data with type t = 'a) -> 'b t -> 'a t

  val encode : (module Data with type t = 'a) -> 'a -> Yojson.Safe.t t
end

module Output : sig
  type single

  type group

  type ('input, 'result, 'scope) t

  val patch :
    ?remove:string list -> (module Data with type t = 'a) -> ('i, 'a, single) t
  (** Set output fields at the top level, remove the named fields, and preserve
      the remaining payload and identity. Output and removal names must be disjoint. *)

  val fresh : (module Data with type t = 'a) -> ('i, 'a, 'scope) t
  (** Build a new payload with a new message identity. *)

  val patch_selected :
       ?remove:string list
    -> (module Data with type t = 'a)
    -> ('i, 'i Msg.t * 'a, group) t
  (** A Joiner returns one of its input messages together with its typed output.
      The selected base is checked at runtime; a reconstructed message is not a base. *)
end

module Cell : sig
  module Raw : sig
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

  module type State = sig
    type t

    val version : int

    val init : unit -> t

    val to_yojson : t -> Yojson.Safe.t

    val of_yojson : Yojson.Safe.t -> (t, string) result
  end

  type 'state operation

  type 'state spec =
    { id: string
    ; state: (module State with type t = 'state)
    ; operations: 'state operation list }

  type definition = Raw.definition

  val define :
    ?views:Db.packed_view list -> ?revision:int -> 's spec -> definition

  val raw : 's Raw.operation -> 's operation

  val transformer :
       id:string
    -> input:(module Data with type t = 'i)
    -> output:('i, 'r, Output.single) Output.t
    -> impl:(Db.t -> 's -> 'i Msg.t -> 's * 'r)
    -> 's operation

  val expander :
       id:string
    -> input:(module Data with type t = 'i)
    -> output:('i, 'r, Output.single) Output.t
    -> impl:(Db.t -> 's -> 'i Msg.t -> 's * 'r list)
    -> 's operation

  val joiner :
       id:string
    -> input:(module Data with type t = 'i)
    -> output:('i, 'r, Output.group) Output.t
    -> impl:(Db.t -> 's -> 'i Msg.t list -> 's * 'r)
    -> 's operation

  val router :
       id:string
    -> input:(module Data with type t = 'i)
    -> output:('i, 'r, Output.single) Output.t
    -> ports:string list
    -> impl:(Db.t -> 's -> 'i Msg.t -> 's * (string * 'r))
    -> 's operation
end

module Flow : sig
  type spec =
    { id: string
    ; input: Schema.fields
    ; output: Schema.fields
    ; body: string }

  type definition

  val explicit : ?version:int -> spec -> definition

  val define : ?version:int -> id:string -> body:string -> unit -> definition
  (** Infer structural input and output contracts when System.define compiles
      the flow. Statements must be separated by a newline or semicolon. *)

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
  (** Decorate a backend before creating a System, e.g. to inject storage
      failures in tests. Cells do not have access to this interface. *)
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

  val call :
       ?request_id:string
    -> t
    -> flow:string
    -> msg:'a Msg.t
    -> Yojson.Safe.t Msg.t

  val call_json : ?request_id:string -> t -> flow:string -> msg -> msg

  val replace : t -> definition -> unit

  val catalog : t -> Yojson.Safe.t

  val close : t -> unit
end

val run :
     ?id:string
  -> ?workers:int
  -> ?storage:Storage.t
  -> System.definition
  -> (System.t -> 'a)
  -> 'a
(** [run definition f] starts an execution environment, creates a System and
    returns [f system]. It closes the System before returning or propagating an
    exception. The System is only usable within the callback.

    Options have the same defaults as {!System.create}: [id = "main"],
    [workers = 4] and in-memory storage.

    Use this at the program's entry point, outside any existing Eio event loop.
    Programs already using Eio should use {!System.create} with their own
    switch and domain manager. Blocking IO in the callback or cell handlers
    does not become asynchronous. *)
