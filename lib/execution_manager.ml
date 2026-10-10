open Native_contract
type t = {
  definition : definition; store : Execution_access.t; pool : Eio.Executor_pool.t;
  sw : Eio.Switch.t; jobs : (unit -> unit) Eio.Stream.t; stop : unit Eio.Promise.u; stopped : unit Eio.Promise.or_exn;
  close_mutex : Eio.Mutex.t;
}
let serial = Atomic.make 0
let fresh () = Printf.sprintf "req-%d-%.6f-%d" (Unix.getpid ()) (Unix.gettimeofday ()) (Atomic.fetch_and_add serial 1)
let path_text path = Yojson.Safe.to_string (`List (List.map (fun index -> `Int index) path))
let operate t id path step value =
  let key = path_text path in
  match Execution_access.cached t.store id key with
  | Some value -> value
  | None ->
      let address = Flow_access.render step.target value in
      match Execution_access.reserve t.store id key address with
      | `Cached value -> value
      | `Reserved stored ->
          Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Execution_access.release t.store address)) (fun () ->
            try
              let stored = match stored with Some stored -> stored
                | None -> fail "NotFound" ("Cell does not exist: " ^ address) in
              if stored.kind <> step.kind then fail "CellKind" "Target has a different cell kind";
              let cell = Cell_code_access.find t.definition.cells step.kind in
              let next, result =
                Eio.Executor_pool.submit_exn t.pool ~weight:0.0 (fun () -> Cell_engine.handle cell stored step.op value) in
              Execution_access.commit t.store id key next result;
              result
            with exn -> raise (Error (error_of_exn ~path:(address ^ "/" ^ step.op ^ key) exn)))
let reproduce t id path kind target value =
  let key = path_text path in
  match Execution_access.cached t.store id key with
  | Some value -> value
  | None ->
      let address = Flow_access.render target value in
      match Execution_access.reserve t.store id key address with
      | `Cached value -> value
      | `Reserved stored ->
          Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Execution_access.release t.store address)) (fun () ->
            try
              if stored <> None then fail "CellExists" ("Cell already exists: " ^ address);
              let cell = Cell_code_access.find t.definition.cells kind in
              let state = Eio.Executor_pool.submit_exn t.pool ~weight:0.0 (fun () -> Cell_engine.initialize address cell) in
              Execution_access.commit t.store id key state value;
              value
            with exn -> raise (Error (error_of_exn ~path:address exn)))
let run t id =
  let failure = ref None in
  Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () ->
    Execution_access.completed t.store id !failure)) (fun () ->
    let execution = Execution_access.locked t.store (fun () -> Execution_access.find_execution t.store id) in
    let outcome =
      try
        let flow = Flow_access.resolve t.definition execution.flow_id in
        let result = Flow_engine.evaluate
          ~step:(operate t id) ~reproduce:(reproduce t id) flow.ast execution.input |> Cell_engine.single in
        Schema.validate flow.spec.output result; Ok result
      with exn -> Result.Error (error_of_exn exn) in
    try Execution_access.finish t.store id outcome
    with exn -> failure := Some (error_of_exn exn))
let launch t id =
  try Eio.Switch.check t.sw; Eio.Stream.add t.jobs (fun () -> run t id)
  with exn ->
    Eio.Cancel.protect (fun () -> Execution_access.completed t.store id
      (match exn with Eio.Cancel.Cancelled _ -> None | exn -> Some (error_of_exn exn)));
    raise exn
let call ?request_id ?(internal = false) t ~flow input =
  if Cell_engine.is_callback () then fail "Reentrant" "System.call is not allowed inside a cell callback";
  if not internal && t.definition.init_flow = Some flow then fail "Flow" "init_flow is internal";
  let definition = Flow_access.resolve t.definition flow in
  Schema.validate definition.spec.input input;
  let id = Option.value ~default:(fresh ()) request_id in
  if id = "" then fail "Identity" "Empty request ID";
  Eio.Cancel.protect (fun () ->
    if Execution_access.start t.store ~internal id flow input then launch t id);
  match Execution_access.await t.store id with
  | Ok value -> value | Result.Error error -> raise (Error error)
let close t =
  if Cell_engine.is_callback () then fail "Reentrant" "System.close is not allowed inside a cell callback";
  Eio.Cancel.protect (fun () -> Eio.Mutex.use_ro t.close_mutex (fun () ->
    Fun.protect (fun () -> ignore (Execution_access.close t.store))
      ~finally:(fun () ->
        if not (Eio.Promise.is_resolved t.stopped) then Eio.Promise.resolve t.stop ();
        Eio.Promise.await_exn t.stopped)))
let create ~sw ~domain_mgr ~workers ~storage ~id definition =
  Eio.Switch.check sw;
  if id = "" then fail "Identity" "Empty System ID";
  if workers < 1 then fail "Workers" "workers must be positive";
  let store = Revision_manager.prepare definition storage id in
  let jobs = Eio.Stream.create max_int in
  let ready, ready_u = Eio.Promise.create () in
  let stop, stop_u = Eio.Promise.create () in
  let stopped, stopped_u = Eio.Promise.create () in
  (try Eio.Switch.check sw; Eio.Fiber.fork_daemon ~sw (fun () ->
    let outcome =
      try
        Fun.protect (fun () -> Eio.Switch.run (fun sw ->
          let pool = Eio.Executor_pool.create ~sw ~domain_count:workers domain_mgr in
          Eio.Fiber.fork_daemon ~sw (fun () ->
            while true do
              let job = Eio.Stream.take jobs in
              Eio.Switch.check sw;
              Eio.Fiber.fork ~sw job
            done);
          Eio.Promise.resolve_ok ready_u (pool, sw);
          Eio.Promise.await stop))
          ~finally:(fun () -> Eio.Cancel.protect (fun () ->
            Execution_access.abandon store; ignore (Execution_access.close store)));
        Ok ()
      with exn -> Result.Error exn in
    if not (Eio.Promise.is_resolved ready) then Eio.Promise.resolve ready_u
      (match outcome with Result.Error exn -> Result.Error exn | Ok () -> assert false);
    Eio.Promise.resolve stopped_u (match outcome with
      | Result.Error (Eio.Cancel.Cancelled _) -> Ok () | outcome -> outcome);
    `Stop_daemon)
   with exn -> Eio.Cancel.protect (fun () -> ignore (Execution_access.close store)); raise exn);
  let pool, runtime_sw = Eio.Cancel.protect (fun () -> Eio.Promise.await_exn ready) in
  let t = {definition; store; pool; sw = runtime_sw; jobs; stop = stop_u; stopped;
    close_mutex = Eio.Mutex.create ()} in
  try
    Eio.Fiber.check ();
    if not (Execution_access.initialized store) then (
      Option.iter (fun flow -> ignore (call ~request_id:"~kom:init" ~internal:true t ~flow (`Assoc []))) definition.init_flow;
      Execution_access.mark_initialized store);
    List.iter (fun execution ->
      if execution.outcome = None && Execution_access.resume store execution.request_id
      then launch t execution.request_id) (Execution_access.snapshot store).executions;
    t
  with exn ->
    (try Eio.Switch.fail runtime_sw exn with Invalid_argument _ -> ());
    Eio.Cancel.protect (fun () ->
      try Eio.Promise.await_exn stopped with _ -> ());
    raise exn
