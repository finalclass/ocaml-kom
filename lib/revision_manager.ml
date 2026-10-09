open Kom_contracts.Kom_types
open Native_contract
module Codec=Message_codec
type t={ store:Execution_access.t; code:Cell_code_access.t; flows:Flow_access.t;
  engine:Cell_engine.t; bus:Message_bus.t; mutable closed:bool }
let result = function Ok x -> x | Error p -> raise (Codec.Invalid p)
let refs_release t refs = List.iter (Cell_engine.release t.engine) refs
let prepare t (definition : definition) =
  Cell_code_access.register t.code definition.implementations;
  let bindings=Cell_code_access.prepare t.code definition.wire in
  let ids=List.map (fun (s : CellSpec.t) -> s.id) definition.wire.cells in
  if List.length ids<>List.length (List.sort_uniq String.compare ids) then Codec.fail "Revision" "Duplicate cell ID";
  List.iter (fun (c : CellBinding.t) ->
    let names=List.map (fun (o : Operation.t) -> o.name) c.definition.operations in
    if List.length names<>List.length (List.sort_uniq String.compare names) then Codec.fail "Contract" "Duplicate operation") bindings;
  let catalog=Flow_access.stage t.flows definition.wire.flows in
  let view=SystemView.make ~system:(SystemRef.make ~id:t.store.id ()) ~revision:"prepared" ~cells:bindings ~catalog () in
  List.iter (fun (f : NamedFlow.t) -> ignore (Flow_engine.validate ~catalog ~flows:t.flows ~system:view f.definition)) definition.wire.flows;
  catalog,bindings
let prepared t definition catalog bindings states =
  let code=CodeStage.make ~id:(Hosting.uuid ()) ~definitions:(List.map (fun (c : CellBinding.t) -> c.definition) bindings) () in
  PreparedRevision.make ~revision:(Hosting.uuid ()) ~definition:definition.wire ~code ~catalog ~cells:states
    ~flow_history:(Flow_access.history t.flows) ()
let prepare_cell t (spec : CellSpec.t) value =
  let snapshot=result (Cell_engine.snapshot t.engine value) in
  PreparedCell.make ~cell_id:spec.id ~implementation:spec.implementation ~state:(PreparedState.make ~value ~snapshot ()) ()
let activate_initial t definition =
  let refs=ref [] in
  try
    match Execution_access.load t.store with
    | Some saved ->
      if saved.closed then Codec.fail "Closed" "Stored system was closed";
      Cell_code_access.register t.code definition.implementations;
      Flow_access.remember t.flows saved.flow_history;
      let bindings=Cell_code_access.prepare t.code saved.definition in
      if bindings<>saved.view.cells then Codec.fail "Code" "Pinned implementation descriptor changed";
      let catalog=Flow_access.stage t.flows saved.definition.flows in
      if catalog<>saved.view.catalog then Codec.fail "Store" "Stored catalog identity mismatch";
      let states=List.map (fun (s : StoredCellState.t) ->
        let spec=List.find (fun (c : CellSpec.t) -> c.id=s.cell_id) saved.definition.cells in
        let value=match Cell_engine.restore t.engine spec s.snapshot with
          | Restored r -> r | Unsupported p | Failed p -> raise (Codec.Invalid p) in
        refs := value :: !refs; s.cell_id,value) saved.states in
      Execution_access.attach t.store states;
      Ok ()
    | None ->
      let catalog,bindings=prepare t definition in
      let states=List.map (fun spec -> let value=result (Cell_engine.initialize t.engine spec) in
        refs := value::!refs; prepare_cell t spec value) definition.wire.cells in
      let revision=prepared t definition catalog bindings states in
      ignore (Execution_access.activate t.store (ActivationBasis.New (NewSystem.make ~system:(SystemRef.make ~id:t.store.id ())
        ~configuration:t.store.configuration ())) revision);
      Ok ()
  with
  | Codec.Invalid p -> refs_release t !refs; Execution_access.dispose t.store; Error (Problems.make ~items:[p] ())
  | exn -> refs_release t !refs; Execution_access.dispose t.store; Error (Problems.make ~items:[Codec.problem "Exception" (Printexc.to_string exn)] ())
let create ~scheduler ~storage ~id definition =
  try
    let code=Cell_code_access.create () in
    let flows=Flow_access.create () in
    let store=Execution_access.create ~workers:scheduler.Scheduler.capacity storage id in
    let engine=Cell_engine.create ~code ~scheduler ~storage ~system_id:id in
    let bus=Message_bus.create () in
    let t={store;code;flows;engine;bus;closed=false} in
    match activate_initial t definition with Ok () -> Ok t | Error p -> Error p
  with
  | Codec.Invalid p -> Error (Problems.make ~items:[p] ())
  | exn -> Error (Problems.make ~items:[Codec.problem "Exception" (Printexc.to_string exn)] ())
let compatible old bindings =
  List.iter (fun (c : CellBinding.t) ->
    match List.find_opt (fun (n : CellBinding.t) -> n.cell_id=c.cell_id) bindings with
    | None -> ()
    | Some n ->
      let sort=List.sort (fun (a : Operation.t) b -> String.compare a.name b.name) in
      if sort c.definition.operations<>sort n.definition.operations then Codec.fail "Contract" "Update changes an existing cell's message contract") old.SystemView.cells
let update t ~force definition =
  let q=ref None and refs=ref [] in
  let rollback p =
    refs_release t !refs;
    Option.iter (Execution_access.resume t.store) !q;
    Message_bus.admission t.bus;
    Error (Problems.make ~items:[p] ()) in
  try
    let catalog,bindings=prepare t definition in
    compatible (Execution_access.view t.store) bindings;
    let quiescent=Execution_access.quiesce t.store QuiescencePurpose.Revision in
    q := Some quiescent.quiescence;
    let states=List.map (fun (spec : CellSpec.t) ->
      let value=match List.find_opt (fun (s : StoredCellState.t) -> s.cell_id=spec.id) quiescent.states with
        | None -> result (Cell_engine.initialize t.engine spec)
        | Some old -> (match Cell_engine.restore t.engine spec old.snapshot with
          | Restored r -> r
          | Unsupported _ when force -> result (Cell_engine.initialize t.engine spec)
          | Unsupported p | Failed p -> raise (Codec.Invalid p)) in
      refs := value::!refs; prepare_cell t spec value) definition.wire.cells in
    let revision=prepared t definition catalog bindings states in
    let old=Execution_access.activate t.store (ActivationBasis.Quiescent quiescent.quiescence) revision in
    refs := []; q := None;
    refs_release t old;
    Message_bus.admission t.bus; Ok ()
  with
  | Codec.Invalid p -> rollback p
  | exn -> rollback (Codec.problem "Exception" (Printexc.to_string exn))
let instantiate t spec cell =
  let old=Execution_access.definition t.store in
  if List.exists (fun (s : CellSpec.t) -> s.id=spec.CellSpec.id) old.cells then
    Error (Problems.make ~items:[Codec.problem "Revision" "Cell ID already exists"] ())
  else update t ~force:false {wire={old with cells=old.cells@[spec]};implementations=[cell]}
let close t = if not t.closed then (
  let q=Execution_access.quiesce t.store QuiescencePurpose.Closure in
  System_access.close t.store.id;
  let refs=Execution_access.close t.store q.quiescence in
  t.closed <- true;
  Fun.protect ~finally:(fun () -> Execution_access.dispose t.store) (fun () ->
    refs_release t refs;
    Flow_access.discard t.flows q.view.catalog;
    Cell_code_access.discard t.code))
