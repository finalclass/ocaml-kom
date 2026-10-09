(** Stateful cells and declarative flows. The runtime belongs to a System. *)
module Types = Kom_contracts.Kom_types
exception Error of Types.Problems.t
module Message : sig
  type 'a codec
  module type Codec = sig
    type t
    val to_drut : t -> (string, Cyrograf.Error.t) result
    val from_drut : string -> (t, Cyrograf.Error.t) result
  end
  val schema : (string * string) list -> Cyrograf.Schema.t
  val codec : schema:Cyrograf.Schema.t -> name:string -> (module Codec with type t='a) -> 'a codec
  val type_ : 'a codec -> Types.MessageType.t
  val encode : 'a codec -> 'a -> Types.Message.t
  val decode : 'a codec -> Types.Message.t -> 'a
  val bool : bool codec
  val int : int codec
  val string : string codec
  val batch : Types.Message.t list -> Types.MessageBatch.t
end
module Storage : sig
  type backend = { load:unit -> string option; save:string -> unit; close:unit -> unit }
  type t = Memory | Backend of string * (string -> backend)
  val memory : t

  (** Native persistence facet of ExecutionAccess; the callbacks operate on
      generated StoreSnapshot Drut text, never on process values. *)
  val backend : ?location:string -> (string -> backend) -> t
end
module Flow : sig
  type t = Types.FlowDefinition.t
  type named = Types.NamedFlow.t
  type source = Types.ValueSource.t
  type binding = Types.InputBinding.t
  type pattern = Types.OutputPattern.t
  type case
  val input : source
  val output : string -> source
  val field : ?from:string -> string list -> source
  val constant : 'a Message.codec -> 'a -> source
  val bind : source -> binding
  val bind_fields : (string list * source) list -> binding
  val step : ?id:string -> cell:string -> operation:string -> ?input:binding -> unit -> t
  val use : as_:string -> ?input:binding -> named -> t
  val sequence : t list -> t
  val parallel : t list -> t
  val bool : bool -> pattern
  val constructor : 'a Message.codec -> tag:string -> pattern
  val case : output:pattern -> t -> case
  val branch : from:source -> ?default:t -> case list -> t
  val input_type : 'a Message.codec -> t -> t
  val define : id:string -> ?version:int -> t -> named
  val inline : t -> Types.FlowSelector.t
  val named : string -> Types.FlowSelector.t
end
module rec Context : sig
  type t
  val work_id : t -> string
  val execution_id : t -> string
  val cell_id : t -> string
  val child : t -> id:string -> System.definition -> System.t
  val call : t -> call_id:string -> System.t -> flow:Types.FlowSelector.t -> Types.Message.t -> Types.Completion.t
end
and Cell : sig
  type definition
  type 'a restoration = Restored of 'a | Unsupported of Types.Problem.t | Failed of Types.Problem.t
  module type S = sig
    type state
    val id : string
    val revision : string
    val state_version : int
    val operations : Types.Operation.t list
    val init : Context.t -> Yojson.Safe.t -> (state, Types.Problem.t) result
    val handle : Context.t -> state -> operation:string -> Types.Message.t -> (state * Types.MessageBatch.t, Types.Problem.t) result
    val snapshot : state -> (string, Types.Problem.t) result
    val restore : Context.t -> Yojson.Safe.t -> Types.StateSnapshot.t -> state restoration
    val release : state -> unit
  end
  val define : (module S) -> definition
  val spec : id:string -> ?configuration:Yojson.Safe.t -> definition -> Types.CellSpec.t * definition
  val instantiate : System.t -> id:string -> ?configuration:Yojson.Safe.t -> definition -> (unit, Types.Problems.t) result
end
and System : sig
  type t
  type definition
  val define : ?implementations:Cell.definition list -> cells:(Types.CellSpec.t * Cell.definition) list -> flows:Flow.named list -> unit -> definition
  val create : ?id:string -> ?workers:int -> ?max_attempts:int -> ?storage:Storage.t -> definition -> (t, Types.Problems.t) result
  val with_ : ?id:string -> ?workers:int -> ?max_attempts:int -> ?storage:Storage.t -> definition -> (t -> 'a) -> ('a, Types.Problems.t) result
  val send : t -> flow:Types.FlowSelector.t -> Types.Message.t -> Types.SendResponse.t
  val await : t -> Types.Receipt.t -> Types.AwaitResponse.t
  val call : t -> flow:Types.FlowSelector.t -> Types.Message.t -> (Types.Completion.t, Types.Problems.t) result
  val update : ?force:bool -> t -> definition -> (unit, Types.Problems.t) result
end
module Operation : sig
  val make : name:string -> input:'a Message.codec -> outputs:Types.MessageType.t list -> Types.Operation.t
end
