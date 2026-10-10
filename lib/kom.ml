module Json = Json
module Schema = Schema
type msg = Native_contract.msg
type error = Native_contract.error = {code : string; message : string; path : string option}
exception Error = Native_contract.Error
let protect f = try f () with exn -> raise (Error (Native_contract.error_of_exn exn))
module Cell = struct
  type 'state state = 'state Native_contract.state = {
    version : int; init : unit -> 'state;
    to_string : 'state -> string; of_string : string -> ('state, string) result;
  }
  type 'state operation = 'state Native_contract.operation =
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
  type 'state spec = 'state Native_contract.cell_spec = {
    id : string; state : 'state state; operations : 'state operation list;
  }
  type definition = Native_contract.cell
  let define ?(revision = 1) spec = protect (fun () ->
    let cell = Native_contract.Cell (revision, spec) in Cell_code_access.validate cell; cell)
  let unit_state = Native_contract.unit_state
end
module Flow = struct
  type spec = Native_contract.flow_spec = {
    id : string; input : Schema.fields; output : Schema.fields; body : string;
  }
  type definition = Native_contract.flow
  let define ?version spec = protect (fun () -> Flow_access.define ?version spec)
  let of_json json = protect (fun () -> Flow_access.of_json json)
end
module Storage = struct
  type backend = Native_contract.backend = {
    load : unit -> string option; save : string -> unit; close : unit -> unit;
  }
  type t = Native_contract.storage
  let memory = Native_contract.Memory
  let backend open_ = Native_contract.Backend open_
end
module System = struct
  type definition = Native_contract.definition
  type t = Execution_manager.t
  let define ~cell_kinds ?init_flow ~flows () =
    protect (fun () -> Revision_manager.define ~cell_kinds ?init_flow ~flows ())
  let create ?(id = "main") ?(workers = 4) ?(storage = Storage.memory) definition =
    protect (fun () -> Execution_manager.create ~workers ~storage ~id definition)
  let call ?request_id system ~flow message =
    protect (fun () -> Execution_manager.call ?request_id system ~flow message)
  let catalog system = system.Execution_manager.definition.Native_contract.catalog
  let close system = protect (fun () -> Execution_manager.close system)
end
