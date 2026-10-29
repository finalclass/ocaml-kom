open Native_contract

type t =
  { mutable definition: definition
  ; store: Execution_access.t
  ; pool: Eio.Executor_pool.t
  ; sw: Eio.Switch.t
  ; jobs: (unit -> unit) Eio.Stream.t
  ; stop: unit Eio.Promise.u
  ; stopped: unit Eio.Promise.or_exn
  ; close_mutex: Eio.Mutex.t
  ; admission: Eio.Mutex.t }

let serial = Atomic.make 0

let fresh () =
  Printf.sprintf
    "req-%d-%.6f-%d"
    (Unix.getpid ())
    (Unix.gettimeofday ())
    (Atomic.fetch_and_add serial 1)

let path_text path =
  Yojson.Safe.to_string (`List (List.map (fun index -> `Int index) path))

let context = Eio.Fiber.create_key ()

let cached t id path =
  match Eio.Fiber.get context with
  | None -> Execution_access.cached t.store id path
  | Some tx -> Execution_access.tx_cached tx path

let perform t id path address f =
  let tx = Eio.Fiber.get context in
  match cached t id path with
  | Some result -> result
  | None -> (
      (* Children of a transaction never consult durable child checkpoints. *)
      let reservation_path =
        match tx with
        | None -> path
        | Some _ -> "transaction:" ^ path
      in
      match Execution_access.reserve t.store id reservation_path address with
      | `Cached result -> result
      | `Reserved (stored, epoch) ->
          Fun.protect
            ~finally:(fun () ->
              Eio.Cancel.protect (fun () ->
                  Execution_access.release t.store address ) )
            (fun () ->
              let stored =
                match tx with
                | None -> stored
                | Some tx -> Execution_access.tx_cell tx address stored epoch
              in
              let next, result, writes = f tx stored in
              ( match tx with
              | None ->
                  Execution_access.commit ~writes t.store id path next result
              | Some tx -> Execution_access.tx_stage tx path next result writes
              ) ;
              result ) )

let operate t id path step value =
  let key = path_text path in
  let address = Flow_access.render step.target value in
  try
    perform t id key address (fun tx stored ->
        let stored =
          match stored with
          | Some stored -> stored
          | None -> fail "NotFound" ("Cell does not exist: " ^ address)
        in
        if stored.kind <> step.kind
        then fail "CellKind" "Target has a different cell kind" ;
        let (Cell (views, _, _) as cell) =
          Cell_code_access.find t.definition.cells step.kind
        in
        let db = Execution_access.database t.store tx ~owner:address ~views in
        Fun.protect
          ~finally:(fun () -> Db.invalidate db)
          (fun () ->
            let next, result =
              Eio.Executor_pool.submit_exn t.pool ~weight:0.0 (fun () ->
                  Db.with_context db (fun () ->
                      Cell_engine.handle db cell stored step.op value ) )
            in
            (next, result, Db.changes db) ) )
  with
  | exn -> raise (Error (error_of_exn ~path:(address ^ "/" ^ step.op ^ key) exn))

let reproduce t id path kind target value =
  let address = Flow_access.render target value in
  try
    perform t id (path_text path) address (fun _ stored ->
        if stored <> None
        then fail "CellExists" ("Cell already exists: " ^ address) ;
        let (Cell (views, _, _) as cell) =
          Cell_code_access.find t.definition.cells kind
        in
        let state =
          Eio.Executor_pool.submit_exn t.pool ~weight:0.0 (fun () ->
              Cell_engine.initialize address cell )
        in
        let writes =
          List.map
            (fun (Db.View view) ->
              (Db.metadata address view.spec.id, Some (Db.view_meta view)) )
            views
        in
        (state, value, writes) )
  with
  | exn -> raise (Error (error_of_exn ~path:address exn))

let transaction t id path body =
  if Eio.Fiber.get context <> None
  then fail "Transaction" "Nested transactions are not supported" ;
  let path = path_text path in
  match Execution_access.cached t.store id path with
  | Some result -> result
  | None ->
      let tx = Execution_access.transaction () in
      let result = Eio.Fiber.with_binding context tx body in
      Execution_access.commit_transaction t.store id path tx result ;
      result

let run t id =
  let failure = ref None in
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () ->
          Execution_access.completed t.store id !failure ) )
    (fun () ->
      let execution =
        Execution_access.locked t.store (fun () ->
            Execution_access.find_execution t.store id )
      in
      let outcome =
        try
          let flow = Flow_access.resolve t.definition execution.flow_id in
          let result =
            Flow_engine.evaluate
              ~transaction:(transaction t id)
              ~step:(operate t id)
              ~reproduce:(reproduce t id)
              flow.ast
              execution.input
            |> Cell_engine.single
          in
          Schema.validate flow.spec.output result ;
          Ok result
        with
        | exn -> Result.Error (error_of_exn exn)
      in
      try Execution_access.finish t.store id outcome with
      | exn -> failure := Some (error_of_exn exn) )

let launch t id =
  try
    Eio.Switch.check t.sw ;
    Eio.Stream.add t.jobs (fun () -> run t id)
  with
  | exn ->
      Eio.Cancel.protect (fun () ->
          Execution_access.completed
            t.store
            id
            ( match exn with
            | Eio.Cancel.Cancelled _ -> None
            | exn -> Some (error_of_exn exn) ) ) ;
      raise exn

let call ?request_id ?(internal = false) t ~flow input =
  if Cell_engine.is_callback ()
  then fail "Reentrant" "System.call is not allowed inside a cell callback" ;
  Execution_access.locked t.store (fun () ->
      if t.store.closing || t.store.closed
      then fail "Closed" "System is closing" ) ;
  let id = Option.value ~default:(fresh ()) request_id in
  if id = "" then fail "Identity" "Empty request ID" ;
  Eio.Mutex.use_ro t.admission (fun () ->
      if (not internal) && t.definition.init_flow = Some flow
      then fail "Flow" "init_flow is internal" ;
      let definition = Flow_access.resolve t.definition flow in
      Schema.validate definition.spec.input input ;
      Eio.Cancel.protect (fun () ->
          if Execution_access.start t.store ~internal id flow input
          then launch t id ) ) ;
  match Execution_access.await t.store id with
  | Ok value -> value
  | Result.Error error -> raise (Error error)

let close t =
  if Cell_engine.is_callback ()
  then fail "Reentrant" "System.close is not allowed inside a cell callback" ;
  Eio.Cancel.protect (fun () ->
      Eio.Mutex.use_ro t.admission (fun () ->
          Eio.Mutex.use_ro t.close_mutex (fun () ->
              Fun.protect
                (fun () -> ignore (Execution_access.close t.store))
                ~finally:(fun () ->
                  if not (Eio.Promise.is_resolved t.stopped)
                  then Eio.Promise.resolve t.stop () ;
                  Eio.Promise.await_exn t.stopped ) ) ) )

let create ~sw ~domain_mgr ~workers ~storage ~id definition =
  Eio.Switch.check sw ;
  if id = "" then fail "Identity" "Empty System ID" ;
  if workers < 1 then fail "Workers" "workers must be positive" ;
  let store = Revision_manager.prepare definition storage id in
  let jobs = Eio.Stream.create max_int in
  let ready, ready_u = Eio.Promise.create () in
  let stop, stop_u = Eio.Promise.create () in
  let stopped, stopped_u = Eio.Promise.create () in
  ( try
      Eio.Switch.check sw ;
      Eio.Fiber.fork_daemon ~sw (fun () ->
          let outcome =
            try
              Fun.protect
                (fun () ->
                  Eio.Switch.run (fun sw ->
                      let pool =
                        Eio.Executor_pool.create
                          ~sw
                          ~domain_count:workers
                          domain_mgr
                      in
                      Eio.Fiber.fork_daemon ~sw (fun () ->
                          let rec dispatch () =
                            let job = Eio.Stream.take jobs in
                            Eio.Switch.check sw ;
                            Eio.Fiber.fork ~sw job ;
                            dispatch ()
                          in
                          dispatch () ) ;
                      Eio.Promise.resolve_ok ready_u (pool, sw) ;
                      Eio.Promise.await stop ) )
                ~finally:(fun () ->
                  Eio.Cancel.protect (fun () ->
                      Execution_access.abandon store ;
                      ignore (Execution_access.close store) ) ) ;
              Ok ()
            with
            | exn -> Result.Error exn
          in
          if not (Eio.Promise.is_resolved ready)
          then
            Eio.Promise.resolve
              ready_u
              ( match outcome with
              | Result.Error exn -> Result.Error exn
              | Ok () -> assert false ) ;
          Eio.Promise.resolve
            stopped_u
            ( match outcome with
            | Result.Error (Eio.Cancel.Cancelled _) -> Ok ()
            | outcome -> outcome ) ;
          `Stop_daemon )
    with
  | exn ->
      Eio.Cancel.protect (fun () -> ignore (Execution_access.close store)) ;
      raise exn ) ;
  let pool, runtime_sw =
    Eio.Cancel.protect (fun () -> Eio.Promise.await_exn ready)
  in
  let t =
    { definition
    ; store
    ; pool
    ; sw= runtime_sw
    ; jobs
    ; stop= stop_u
    ; stopped
    ; close_mutex= Eio.Mutex.create ()
    ; admission= Eio.Mutex.create () }
  in
  try
    Eio.Fiber.check () ;
    if not (Execution_access.initialized store)
    then (
      Option.iter
        (fun flow ->
          ignore
            (call ~request_id:"~kom:init" ~internal:true t ~flow (`Assoc [])) )
        definition.init_flow ;
      Execution_access.mark_initialized store ) ;
    List.iter
      (fun execution ->
        if
          execution.outcome = None
          && Execution_access.resume store execution.request_id
        then launch t execution.request_id )
      (Execution_access.snapshot store).executions ;
    t
  with
  | exn ->
      ( try Eio.Switch.fail runtime_sw exn with
      | Invalid_argument _ -> () ) ;
      Eio.Cancel.protect (fun () ->
          try Eio.Promise.await_exn stopped with
          | _ -> () ) ;
      raise exn

let replace t definition =
  if Cell_engine.is_callback ()
  then fail "Reentrant" "System.replace is not allowed inside a cell callback" ;
  Eio.Mutex.use_ro t.admission (fun () ->
      Execution_access.locked t.store (fun () ->
          if t.store.closing || t.store.closed
          then fail "Closed" "System is closing" ;
          while Hashtbl.length t.store.inflight > 0 do
            Eio.Condition.await t.store.changed t.store.mutex
          done ) ;
      let snapshot, writes =
        Eio.Executor_pool.submit_exn t.pool ~weight:0.0 (fun () ->
            Revision_manager.replacement definition t.store )
      in
      Eio.Cancel.protect (fun () ->
          Execution_access.locked t.store (fun () ->
              Execution_access.save ~writes t.store snapshot ) ;
          t.definition <- definition ;
          List.iter
            (fun (stored : stored_cell) ->
              let (Cell (views, _, _)) =
                Cell_code_access.find definition.cells stored.kind
              in
              try Db.prune t.store.backend ~owner:stored.address views with
              | exn ->
                  prerr_endline ("Kom index cleanup: " ^ Printexc.to_string exn) )
            snapshot.cells ) )
