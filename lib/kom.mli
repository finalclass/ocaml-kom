module Json : sig
  type t = Yojson.Safe.t
  exception Error of string
  val of_string : string -> t
  val to_string : t -> string
  val object_ : (string * t) list -> t
  val string : string -> t
  val int : int -> t
  val array : t list -> t
  val null : t
  val is_null : t -> bool
  val fields : t -> (string * t) list
  val get : string -> t -> t
  val get_string : string -> t -> string
  val get_int : string -> t -> int
  val get_bool : string -> t -> bool
  val get_list : string -> t -> t list
  val get_string_list : string -> t -> string list
  val set : string -> t -> t -> t
end
module Schema : sig
  type value =
    | String | Int | Float | Bool
    | List of value | Object of fields | Optional of value
  and fields = (string * value) list
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
        impl : 'state -> Json.t -> 'state * Json.t;
      }
    | Expander of {
        op : string; input : Schema.fields; output : Schema.fields;
        impl : 'state -> Json.t -> 'state * Json.t list;
      }
    | Joiner of {
        op : string; input : Schema.fields; output : Schema.fields;
        impl : 'state -> Json.t list -> 'state * Json.t;
      }
    | Router of {
        op : string; input : Schema.fields; output : (string * Schema.fields) list;
        impl : 'state -> Json.t -> 'state * (string * Json.t);
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
  val of_json : Json.t -> definition
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
  val call : ?request_id:string -> t -> flow:string -> Json.t -> Json.t
  val catalog : t -> Json.t
  val close : t -> unit
end
