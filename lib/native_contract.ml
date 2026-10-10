type msg = Json.t
type error = { code : string; message : string; path : string option }
exception Error of error
let fail ?path code message = raise (Error {code; message; path})
let error_of_exn ?path = function
  | Error error -> {error with path = (match error.path with Some _ -> error.path | None -> path)}
  | Json.Error message -> {code = "Contract"; message; path}
  | exn -> {code = "Exception"; message = Printexc.to_string exn; path}
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
type 'state cell_spec = {
  id : string; state : 'state state; operations : 'state operation list;
}
type cell = Cell : int * 'state cell_spec -> cell
type segment = Literal of string | Field of string list
type template = { text : string; parts : segment list }
type step = { op : string; target : template; kind : string }
type node =
  | Step of step | Reproduce of string * template
  | Sequence of node list | Parallel of node list | Each of node | Flatten
  | Branch of node * (string * node) list
type flow_spec = {
  id : string; input : Schema.fields; output : Schema.fields; body : string;
}
type flow = { version : int; spec : flow_spec; ast : node }
type definition = {
  cells : cell list; flows : flow list; init_flow : string option;
  bindings : (template * string) list; catalog : Json.t;
}
type value = Message of msg | Group of value list | Port of string * msg
type stored_cell = { address : string; kind : string; revision : int; version : int; data : string }
type outcome = (msg, error) result
type execution = {
  request_id : string; flow_id : string; input : msg;
  results : (string * value) list; outcome : outcome option;
}
type snapshot = {
  format : int; catalog : Json.t; initialized : bool;
  cells : stored_cell list; executions : execution list;
}
type backend = { load : unit -> string option; save : string -> unit; close : unit -> unit }
type storage = Memory | Backend of (string -> backend)
let operation_name = function
  | Transformer value -> value.op | Expander value -> value.op
  | Joiner value -> value.op | Router value -> value.op
let unit_state = {
  version = 1; init = (fun () -> ());
  to_string = (fun () -> "null");
  of_string = (fun text ->
    try if Json.of_string text = `Null then Ok () else Result.Error "Expected null"
    with Json.Error message -> Result.Error message);
}
