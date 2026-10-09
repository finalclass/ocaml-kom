open Kom_contracts.Kom_types
open Native_contract
let create ~scheduler ~storage ~owner ~cell_id ~id definition =
  Hosting.child ~scheduler ~storage ~owner ~cell_id ~id definition
let send ~system_id ~execution_id ~work_id ~call_id child flow message =
  let id=Yojson.Safe.to_string (`List [`String system_id;`String execution_id;`String work_id;`String call_id]) in
  let owner=SystemRef.make ~id:system_id () in
  let execution=ExecutionRef.make ~system:owner ~id:execution_id () in
  let parent=ParentExecution.make ~execution ~call_id:id () in
  child.send (Entry.make ~id ~system:(SystemRef.make ~id:child.id ()) ~flow ~message ~parent ())
let await child receipt = Scheduler.suspend child.scheduler (fun () -> child.await receipt)
let call ~system_id ~execution_id ~work_id ~call_id child flow message =
  match send ~system_id ~execution_id ~work_id ~call_id child flow message with
  | SendResponse.Rejected p -> Completion.Failed (List.hd p.Problems.items)
  | Admitted receipt | Buffered receipt -> (match await child receipt with
    | AwaitResponse.Finished c -> c | UnknownReceipt -> Completion.Failed (Message_codec.problem "Child" "Unknown child receipt"))
let close owner = Hosting.close_children owner
