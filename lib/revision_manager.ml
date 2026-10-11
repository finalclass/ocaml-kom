open Native_contract

let unique name ids =
  if List.length ids <> List.length (List.sort_uniq String.compare ids)
  then fail "Definition" ("Duplicate " ^ name)

let define ~cell_kinds ?init_flow ~flows () =
  List.iter Cell_code_access.validate cell_kinds ;
  unique "cell kind" (List.map Cell_code_access.id cell_kinds) ;
  unique "Flow" (List.map (fun flow -> flow.spec.id) flows) ;
  let bindings =
    List.concat_map (fun flow -> Flow_access.creations flow.ast) flows
    |> List.sort (fun (left, _) (right, _) ->
        String.compare left.text right.text )
  in
  let bindings =
    List.fold_left
      (fun bindings (target, kind) ->
        ignore (Cell_code_access.find cell_kinds kind) ;
        match
          List.find_opt
            (fun (old, _) ->
              Flow_access.pattern old = Flow_access.pattern target )
            bindings
        with
        | Some (_, old_kind) when old_kind <> kind ->
            fail "Address" "Ambiguous address pattern"
        | Some _ -> bindings
        | None -> (target, kind) :: bindings )
      []
      bindings
  in
  let flows = List.map (Flow_engine.compile cell_kinds bindings) flows in
  Option.iter
    (fun id ->
      let flow =
        match List.find_opt (fun flow -> flow.spec.id = id) flows with
        | Some flow -> flow
        | None -> fail "Flow" "Unknown init_flow"
      in
      Schema.validate flow.spec.input (`Assoc []) )
    init_flow ;
  let cells =
    List.sort
      (fun a b -> String.compare (Cell_code_access.id a) (Cell_code_access.id b))
      cell_kinds
  and flows = List.sort (fun a b -> String.compare a.spec.id b.spec.id) flows in
  let catalog =
    `Assoc
      [ ("format", `Int 1)
      ; ("cell_kinds", `List (List.map Cell_code_access.describe cells))
      ; ("flows", `List (List.map Flow_access.describe flows))
      ; ( "init_flow"
        , match init_flow with
          | None -> `Null
          | Some id -> `String id )
      ; ( "addresses"
        , `List
            (List.map
               (fun (target, kind) ->
                 `Assoc
                   [ ("pattern", `String target.text)
                   ; ("cell_kind", `String kind) ] )
               (List.rev bindings) ) ) ]
  in
  {cells; flows; init_flow; catalog}

let prepare (definition : definition) storage id =
  let store = Execution_access.create storage id definition.catalog in
  try
    let snapshot = Execution_access.snapshot store in
    List.iter
      (fun (stored : stored_cell) ->
        Cell_engine.validate_stored
          (Cell_code_access.find definition.cells stored.kind)
          stored )
      snapshot.cells ;
    List.iter
      (fun execution ->
        if execution.outcome = None
        then
          let flow = Flow_access.resolve definition execution.flow_id in
          Schema.validate flow.spec.input execution.input )
      snapshot.executions ;
    let writes =
      List.concat_map
        (fun (stored : stored_cell) ->
          let (Cell (views, _, _)) =
            Cell_code_access.find definition.cells stored.kind
          in
          Cell_engine.callback (fun () ->
              Db.rebuild store.backend ~owner:stored.address views ) )
        snapshot.cells
    in
    Execution_access.locked store (fun () ->
        Execution_access.save
          ~writes
          store
          {snapshot with catalog= definition.catalog} ) ;
    List.iter
      (fun (stored : stored_cell) ->
        let (Cell (views, _, _)) =
          Cell_code_access.find definition.cells stored.kind
        in
        Db.prune store.backend ~owner:stored.address views )
      snapshot.cells ;
    store
  with
  | exn ->
      Eio.Cancel.protect (fun () -> ignore (Execution_access.close store)) ;
      raise exn

let replacement (definition : definition) store =
  let snapshot = Execution_access.snapshot store in
  if List.exists (fun execution -> execution.outcome = None) snapshot.executions
  then fail "Pending" "Unfinished requests prevent replacing the catalog" ;
  let cells =
    List.map
      (fun (stored : stored_cell) ->
        let (Cell (_, revision, _) as cell) =
          Cell_code_access.find definition.cells stored.kind
        in
        let stored = {stored with revision} in
        Cell_engine.validate_stored cell stored ;
        stored )
      snapshot.cells
  in
  let writes =
    List.concat_map
      (fun (stored : stored_cell) ->
        let (Cell (views, _, _)) =
          Cell_code_access.find definition.cells stored.kind
        in
        Cell_engine.callback (fun () ->
            Db.rebuild
              store.Execution_access.backend
              ~owner:stored.address
              views ) )
      cells
  in
  ({snapshot with catalog= definition.catalog; cells}, writes)
