open Yojson.Safe.Util
open Native_contract

type t =
  { backend: backend
  ; mutex: Eio.Mutex.t
  ; changed: Eio.Condition.t
  ; mutable snapshot: snapshot
  ; mutable closing: bool
  ; mutable closed: bool
  ; busy: (string, string) Hashtbl.t
  ; inflight: (string, unit) Hashtbl.t
  ; epochs: (string, int) Hashtbl.t
  ; failures: (string, error) Hashtbl.t }

let locked t f = Eio.Mutex.use_ro t.mutex f

let error_json error =
  `Assoc
    [ ("code", `String error.code)
    ; ("message", `String error.message)
    ; ( "path"
      , match error.path with
        | None -> `Null
        | Some path -> `String path ) ]

let error_of_json json =
  Schema.validate [("path", Schema.Any)] json ;
  { code= json |> member "code" |> to_string
  ; message= json |> member "message" |> to_string
  ; path=
      ( match member "path" json with
      | `Null -> None
      | `String path -> Some path
      | _ -> fail "Contract" "Invalid error path" ) }

let rec value_json = function
  | Message message -> `List [`String "message"; message]
  | Group values -> `List [`String "group"; `List (List.map value_json values)]
  | Port (port, message) -> `List [`String "port"; `String port; message]

let rec value_of_json = function
  | `List [`String "message"; message] ->
      ignore (to_assoc message) ;
      Message message
  | `List [`String "group"; `List values] ->
      Group (List.map value_of_json values)
  | `List [`String "port"; `String port; message] ->
      ignore (to_assoc message) ;
      Port (port, message)
  | _ -> fail "Contract" "Invalid checkpoint value"

let outcome_json = function
  | None -> `Null
  | Some (Ok value) -> `Assoc [("ok", value)]
  | Some (Result.Error error) -> `Assoc [("error", error_json error)]

let outcome_of_json = function
  | `Null -> None
  | `Assoc [("ok", value)] -> Some (Ok value)
  | `Assoc [("error", error)] -> Some (Result.Error (error_of_json error))
  | _ -> fail "Contract" "Invalid stored outcome"

let cell_json (cell : stored_cell) =
  `Assoc
    [ ("address", `String cell.address)
    ; ("kind", `String cell.kind)
    ; ("revision", `Int cell.revision)
    ; ("version", `Int cell.version)
    ; ("data", `String cell.data) ]

let cell_of_json json =
  { address= json |> member "address" |> to_string
  ; kind= json |> member "kind" |> to_string
  ; revision= json |> member "revision" |> to_int
  ; version= json |> member "version" |> to_int
  ; data= json |> member "data" |> to_string }

let execution_json execution =
  `Assoc
    [ ("id", `String execution.request_id)
    ; ("flow", `String execution.flow_id)
    ; ("input", execution.input)
    ; ("outcome", outcome_json execution.outcome)
    ; ( "results"
      , `List
          (List.map
             (fun (path, value) -> `List [`String path; value_json value])
             execution.results ) ) ]

let execution_of_json json =
  Schema.validate [("input", Schema.Object []); ("outcome", Schema.Any)] json ;
  { request_id= json |> member "id" |> to_string
  ; flow_id= json |> member "flow" |> to_string
  ; input= member "input" json
  ; outcome= outcome_of_json (member "outcome" json)
  ; results=
      List.map
        (function
          | `List [`String path; value] -> (path, value_of_json value)
          | _ -> fail "Contract" "Invalid checkpoint" )
        (json |> member "results" |> to_list) }

let metadata snapshot =
  Yojson.Safe.to_string
    (`Assoc
       [ ("format", `Int snapshot.format)
       ; ("catalog", snapshot.catalog)
       ; ("initialized", `Bool snapshot.initialized) ] )

let records (backend : backend) prefix decode =
  let rec read after acc =
    let rows =
      backend.Db.scan {prefix; first= None; last= None; after; limit= 128}
    in
    let acc =
      List.rev_append
        (List.map (fun (_, text) -> decode (Yojson.Safe.from_string text)) rows)
        acc
    in
    if List.length rows < 128
    then List.rev acc
    else read (Some (fst (List.hd (List.rev rows)))) acc
  in
  read None []

let save ?(writes = []) t snapshot =
  let changed prefix key json old rows =
    List.filter_map
      (fun row ->
        if List.mem row old
        then None
        else
          Some
            ( prefix ^ Db.component (key row)
            , Some (Yojson.Safe.to_string (json row)) ) )
      rows
  in
  let changes =
    (("system", Some (metadata snapshot)) :: writes)
    @ changed
        "cells/"
        (fun (cell : stored_cell) -> cell.address)
        cell_json
        t.snapshot.cells
        snapshot.cells
    @ changed
        "requests/"
        (fun execution -> execution.request_id)
        execution_json
        t.snapshot.executions
        snapshot.executions
  in
  ( try Eio.Cancel.protect (fun () -> t.backend.commit changes) with
  | exn -> fail "Store" (Printexc.to_string exn) ) ;
  t.snapshot <- snapshot ;
  Eio.Condition.broadcast t.changed

let without_views json =
  let cells =
    json
    |> member "cell_kinds"
    |> to_list
    |> List.map (fun cell ->
        `Assoc (List.remove_assoc "views" (to_assoc cell)) )
  in
  `Assoc
    ( ("cell_kinds", `List cells)
    :: List.remove_assoc "cell_kinds" (to_assoc json) )

let create storage id catalog =
  let backend =
    match storage with
    | Memory -> Db.memory_backend ()
    | Backend open_ -> open_ id
  in
  try
    let loaded = backend.get "system" in
    let snapshot =
      match loaded with
      | Some text ->
          let json = Yojson.Safe.from_string text in
          let format = json |> member "format" |> to_int in
          if format <> 3 then fail "Store" "Unsupported store format" ;
          { format
          ; catalog= member "catalog" json
          ; initialized= json |> member "initialized" |> to_bool
          ; cells= records backend "cells/" cell_of_json
          ; executions= records backend "requests/" execution_of_json }
      | None ->
          {format= 3; catalog; initialized= false; cells= []; executions= []}
    in
    let unique xs =
      List.length xs = List.length (List.sort_uniq String.compare xs)
    in
    if
      (not
         (unique
            (List.map (fun (cell : stored_cell) -> cell.address) snapshot.cells) ) )
      || (not
            (unique
               (List.map
                  (fun execution -> execution.request_id)
                  snapshot.executions ) ) )
      || List.exists
           (fun execution -> not (unique (List.map fst execution.results)))
           snapshot.executions
    then fail "Store" "Duplicate stored identity" ;
    if
      not
        (Yojson.Safe.equal
           (without_views snapshot.catalog)
           (without_views catalog) )
    then fail "Catalog" "Stored catalog differs from supplied definition" ;
    let t =
      { backend
      ; mutex= Eio.Mutex.create ()
      ; changed= Eio.Condition.create ()
      ; snapshot
      ; closing= false
      ; closed= false
      ; busy= Hashtbl.create 16
      ; epochs= Hashtbl.create 16
      ; inflight= Hashtbl.create 16
      ; failures= Hashtbl.create 4 }
    in
    if loaded = None then save t snapshot ;
    t
  with
  | exn ->
      Eio.Cancel.protect backend.close ;
      raise exn

let epoch t address =
  Option.value ~default:0 (Hashtbl.find_opt t.epochs address)

let bump t address = Hashtbl.replace t.epochs address (epoch t address + 1)

let find_execution t id =
  match
    List.find_opt
      (fun execution -> execution.request_id = id)
      t.snapshot.executions
  with
  | Some execution -> execution
  | None -> fail "Request" "Unknown execution"

let replace_execution snapshot execution =
  { snapshot with
    executions=
      execution
      :: List.filter
           (fun old -> old.request_id <> execution.request_id)
           snapshot.executions }

let start t ~internal id flow input =
  locked t (fun () ->
      if t.closing || t.closed then fail "Closed" "System is closing" ;
      if (not internal) && String.starts_with ~prefix:"~kom:" id
      then fail "Identity" "Reserved request ID" ;
      let execution =
        match
          List.find_opt
            (fun execution -> execution.request_id = id)
            t.snapshot.executions
        with
        | Some execution ->
            if
              execution.flow_id <> flow
              || not (Yojson.Safe.equal execution.input input)
            then
              fail "Identity" "Request ID reused with different input or Flow" ;
            execution
        | None ->
            let execution =
              {request_id= id; flow_id= flow; input; results= []; outcome= None}
            in
            save t (replace_execution t.snapshot execution) ;
            execution
      in
      if execution.outcome <> None || Hashtbl.mem t.inflight id
      then false
      else (
        Hashtbl.remove t.failures id ;
        Hashtbl.add t.inflight id () ;
        true ) )

let resume t id =
  locked t (fun () ->
      let execution = find_execution t id in
      if execution.outcome <> None || Hashtbl.mem t.inflight id
      then false
      else (
        Hashtbl.add t.inflight id () ;
        true ) )

let cached t id path =
  locked t (fun () -> List.assoc_opt path (find_execution t id).results)

let reserve t id path address =
  locked t (fun () ->
      while Hashtbl.mem t.busy address do
        Eio.Condition.await t.changed t.mutex
      done ;
      match List.assoc_opt path (find_execution t id).results with
      | Some result -> `Cached result
      | None ->
          Hashtbl.add t.busy address id ;
          `Reserved
            ( List.find_opt
                (fun (cell : stored_cell) -> cell.address = address)
                t.snapshot.cells
            , epoch t address ) )

let release t address =
  locked t (fun () ->
      Hashtbl.remove t.busy address ;
      Eio.Condition.broadcast t.changed )

let commit ~writes t id path (cell : stored_cell) result =
  locked t (fun () ->
      if Hashtbl.find_opt t.busy cell.address <> Some id
      then fail "Reservation" "Lost cell reservation" ;
      let execution = find_execution t id in
      if List.mem_assoc path execution.results
      then fail "Checkpoint" "Step already committed" ;
      let execution =
        {execution with results= (path, result) :: execution.results}
      in
      let snapshot = replace_execution t.snapshot execution in
      let snapshot =
        { snapshot with
          cells=
            cell
            :: List.filter
                 (fun (old : stored_cell) -> old.address <> cell.address)
                 snapshot.cells }
      in
      let previous =
        List.find_opt
          (fun (old : stored_cell) -> old.address = cell.address)
          t.snapshot.cells
      in
      save ~writes t snapshot ;
      if previous <> Some cell || writes <> [] then bump t cell.address )

let finish t id outcome =
  locked t (fun () ->
      let execution = find_execution t id in
      save
        t
        (replace_execution t.snapshot {execution with outcome= Some outcome}) )

let completed t id failure =
  locked t (fun () ->
      Option.iter (fun error -> Hashtbl.replace t.failures id error) failure ;
      Hashtbl.remove t.inflight id ;
      Eio.Condition.broadcast t.changed )

let await t id =
  locked t (fun () ->
      let rec wait () =
        match
          ((find_execution t id).outcome, Hashtbl.find_opt t.failures id)
        with
        | Some outcome, _ -> outcome
        | None, Some error -> Result.Error error
        | None, None when t.closed -> fail "Closed" "System is closed"
        | None, None ->
            Eio.Condition.await t.changed t.mutex ;
            wait ()
      in
      wait () )

let snapshot t = locked t (fun () -> t.snapshot)

let initialized t = locked t (fun () -> t.snapshot.initialized)

let mark_initialized t =
  locked t (fun () -> save t {t.snapshot with initialized= true})

let abandon t =
  locked t (fun () ->
      Hashtbl.clear t.inflight ;
      Eio.Condition.broadcast t.changed )

let close t =
  let owns_close =
    locked t (fun () ->
        if t.closed
        then false
        else if t.closing
        then (
          while not t.closed do
            Eio.Condition.await t.changed t.mutex
          done ;
          false )
        else (
          t.closing <- true ;
          while Hashtbl.length t.inflight > 0 do
            Eio.Condition.await t.changed t.mutex
          done ;
          true ) )
  in
  if owns_close
  then
    Fun.protect
      (fun () -> t.backend.close ())
      ~finally:(fun () ->
        locked t (fun () ->
            t.closed <- true ;
            Eio.Condition.broadcast t.changed ) ) ;
  owns_close

type transaction =
  { mutex: Eio.Mutex.t
  ; mutable cells: stored_cell list
  ; mutable results: (string * value) list
  ; mutable writes: string option Db.Strings.t
  ; originals: (string, int) Hashtbl.t }

let transaction () =
  { mutex= Eio.Mutex.create ()
  ; cells= []
  ; results= []
  ; writes= Db.Strings.empty
  ; originals= Hashtbl.create 8 }

let tx_locked tx f = Eio.Mutex.use_ro tx.mutex f

let tx_cached tx path = tx_locked tx (fun () -> List.assoc_opt path tx.results)

let tx_cell tx address stored epoch =
  tx_locked tx (fun () ->
      ( match Hashtbl.find_opt tx.originals address with
      | None -> Hashtbl.add tx.originals address epoch
      | Some original when original <> epoch ->
          fail "Conflict" "Cell changed during transaction"
      | Some _ -> () ) ;
      match
        List.find_opt
          (fun (cell : stored_cell) -> cell.address = address)
          tx.cells
      with
      | Some cell -> Some cell
      | None -> stored )

let tx_stage tx path (cell : stored_cell) result writes =
  tx_locked tx (fun () ->
      tx.cells <-
        cell
        :: List.filter
             (fun (old : stored_cell) -> old.address <> cell.address)
             tx.cells ;
      tx.results <- (path, result) :: tx.results ;
      tx.writes <-
        List.fold_left
          (fun map (key, value) -> Db.Strings.add key value map)
          tx.writes
          writes )

let database t tx ~owner ~views =
  let read key =
    locked t (fun () ->
        match tx with
        | None -> t.backend.get key
        | Some tx ->
            tx_locked tx (fun () ->
                match Db.Strings.find_opt key tx.writes with
                | Some value -> value
                | None -> t.backend.get key ) )
  in
  let scan range =
    locked t (fun () ->
        match tx with
        | None -> t.backend.scan range
        | Some tx ->
            tx_locked tx (fun () ->
                let overlay =
                  Db.create
                    ~owner
                    ~views
                    ~read:t.backend.get
                    ~scan:t.backend.scan
                in
                overlay.writes <- tx.writes ;
                Db.scan overlay range ) )
  in
  Db.create ~owner ~views ~read ~scan

let commit_transaction t id path tx result =
  locked t (fun () ->
      Hashtbl.iter
        (fun address original ->
          if original <> epoch t address || Hashtbl.mem t.busy address
          then fail "Conflict" ("Concurrent change to cell: " ^ address) )
        tx.originals ;
      let execution = find_execution t id in
      let execution =
        { execution with
          results= ((path, result) :: tx.results) @ execution.results }
      in
      let snapshot = replace_execution t.snapshot execution in
      let addresses =
        List.map (fun (cell : stored_cell) -> cell.address) tx.cells
      in
      let snapshot =
        { snapshot with
          cells=
            tx.cells
            @ List.filter
                (fun (cell : stored_cell) ->
                  not (List.mem cell.address addresses) )
                snapshot.cells }
      in
      let changed =
        List.filter
          (fun address ->
            List.find_opt
              (fun (cell : stored_cell) -> cell.address = address)
              t.snapshot.cells
            <> List.find_opt
                 (fun (cell : stored_cell) -> cell.address = address)
                 tx.cells
            || Db.Strings.exists
                 (fun key _ -> String.starts_with ~prefix:(Db.root address) key)
                 tx.writes )
          addresses
      in
      save ~writes:(Db.Strings.bindings tx.writes) t snapshot ;
      List.iter (bump t) changed )
