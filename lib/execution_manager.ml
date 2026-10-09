open Kom_contracts.Kom_types
module A=Kom_contracts.Execution_access
module Codec=Message_codec
type t={ store:Execution_access.t; flows:Flow_access.t; engine:Cell_engine.t;
  scheduler:Scheduler.t; bus:Message_bus.t; max_attempts:int }
let problems p=Problems.make ~items:[p] ()
let retryable (p : Problem.t) = not (List.mem p.code ["Contract";"Codec";"Flow";"Branch";"Binding";"Checkpoint";"Descriptor";"Identity";"State";"Code"])
let settle t (r : Reservation.t) p =
  let decision=if retryable p && Execution_access.attempts t.store r < t.max_attempts then
    FailureDecision.Retry (Retry.make ~problem:p ~delay_ms:0 ()) else Fail p in
  match Execution_access.release t.store r.token decision with
  | A.ReleaseResponse.Failed p -> raise (Codec.Invalid p)
  | Released | AlreadySettled -> ()
let run t (r : Reservation.t) =
  let candidate=ref None in
  Fun.protect ~finally:(fun () ->
    Option.iter (Cell_engine.release t.engine) !candidate;
    Message_bus.work t.bus) (fun () ->
    try
      let def=Execution_access.definition t.store in
      let spec=List.find (fun (s : CellSpec.t) -> s.id=r.work.cell_id) def.cells in
      match Cell_engine.handle t.engine spec r with
      | Error p -> settle t r p
      | Ok (state,messages) ->
        candidate := Some state.PreparedState.value;
        let output=StepOutput.make ~work_id:r.work.id ~node_id:r.work.node_id ~branch_path:r.work.branch_path ~messages () in
        let rec commit progress version =
          let advancement=Flow_engine.advance r.flow progress output in
          let request=A.CommitRequest.make ~reservation_token:r.token ~expected_progress_version:version ~state ~advancement () in
          match Execution_access.commit t.store request with
          | A.CommitResponse.ProgressChanged cp -> commit cp.progress cp.version
          | Committed c -> candidate := None; Option.iter (Cell_engine.release t.engine) c.replaced_state
          | AlreadyCommitted _ -> candidate := None
          | StaleReservation -> ignore (Execution_access.release t.store r.token (FailureDecision.Fail (Codec.problem "Reservation" "Stale reservation")))
          | Failed p -> settle t r p in
        commit r.progress r.progress_version
    with
    | Codec.Invalid p -> settle t r p
    | exn -> settle t r (Codec.problem "Exception" (Printexc.to_string exn)))
let process t work = match Execution_access.reserve t.store work with
  | A.ReserveResponse.Reserved r -> Scheduler.submit t.scheduler (fun () -> run t r)
  | Busy | AlreadySettled | Rejected _ -> ()
let tick t = List.iter (process t) (Execution_access.ready t.store)
let rec send t entry =
  try match Execution_access.prepare t.store entry with
  | A.PrepareResponse.Buffered r -> SendResponse.Buffered r
  | Existing e -> (match e.status with AdmissionStatus.Admitted -> SendResponse.Admitted e.receipt | Buffered -> Buffered e.receipt)
  | Rejected p -> SendResponse.Rejected (problems p)
  | Ready view ->
    let decision=try
      let definition=match entry.Entry.flow with
        | FlowSelector.Inline def -> def | Id id -> (Flow_access.resolve t.flows view.catalog id).definition in
      let flow=Flow_engine.validate ~catalog:view.catalog ~flows:t.flows ~system:view definition in
      A.AdmissionDecision.Planned (Flow_engine.start flow entry.message)
      with Codec.Invalid p -> A.AdmissionDecision.Rejected (problems p) in
    let request=A.AdmitRequest.make ~entry ~expected_revision:view.revision ~decision () in
    (match Execution_access.admit t.store request with
    | A.AdmitResponse.RevisionChanged _ -> send t entry
    | Rejected p -> SendResponse.Rejected (problems p)
    | Buffered r -> SendResponse.Buffered r
    | Admitted r -> Message_bus.work t.bus; SendResponse.Admitted r
    | Existing e -> (match e.status with AdmissionStatus.Admitted -> SendResponse.Admitted e.receipt | Buffered -> Buffered e.receipt))
  with Codec.Invalid p -> SendResponse.Rejected (problems p)
let admit_buffer t = List.iter (fun e -> ignore (send t e)) (Execution_access.buffered t.store)
let await t receipt = Execution_access.await t.store receipt
let call t entry = match send t entry with
  | SendResponse.Rejected ps -> Error ps
  | Admitted r | Buffered r -> Ok (await t r)
