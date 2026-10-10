type msg = Yojson.Safe.t
module Schema : sig
  type t =
    | Any | Null | String | Int | Number | Bool
    | List of t | Object of fields | Dict of t | Any_of of t list | Optional of t
  and fields = (string * t) list
end
type error = {code : string; message : string; path : string option}
exception Error of error
module Cell : sig
  type 'state state = {
    version : int; init : unit -> 'state;
    to_string : 'state -> string; of_string : string -> ('state, string) result;
  }
  type 'state operation =
    | Transformer of {
        op : string; input : Schema.fields; output : Schema.fields;
        impl : 'state -> msg -> 'state * msg;
      }
    | Expander of {
        op : string; input : Schema.fields; output : Schema.fields;
        impl : 'state -> msg -> 'state * msg list;
      }
    | Joiner of {
        op : string; input : Schema.fields; output : Schema.fields;
        impl : 'state -> msg list -> 'state * msg;
      }
    | Router of {
        op : string; input : Schema.fields; output : (string * Schema.fields) list;
        impl : 'state -> msg -> 'state * (string * msg);
      }
  type 'state spec = {
    id : string; state : 'state state; operations : 'state operation list;
  }
  type definition
  val define : ?revision:int -> 'state spec -> definition
  val unit_state : unit state
end
module Flow : sig
  type spec = {id : string; input : Schema.fields; output : Schema.fields; body : string}
  type definition
  val define : ?version:int -> spec -> definition
  val of_json : Yojson.Safe.t -> definition
end
module Storage : sig
  type backend = {
    load : unit -> string option; save : string -> unit; close : unit -> unit;
  }
  type t
  val memory : t
  val backend : (string -> backend) -> t
end
module System : sig
  type definition
  type t
  val define :
    cell_kinds:Cell.definition list -> ?init_flow:string ->
    flows:Flow.definition list -> unit -> definition
  val create : ?id:string -> ?workers:int -> ?storage:Storage.t -> definition -> t
  val call : ?request_id:string -> t -> flow:string -> msg -> msg
  val catalog : t -> Yojson.Safe.t
  val close : t -> unit
end
