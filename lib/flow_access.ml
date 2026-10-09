open Kom_contracts.Kom_types
type t = { history:(string,NamedFlow.t) Hashtbl.t; mutable catalogs:(string * NamedFlow.t list) list;mutex:Mutex.t }
let create () = {history=Hashtbl.create 32;catalogs=[];mutex=Mutex.create ()}
let locked t f = Mutex.lock t.mutex;Fun.protect f ~finally:(fun () -> Mutex.unlock t.mutex)
let stage t flows = locked t (fun () ->
  let names=List.map (fun (f : NamedFlow.t) -> f.id) flows in
  if List.length names <> List.length (List.sort_uniq String.compare names) then Message_codec.fail "Flow" "Duplicate Flow name";
  List.iter (fun (f : NamedFlow.t) ->
    let key=Yojson.Safe.to_string (`List [`String f.id;`Int f.version]) in
    match Hashtbl.find_opt t.history key with
    | Some old when old<>f -> Message_codec.fail "Flow" "Flow version is immutable"
    | _ -> ()) flows;
  List.iter (fun (f : NamedFlow.t) ->
    let key=Yojson.Safe.to_string (`List [`String f.id;`Int f.version]) in
    Hashtbl.replace t.history key f) flows;
  let id=Digest.to_hex (Digest.string (String.concat "" (List.map (fun f -> Message_codec.unwrap (NamedFlow.to_drut f)) flows))) in
  t.catalogs <- (id,flows) :: List.remove_assoc id t.catalogs;
  CatalogRef.make ~id ())
let resolve t catalog id = locked t (fun () -> match List.assoc_opt catalog.CatalogRef.id t.catalogs with
  | None -> Message_codec.fail "Flow" "Unknown catalog"
  | Some fs -> (match List.find_opt (fun (f : NamedFlow.t) -> f.id=id) fs with
    | Some f -> f | None -> Message_codec.fail "Flow" ("Unknown Flow: " ^ id)))
let discard t catalog = locked t (fun () -> t.catalogs <- List.remove_assoc catalog.CatalogRef.id t.catalogs)
let history t = locked t (fun () -> Hashtbl.fold (fun _ f fs -> f::fs) t.history []
  |> List.sort (fun (a : NamedFlow.t) b -> compare (a.id,a.version) (b.id,b.version)))
let remember t flows = locked t (fun () ->
  List.iter (fun (f : NamedFlow.t) ->
    let key=Yojson.Safe.to_string (`List [`String f.id;`Int f.version]) in
    match Hashtbl.find_opt t.history key with
    | Some old when old<>f -> Message_codec.fail "Flow" "Flow version is immutable"
    | _ -> Hashtbl.replace t.history key f) flows)
