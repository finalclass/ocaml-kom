open Kom_contracts.Kom_types
open Native_contract
type resident = State : 's implementation * 's -> resident
type t = { code:Cell_code_access.t; states:(string,resident) Hashtbl.t; mutex:Mutex.t;
  scheduler:Scheduler.t; storage:storage; system_id:string }
let create ~code ~scheduler ~storage ~system_id = {code;states=Hashtbl.create 32;mutex=Mutex.create ();scheduler;storage;system_id}
let with_lock t f = Mutex.lock t.mutex; Fun.protect f ~finally:(fun () -> Mutex.unlock t.mutex)
let context t ~cell_id ~execution_id ~work_id = {
  system_id=t.system_id;cell_id;execution_id;work_id;
  child=(fun ~id def -> System_access.create ~scheduler:t.scheduler ~storage:t.storage ~owner:t.system_id ~cell_id ~id def);
  call=(fun ~call_id child flow message -> System_access.call ~system_id:t.system_id ~execution_id ~work_id ~call_id child flow message) }
let protect f = try f () with
  | Message_codec.Invalid p -> Error p
  | exn -> Error (Message_codec.problem "Exception" (Printexc.to_string exn))
let hold t c state = let id=Hosting.uuid () in
  with_lock t (fun () -> Hashtbl.add t.states id (State(c,state))); StateRef.make ~id ()
let state t r = with_lock t (fun () -> match Hashtbl.find_opt t.states r.StateRef.id with
  | Some s -> s | None -> Message_codec.fail "State" "Unknown resident state")
let initialize t (spec : CellSpec.t) = protect (fun () ->
  let Cell c=Cell_code_access.resolve t.code spec.implementation in
  let ctx=context t ~cell_id:spec.id ~execution_id:"" ~work_id:"" in
  match c.init ctx spec.configuration with Ok s -> Ok (hold t c s) | Error p -> Error p)
let restore t (spec : CellSpec.t) snapshot =
  let Cell c=Cell_code_access.resolve t.code spec.implementation in
  let ctx=context t ~cell_id:spec.id ~execution_id:"" ~work_id:"" in
  try match c.restore ctx spec.configuration snapshot with
    | Restored s -> Restored (hold t c s) | Unsupported p -> Unsupported p | Failed p -> Failed p
  with exn -> Failed (Message_codec.problem "Exception" (Printexc.to_string exn))
let snapshot t r = protect (fun () -> let State(c,s)=state t r in
  match c.snapshot s with
  | Error p -> Error p
  | Ok data -> Ok (StateSnapshot.make ~state_version:c.state_version ~data ()))
let release t r =
  let s=with_lock t (fun () -> let s=Hashtbl.find_opt t.states r.StateRef.id in Hashtbl.remove t.states r.id; s) in
  Option.iter (fun (State(c,s)) -> c.release s) s
let handle t (spec : CellSpec.t) (reservation : Reservation.t) = protect (fun () ->
  let Cell c=Cell_code_access.resolve t.code reservation.implementation in
  let op=match List.find_opt (fun (o : Operation.t) -> o.name=reservation.work.operation) c.operations with
    | Some o -> o | None -> Message_codec.fail "Contract" "Unknown operation" in
  Message_codec.accepts op.input reservation.work.message;
  let snap=match reservation.state with Stored s -> s | Resident r ->
    (match snapshot t r with Ok s -> s | Error p -> raise (Message_codec.Invalid p)) in
  let ctx=context t ~cell_id:spec.id ~execution_id:reservation.execution.id ~work_id:reservation.work.id in
  let copy=match c.restore ctx spec.configuration snap with
    | Restored s -> s | Unsupported p | Failed p -> raise (Message_codec.Invalid p) in
  let keep=ref false in
  Fun.protect ~finally:(fun () -> if not !keep then c.release copy) (fun () ->
    match c.handle ctx copy ~operation:op.name reservation.work.message with
    | Error p -> Error p
    | Ok (next,messages) ->
      (try
        List.iter (fun (m : Message.t) ->
          if not (List.mem m.type' op.outputs) then Message_codec.fail "Contract" "Undeclared cell output";
          Message_codec.validate m) messages.MessageBatch.items;
        let data=match c.snapshot next with Ok d -> d | Error p -> raise (Message_codec.Invalid p) in
        keep := true;
        let value=hold t c next in
        Ok (PreparedState.make ~value ~snapshot:(StateSnapshot.make ~state_version:c.state_version ~data ()) (),messages)
       with exn -> if not (next == copy) then c.release next; raise exn)))
