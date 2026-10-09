open Kom_contracts.Kom_types
module A = Kom_contracts.Execution_access
module Codec = Message_codec
type gate = Open | Quiescing of QuiescencePurpose.t * string | Closed
type t = {
  id:string; backend:Native_contract.backend;configuration:SystemConfiguration.t;
  mutex:Mutex.t; changed:Condition.t; mutable snapshot:A.StoreSnapshot.t option;
  mutable gate:gate; reservations:(string,Reservation.t) Hashtbl.t;
  busy:(string,string) Hashtbl.t; committed:(string,A.Committed.t) Hashtbl.t;
  residents:(string,StateRef.t) Hashtbl.t;
}
let create ?(workers=4) storage id =
  let location=match storage with Native_contract.Memory -> Storage.Memory
    | Backend(location,_) -> Storage.Durable (DurableStore.make ~location ()) in
  let configuration=SystemConfiguration.make ~storage:location ~workers () in
  let backend=match storage with Native_contract.Memory ->
    Native_contract.{load=(fun () -> None);save=(fun _ -> ());close=(fun () -> ())}
    | Backend (_,open_) -> open_ id in
  try
    let snapshot=Option.map (fun s -> Codec.unwrap (A.StoreSnapshot.from_drut s)) (backend.load ()) in
    Option.iter (fun (s : A.StoreSnapshot.t) -> if s.format_version<>1 then Codec.fail "Store" "Unsupported store version") snapshot;
    {id;backend;configuration;mutex=Mutex.create ();changed=Condition.create ();snapshot;
     gate=(if List.exists (fun (s : A.StoreSnapshot.t) -> s.closed) (Option.to_list snapshot) then Closed else Open);
     reservations=Hashtbl.create 16;busy=Hashtbl.create 16;committed=Hashtbl.create 16;residents=Hashtbl.create 16}
  with exn -> backend.close (); raise exn
let locked t f = Mutex.lock t.mutex; Fun.protect f ~finally:(fun () -> Mutex.unlock t.mutex)
let current t = match t.snapshot with Some s -> s | None -> Codec.fail "Store" "System is not active"
let load t = locked t (fun () -> t.snapshot)
let save t snapshot =
  t.backend.save (Codec.unwrap (A.StoreSnapshot.to_drut snapshot));
  t.snapshot <- Some snapshot; Condition.broadcast t.changed
let view t = locked t (fun () -> (current t).view)
let definition t = locked t (fun () -> (current t).definition)
let entry_ref t id = ExecutionRef.make ~system:(SystemRef.make ~id:t.id ()) ~id ()
let receipt t id = Receipt.make ~execution:(entry_ref t id) ()
let find s id = List.find_opt (fun (e : A.StoredExecution.t) -> e.entry.id=id) s.A.StoreSnapshot.executions
let execution t id = match find (current t) id with Some e -> e | None -> Codec.fail "Receipt" "Unknown execution"
let replace (s : A.StoreSnapshot.t) (e : A.StoredExecution.t) = {s with A.StoreSnapshot.executions=e::List.filter (fun (x : A.StoredExecution.t) -> x.entry.id<>e.A.StoredExecution.entry.id) s.executions}
let empty entry = A.StoredExecution.make ~entry ~work:[] ~settled:[] ~attempts:[] ()
let same_entry old entry =
  if old <> entry then Codec.fail "Identity" "An entry ID cannot be reused with different data"
let active t =
  Hashtbl.length t.reservations>0 ||
  List.exists (fun (e : A.StoredExecution.t) -> e.flow<>None && e.completion=None) (current t).executions
let existing t e =
  ExistingReceipt.make ~receipt:(receipt t e.A.StoredExecution.entry.id)
    ~status:(if e.flow=None && e.completion=None then AdmissionStatus.Buffered else Admitted) ()
let buffer t s entry =
  let e=match find s entry.Entry.id with Some e -> same_entry e.entry entry; e | None -> empty entry in
  save t (replace s e); receipt t entry.id
let prepare t entry = locked t (fun () ->
  let s=current t in
  if entry.Entry.system.id<>t.id then A.PrepareResponse.Rejected (Codec.problem "System" "Wrong system") else
  match find s entry.id with
  | Some e when e.flow<>None || e.completion<>None -> same_entry e.entry entry; A.PrepareResponse.Existing (existing t e)
  | _ -> (match t.gate,entry.parent with
    | Closed,_ | Quiescing(Closure,_),None -> A.PrepareResponse.Rejected (Codec.problem "Closed" "System is closing")
    | Quiescing(Revision,_),None -> A.PrepareResponse.Buffered (buffer t s entry)
    | _ -> A.PrepareResponse.Ready s.view))
let admit t (request : A.AdmitRequest.t) = locked t (fun () ->
  let s=current t and entry=request.entry in
  match find s entry.id with
  | Some e when e.flow<>None || e.completion<>None -> same_entry e.entry entry; A.AdmitResponse.Existing (existing t e)
  | _ ->
    (match t.gate,entry.parent with
    | Closed,_ | Quiescing(Closure,_),None -> A.AdmitResponse.Rejected (Codec.problem "Closed" "System is closing")
    | Quiescing(Revision,_),None -> A.AdmitResponse.Buffered (buffer t s entry)
    | _ when s.view.revision<>request.expected_revision -> A.AdmitResponse.RevisionChanged s.view
    | _ ->
      let old=match find s entry.id with Some e -> same_entry e.entry entry; e | None -> empty entry in
      match request.decision with
      | A.AdmissionDecision.Rejected ps ->
        let p=match ps.Problems.items with p::_ -> p | [] -> Codec.problem "Flow" "Admission rejected" in
        save t (replace s {old with completion=Some (Completion.Failed p)});
        A.AdmitResponse.Rejected p
      | Planned plan ->
        let checkpoint=ProgressCheckpoint.make ~version:0 ~progress:plan.progress () in
        let e={old with flow=Some plan.flow;checkpoint=Some checkpoint;work=plan.work;completion=plan.completion} in
        save t (replace s e); A.AdmitResponse.Admitted (receipt t entry.id)))
let ready t = locked t (fun () ->
  List.concat_map (fun (e : A.StoredExecution.t) -> if e.completion<>None then [] else
    List.filter_map (fun (w : Work.t) ->
      if List.mem w.id e.settled || Hashtbl.mem t.busy w.cell_id ||
        Hashtbl.fold (fun _ (r : Reservation.t) yes -> yes || (r.execution.id=e.entry.id && r.work.id=w.id)) t.reservations false
      then None else Some (WorkRef.make ~execution:(entry_ref t e.entry.id) ~work_id:w.id ())) e.work) (current t).executions)
let reserve t (wr : WorkRef.t) = locked t (fun () ->
  let e=execution t wr.execution.id in
  if e.completion<>None || List.mem wr.work_id e.settled then A.ReserveResponse.AlreadySettled else
  let work=match List.find_opt (fun (w : Work.t) -> w.id=wr.work_id) e.work with
    | Some w -> w | None -> Codec.fail "Work" "Unknown work" in
  if Hashtbl.mem t.busy work.cell_id then A.ReserveResponse.Busy else
  let stored=List.find (fun (s : StoredCellState.t) -> s.cell_id=work.cell_id) (current t).states in
  let checkpoint=Option.get e.checkpoint in
  let state=match Hashtbl.find_opt t.residents work.cell_id with Some r -> StateLocation.Resident r | None -> Stored stored.snapshot in
  let token=Hosting.uuid () in
  let r=Reservation.make ~token ~execution:wr.execution ~work ~implementation:stored.implementation ~state
    ~flow:(Option.get e.flow) ~progress:checkpoint.progress ~progress_version:checkpoint.version ?parent:e.entry.parent () in
  Hashtbl.add t.reservations token r; Hashtbl.add t.busy work.cell_id token;
  A.ReserveResponse.Reserved r)
let unreserve t (r : Reservation.t) =
  Hashtbl.remove t.reservations r.token; Hashtbl.remove t.busy r.work.cell_id; Condition.broadcast t.changed
let commit t (request : A.CommitRequest.t) = locked t (fun () ->
  match Hashtbl.find_opt t.committed request.reservation_token with
  | Some response -> A.CommitResponse.AlreadyCommitted response
  | None -> (match Hashtbl.find_opt t.reservations request.reservation_token with
    | None -> A.CommitResponse.StaleReservation
    | Some r ->
      let s=current t and e=execution t r.execution.id in
      if e.completion<>None then A.CommitResponse.StaleReservation else
      let cp=Option.get e.checkpoint in
      if cp.version<>request.expected_progress_version then A.CommitResponse.ProgressChanged cp else
      try
        let checkpoint=ProgressCheckpoint.make ~version:(cp.version+1) ~progress:request.advancement.progress () in
        let e={e with A.StoredExecution.checkpoint=Some checkpoint; settled=r.work.id::e.settled;
          work=e.work @ request.advancement.work; completion=request.advancement.completion} in
        let state=StoredCellState.make ~cell_id:r.work.cell_id ~implementation:r.implementation ~snapshot:request.state.snapshot () in
        let s=replace s e in
        let s={s with states=state::List.filter (fun (old : StoredCellState.t) -> old.cell_id<>state.cell_id) s.states} in
        let replaced_state=Hashtbl.find_opt t.residents state.cell_id in
        let work=List.map (fun (w : Work.t) -> WorkRef.make ~execution:r.execution ~work_id:w.id ()) request.advancement.work in
        let response=A.Committed.make ~execution:r.execution ~work ?replaced_state ?completion:e.completion () in
        save t s;
        Hashtbl.replace t.residents state.cell_id request.state.value;
        Hashtbl.add t.committed r.token response; unreserve t r;
        A.CommitResponse.Committed response
      with exn -> A.CommitResponse.Failed (Codec.problem "Store" (Printexc.to_string exn))))
let attempts t (r : Reservation.t) = locked t (fun () ->
  let e=execution t r.execution.id in
  match List.find_opt (fun (a : A.AttemptCount.t) -> a.work_id=r.work.id) e.attempts with Some a -> a.count+1 | None -> 1)
let release t token decision = locked t (fun () ->
  match Hashtbl.find_opt t.reservations token with
  | None -> A.ReleaseResponse.AlreadySettled
  | Some r ->
    let s=current t and e=execution t r.execution.id in
    try
      let count=match List.find_opt (fun (a : A.AttemptCount.t) -> a.work_id=r.work.id) e.attempts with Some a -> a.count+1 | None -> 1 in
      let a=A.AttemptCount.make ~work_id:r.work.id ~count () in
      let completion=match e.completion,decision with
        | Some c,_ -> Some c | None,FailureDecision.Fail p -> Some (Completion.Failed p) | None,Retry _ -> None in
      let e={e with attempts=a::List.filter (fun (a : A.AttemptCount.t) -> a.work_id<>r.work.id) e.attempts;completion} in
      save t (replace s e); unreserve t r; A.ReleaseResponse.Released
    with exn -> A.ReleaseResponse.Failed (Codec.problem "Store" (Printexc.to_string exn)))
let await t receipt = locked t (fun () ->
  if receipt.Receipt.execution.system.id<>t.id then AwaitResponse.UnknownReceipt else
  let rec wait () = match find (current t) receipt.execution.id with
    | None -> AwaitResponse.UnknownReceipt
    | Some e -> (match e.completion with Some c -> AwaitResponse.Finished c
      | None -> Condition.wait t.changed t.mutex; wait ()) in wait ())
let buffered t = locked t (fun () ->
  if t.gate<>Open then [] else List.filter_map (fun (e : A.StoredExecution.t) ->
    if e.flow=None && e.completion=None then Some e.entry else None) (current t).executions)
let quiesce t purpose = locked t (fun () ->
  if purpose=QuiescencePurpose.Closure then (
    let changing () = match t.gate with Quiescing _ -> true | _ -> false in
    while changing () do Condition.wait t.changed t.mutex done);
  if t.gate<>Open then Codec.fail "Revision" "Another configuration change owns the system";
  let token=Hosting.uuid () in t.gate <- Quiescing(purpose,token);
  while active t do Condition.wait t.changed t.mutex done;
  let s=current t in
  QuiescentSystem.make ~quiescence:(QuiescenceRef.make ~system:s.view.system ~token ())
    ~view:s.view ~definition:s.definition ~configuration:t.configuration ~states:s.states ())
let check_token t q = match t.gate with
  | Quiescing(_,token) when token=q.QuiescenceRef.token && q.system.id=t.id -> ()
  | _ -> Codec.fail "Revision" "Stale quiescence token"
let activate t basis revision = locked t (fun () ->
  (match basis with ActivationBasis.New _ -> if t.snapshot<>None then Codec.fail "Revision" "System already exists"
    | Quiescent q -> check_token t q; if active t then Codec.fail "Revision" "Work is still active");
  let cells=List.map (fun (p : PreparedCell.t) ->
    let d=List.find (fun (d : CellDefinition.t) -> d.implementation=p.implementation) revision.PreparedRevision.code.definitions in
    CellBinding.make ~cell_id:p.cell_id ~definition:d ()) revision.cells in
  let ids=List.map (fun (p : PreparedCell.t) -> p.cell_id) revision.cells |> List.sort String.compare in
  let expected=List.map (fun (s : CellSpec.t) -> s.id) revision.definition.cells |> List.sort String.compare in
  if ids<>expected || List.length ids<>List.length (List.sort_uniq String.compare ids) then Codec.fail "Revision" "Incomplete prepared state set";
  let view=SystemView.make ~system:(SystemRef.make ~id:t.id ()) ~revision:revision.revision ~cells ~catalog:revision.catalog () in
  let states=List.map (fun (p : PreparedCell.t) -> StoredCellState.make ~cell_id:p.cell_id ~implementation:p.implementation ~snapshot:p.state.snapshot ()) revision.cells in
  let executions=match t.snapshot with None -> [] | Some s -> s.executions in
  let flow_history=Option.value ~default:revision.definition.flows revision.flow_history in
  let s=A.StoreSnapshot.make ~format_version:1 ~view ~definition:revision.definition ~configuration:t.configuration
    ~flow_history ~states ~executions ~closed:false () in
  let old=Hashtbl.fold (fun _ r xs -> r::xs) t.residents [] in
  save t s;
  Hashtbl.clear t.residents;
  List.iter (fun (p : PreparedCell.t) -> Hashtbl.add t.residents p.cell_id p.state.value) revision.cells;
  t.gate <- Open; Condition.broadcast t.changed; old)
let attach t refs = locked t (fun () -> List.iter (fun (id,r) -> Hashtbl.replace t.residents id r) refs)
let resume t q = locked t (fun () -> check_token t q; t.gate <- Open; Condition.broadcast t.changed)
let close t q = locked t (fun () ->
  check_token t q;
  if active t then Codec.fail "Closed" "System still has active work";
  let s=current t in
  let executions=List.map (fun (e : A.StoredExecution.t) -> if e.completion=None then
    {e with completion=Some (Completion.Failed (Codec.problem "Closed" "System closed before admission"))} else e) s.executions in
  save t {s with closed=true;executions}; t.gate <- Closed;
  let refs=Hashtbl.fold (fun _ r xs -> r::xs) t.residents [] in
  Hashtbl.clear t.residents; refs)
let dispose t = t.backend.close ()
