open Kom_contracts.Kom_types
type backend = { load: unit -> string option; save:string -> unit; close:unit -> unit }
type storage = Memory | Backend of string * (string -> backend)
type 'a restoration = Restored of 'a | Unsupported of Problem.t | Failed of Problem.t
type context = {
  system_id:string; cell_id:string; execution_id:string; work_id:string;
  child: id:string -> definition -> system;
  call: call_id:string -> system -> FlowSelector.t -> Message.t -> Completion.t;
}
and cell = Cell : 's implementation -> cell
and 's implementation = {
  id:string; revision:string; state_version:int; operations:Operation.t list;
  init:context -> Yojson.Safe.t -> ('s,Problem.t) result;
  handle:context -> 's -> operation:string -> Message.t -> ('s * MessageBatch.t,Problem.t) result;
  snapshot:'s -> (string,Problem.t) result;
  restore:context -> Yojson.Safe.t -> StateSnapshot.t -> 's restoration;
  release:'s -> unit;
}
and definition = { wire:SystemDefinition.t; implementations:cell list }
and system = {
  id:string; scheduler:Scheduler.t; storage:storage;
  send:Entry.t -> SendResponse.t;
  await:Receipt.t -> AwaitResponse.t;
  update:force:bool -> definition -> (unit, Problems.t) result;
  instantiate:CellSpec.t -> cell -> (unit, Problems.t) result;
  close:unit -> unit;
}
module type Cell = sig
  type state
  val id:string
  val revision:string
  val state_version:int
  val operations:Operation.t list
  val init:context -> Yojson.Safe.t -> (state,Problem.t) result
  val handle:context -> state -> operation:string -> Message.t -> (state * MessageBatch.t,Problem.t) result
  val snapshot:state -> (string,Problem.t) result
  val restore:context -> Yojson.Safe.t -> StateSnapshot.t -> state restoration
  val release:state -> unit
end
