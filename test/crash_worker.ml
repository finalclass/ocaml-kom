open Example_cells.Model
module T=Kom.Types
let mode=Sys.argv.(1)
let seed=Filename.check_suffix mode "-seed"
let child_mode=String.starts_with ~prefix:"child" mode
let history_mode=String.starts_with ~prefix:"history" mode
let storage=Kom_sqlite.storage Sys.argv.(2)
let publication_mutex=Mutex.create ()
let publication_changed=Condition.create ()
let published=ref false
let blocked ()=
  Mutex.lock publication_mutex;
  while not !published do Condition.wait publication_changed publication_mutex done;
  Mutex.unlock publication_mutex;
  print_endline "READY";flush stdout;ignore (read_line ())
let c1=counter ~id:"counter" ~on_handle:(fun ctx ->
  if seed && not history_mode && Kom.Context.cell_id ctx="b" then blocked ()) ()
let c2=counter ~id:"counter" ~revision:"2" ~init:100 ()
let leaf version = Kom.Flow.define ~id:"leaf" ~version (Kom.Flow.sequence [
  step ~id:"a" "a";
  step ~id:"b" ~input:(Kom.Flow.bind (Kom.Flow.output "a")) "b"])
let wrap version leaf=Kom.Flow.define ~id:"wrap" ~version (Kom.Flow.use ~as_:"nested" leaf)
let root version wrapped=Kom.Flow.define ~id:"root" ~version (Kom.Flow.use ~as_:"outer" wrapped)
let flow_definition version =
  let leaf=leaf version in let wrap=wrap version leaf in let root=root version wrap in
  let cell=if version=1 then c1 else c2 in
  Kom.System.define ~implementations:[c1;c2]
    ~cells:[Kom.Cell.spec ~id:"a" cell;Kom.Cell.spec ~id:"b" cell] ~flows:[leaf;wrap;root] ()
let make_definition ()=
  if not child_mode then (
    let version=if seed then 1 else 2 in
    flow_definition version)
  else
    let child_def=child_definition (counter ~id:"child" ()) in
    let module P=struct
      type state=unit
      let id="parent"
      let revision="1"
      let state_version=1
      let operations=[Kom.Operation.make ~name:"Run" ~input:value ~outputs:[Kom.Message.type_ value]]
      let init _ _=Ok ()
      let handle ctx () ~operation:_ m=
        let child=Kom.Context.child ctx ~id:"stable" child_def in
        let result=Kom.Context.call ctx ~call_id:"calculate" child ~flow:(Kom.Flow.inline (step ~id:"child-step" "child")) m in
        if seed then blocked ();
        Ok ((),Kom.Message.batch (completed result))
      let snapshot ()=Ok "unit"
      let restore _ _ _=Kom.Cell.Restored ()
      let release ()=()
    end in definition [Kom.Cell.spec ~id:"parent" (Kom.Cell.define (module P))]
let ()=
  let def=make_definition () in
  if not seed && not child_mode && not history_mode then (
    let missing=Kom.System.define ~cells:[Kom.Cell.spec ~id:"a" c2;Kom.Cell.spec ~id:"b" c2] ~flows:[] () in
    match Kom.System.create ~id:"recover" ~workers:1 ~storage missing with
    | Error ps when List.exists (fun (p : T.Problem.t) -> p.code="Code") ps.items -> ()
    | _ -> failwith "Recovery accepted missing pinned implementation");
  let system=Kom.System.create ~id:"recover" ~workers:1 ~storage def |> get in
  if seed then (
    let flow=if child_mode then Kom.Flow.inline (Kom.Flow.step ~id:"parent-step" ~cell:"parent" ~operation:"Run" ()) else Kom.Flow.named "root" in
    let r=match Kom.System.send system ~flow (amount 1) with T.SendResponse.Admitted r -> r | _ -> failwith "Admission failed" in
    if history_mode then (
      ignore (Kom.System.await system r);
      ignore (get (Kom.System.update system (flow_definition 2))));
    let text=match T.Receipt.to_drut r with Ok text -> text | Error _ -> failwith "Receipt codec" in
    (* The handler waits for this handshake before signaling the crash point. *)
    print_endline text;flush stdout;
    Mutex.lock publication_mutex;published:=true;Condition.broadcast publication_changed;Mutex.unlock publication_mutex;
    if history_mode then blocked () else ignore (Kom.System.await system r))
  else (
    if history_mode then (
      let changed=Kom.Flow.define ~id:"leaf" ~version:1 (step ~id:"only-a" "a") in
      let changed_def=Kom.System.define ~cells:[Kom.Cell.spec ~id:"a" c2;Kom.Cell.spec ~id:"b" c2] ~flows:[changed] () in
      match Kom.System.update system changed_def with
      | Error ps when List.exists (fun (p : T.Problem.t) -> p.code="Flow") ps.items -> ()
      | _ -> failwith "Recovery lost immutable Flow version history");
    let text=read_line () in
    let r=match T.Receipt.from_drut text with Ok r -> r | Error _ -> failwith "Receipt codec" in
    let result=match Kom.System.await system r with T.AwaitResponse.Finished c -> completed c | UnknownReceipt -> failwith "Missing recovery receipt" in
    Printf.printf "RESULT %d\n%!" (List.hd result |> decode))
