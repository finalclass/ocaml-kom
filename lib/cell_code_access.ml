open Kom_contracts.Kom_types
open Native_contract
type t = { modules:(string,cell) Hashtbl.t; mutex:Mutex.t }
let create () = {modules=Hashtbl.create 16;mutex=Mutex.create ()}
let identity (r : ImplementationRef.t) = Yojson.Safe.to_string (`List [`String r.id;`String r.revision])
let reference (Cell c) = ImplementationRef.make ~id:c.id ~revision:c.revision ()
let describe (Cell c) = CellDefinition.make ~implementation:(ImplementationRef.make ~id:c.id ~revision:c.revision ()) ~state_version:c.state_version ~operations:c.operations ()
let register t cells =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) (fun () ->
    List.iter (fun c -> let k=identity (reference c) in
      match Hashtbl.find_opt t.modules k with
      | Some existing when describe existing <> describe c -> Message_codec.fail "Code" "Implementation revision changed its contract"
      | Some _ -> () | None -> Hashtbl.add t.modules k c) cells)
let resolve t r =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) (fun () ->
    match Hashtbl.find_opt t.modules (identity r) with
    | Some c -> c | None -> Message_codec.fail "Code" ("Missing pinned implementation: " ^ r.ImplementationRef.id ^ "@" ^ r.revision))
let prepare t definition = List.map (fun (s : CellSpec.t) ->
  CellBinding.make ~cell_id:s.id ~definition:(describe (resolve t s.implementation)) ()) definition.SystemDefinition.cells
let discard t = Mutex.lock t.mutex;Hashtbl.clear t.modules;Mutex.unlock t.mutex
