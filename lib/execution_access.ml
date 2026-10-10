open Yojson.Safe.Util
open Native_contract
type t = {
  backend : backend option; mutex : Mutex.t; changed : Condition.t;
  mutable snapshot : snapshot; mutable closing : bool; mutable closed : bool;
  busy : (string, string) Hashtbl.t; inflight : (string, unit) Hashtbl.t;
  failures : (string, error) Hashtbl.t;
}
let locked t f = Scheduler.locked t.mutex f
let error_json error = `Assoc [
  "code", `String error.code; "message", `String error.message;
  "path", (match error.path with None -> `Null | Some path -> `String path)]
let error_of_json json =
  Schema.validate ["path", Schema.Any] json;
  {
  code = (json |> member "code" |> to_string); message = (json |> member "message" |> to_string);
  path = (match member "path" json with `Null -> None | `String path -> Some path
    | _ -> fail "Contract" "Invalid error path");
}
let rec value_json = function
  | Message message -> `List [`String "message"; message]
  | Group values -> `List [`String "group"; `List (List.map value_json values)]
  | Port (port, message) -> `List [`String "port"; `String port; message]
let rec value_of_json = function
  | `List [`String "message"; message] -> ignore (to_assoc message); Message message
  | `List [`String "group"; `List values] -> Group (List.map value_of_json values)
  | `List [`String "port"; `String port; message] -> ignore (to_assoc message); Port (port, message)
  | _ -> fail "Contract" "Invalid checkpoint value"
let outcome_json = function
  | None -> `Null | Some (Ok value) -> `Assoc ["ok", value]
  | Some (Result.Error error) -> `Assoc ["error", error_json error]
let outcome_of_json = function
  | `Null -> None | `Assoc ["ok", value] -> Some (Ok value)
  | `Assoc ["error", error] -> Some (Result.Error (error_of_json error))
  | _ -> fail "Contract" "Invalid stored outcome"
let cell_json (cell : stored_cell) = `Assoc [
  "address", `String cell.address; "kind", `String cell.kind;
  "revision", `Int cell.revision; "version", `Int cell.version; "data", `String cell.data]
let cell_of_json json = {
  address = (json |> member "address" |> to_string); kind = (json |> member "kind" |> to_string);
  revision = (json |> member "revision" |> to_int); version = (json |> member "version" |> to_int);
  data = (json |> member "data" |> to_string);
}
let execution_json execution = `Assoc [
  "id", `String execution.request_id; "flow", `String execution.flow_id;
  "input", execution.input; "outcome", outcome_json execution.outcome;
  "results", `List (List.map (fun (path, value) -> `List [`String path; value_json value]) execution.results)]
let execution_of_json json =
  Schema.validate ["input", Schema.Object []; "outcome", Schema.Any] json;
  {
  request_id = (json |> member "id" |> to_string); flow_id = (json |> member "flow" |> to_string);
  input = member "input" json; outcome = outcome_of_json (member "outcome" json);
  results = List.map (function
    | `List [`String path; value] -> path, value_of_json value
    | _ -> fail "Contract" "Invalid checkpoint") (json |> member "results" |> to_list);
}
let serialize snapshot = Yojson.Safe.to_string (`Assoc [
  "format", `Int snapshot.format; "catalog", snapshot.catalog;
  "initialized", `Bool snapshot.initialized;
  "cells", `List (List.map cell_json snapshot.cells);
  "executions", `List (List.map execution_json snapshot.executions)])
let deserialize text =
  let json = Yojson.Safe.from_string text in
  Schema.validate ["catalog", Schema.Object []] json;
  let format = (json |> member "format" |> to_int) in
  if format <> 2 then fail "Store" "Unsupported store format";
  let cells = List.map cell_of_json (json |> member "cells" |> to_list)
  and executions = List.map execution_of_json (json |> member "executions" |> to_list) in
  let unique values =
    List.length values = List.length (List.sort_uniq String.compare values) in
  if not (unique (List.map (fun (cell : stored_cell) -> cell.address) cells)) ||
     not (unique (List.map (fun execution -> execution.request_id) executions)) ||
     List.exists (fun execution -> not (unique (List.map fst execution.results))) executions
  then fail "Store" "Duplicate stored identity";
  {format; catalog = member "catalog" json; initialized = (json |> member "initialized" |> to_bool); cells; executions}
let save t snapshot =
  (try Option.iter (fun backend -> backend.save (serialize snapshot)) t.backend
   with exn -> fail "Store" (Printexc.to_string exn));
  t.snapshot <- snapshot; Condition.broadcast t.changed
let create storage id catalog =
  let backend = match storage with
    | Memory -> None
    | Backend open_ -> Some (open_ id) in
  try
    let loaded = Option.bind backend (fun backend -> backend.load ()) in
    let snapshot = match loaded with
      | Some text -> deserialize text
      | None -> {format = 2; catalog; initialized = false; cells = []; executions = []} in
    if not (Yojson.Safe.equal snapshot.catalog catalog) then fail "Catalog" "Stored catalog differs from supplied definition";
    let t = {backend; mutex = Mutex.create (); changed = Condition.create (); snapshot;
      closing = false; closed = false; busy = Hashtbl.create 16;
      inflight = Hashtbl.create 16; failures = Hashtbl.create 4} in
    if loaded = None then save t snapshot;
    t
  with exn -> Option.iter (fun backend -> backend.close ()) backend; raise exn
let find_execution t id =
  match List.find_opt (fun execution -> execution.request_id = id) t.snapshot.executions with
  | Some execution -> execution | None -> fail "Request" "Unknown execution"
let replace_execution snapshot execution =
  {snapshot with executions = execution ::
    List.filter (fun old -> old.request_id <> execution.request_id) snapshot.executions}
let start t ~internal id flow input =
  locked t (fun () ->
    if t.closing || t.closed then fail "Closed" "System is closing";
    if not internal && String.starts_with ~prefix:"~kom:" id then fail "Identity" "Reserved request ID";
    let execution = match List.find_opt (fun execution -> execution.request_id = id) t.snapshot.executions with
      | Some execution ->
          if execution.flow_id <> flow || not (Yojson.Safe.equal execution.input input)
          then fail "Identity" "Request ID reused with different input or Flow";
          execution
      | None ->
          let execution = {request_id = id; flow_id = flow; input; results = []; outcome = None} in
          save t (replace_execution t.snapshot execution); execution in
    if execution.outcome <> None || Hashtbl.mem t.inflight id then false
    else (
      Hashtbl.remove t.failures id; Hashtbl.add t.inflight id (); true))
let resume t id = locked t (fun () ->
  let execution = find_execution t id in
  if execution.outcome <> None || Hashtbl.mem t.inflight id then false
  else (Hashtbl.add t.inflight id (); true))
let cached t id path = locked t (fun () -> List.assoc_opt path (find_execution t id).results)
let reserve t id path address =
  locked t (fun () ->
    while Hashtbl.mem t.busy address do Condition.wait t.changed t.mutex done;
    match List.assoc_opt path (find_execution t id).results with
    | Some result -> `Cached result
    | None ->
        Hashtbl.add t.busy address id;
        `Reserved (List.find_opt (fun (cell : stored_cell) -> cell.address = address) t.snapshot.cells))
let release t address = locked t (fun () ->
  Hashtbl.remove t.busy address; Condition.broadcast t.changed)
let commit t id path (cell : stored_cell) result =
  locked t (fun () ->
    if Hashtbl.find_opt t.busy cell.address <> Some id then fail "Reservation" "Lost cell reservation";
    let execution = find_execution t id in
    if List.mem_assoc path execution.results then fail "Checkpoint" "Step already committed";
    let execution = {execution with results = (path, result) :: execution.results} in
    let snapshot = replace_execution t.snapshot execution in
    let snapshot = {snapshot with cells = cell ::
      List.filter (fun (old : stored_cell) -> old.address <> cell.address) snapshot.cells} in
    save t snapshot)
let finish t id outcome =
  locked t (fun () ->
    let execution = find_execution t id in
    save t (replace_execution t.snapshot {execution with outcome = Some outcome}))
let completed t id failure =
  locked t (fun () ->
    Option.iter (fun error -> Hashtbl.replace t.failures id error) failure;
    Hashtbl.remove t.inflight id; Condition.broadcast t.changed)
let await t id =
  locked t (fun () ->
    let rec wait () =
      match (find_execution t id).outcome, Hashtbl.find_opt t.failures id with
      | Some outcome, _ -> outcome
      | None, Some error -> Result.Error error
      | None, None -> Condition.wait t.changed t.mutex; wait ()
    in wait ())
let snapshot t = locked t (fun () -> t.snapshot)
let initialized t = locked t (fun () -> t.snapshot.initialized)
let mark_initialized t = locked t (fun () -> save t {t.snapshot with initialized = true})
let close t =
  let owns_close = locked t (fun () ->
    if t.closed then false
    else if t.closing then (
      while not t.closed do Condition.wait t.changed t.mutex done; false)
    else (
      t.closing <- true;
      while Hashtbl.length t.inflight > 0 do Condition.wait t.changed t.mutex done;
      true)) in
  if owns_close then
    Fun.protect (fun () -> Option.iter (fun backend -> backend.close ()) t.backend)
      ~finally:(fun () -> locked t (fun () -> t.closed <- true; Condition.broadcast t.changed));
  owns_close
