open Native_contract
type t = {definition : definition; store : Execution_access.t; scheduler : Scheduler.t; close_mutex : Mutex.t}
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
          Fun.protect ~finally:(fun () -> Execution_access.release t.store address) (fun () ->
            try
              let stored = match stored with Some stored -> stored
                | None -> fail "NotFound" ("Cell does not exist: " ^ address) in
              if stored.kind <> step.kind then fail "CellKind" "Target has a different cell kind";
              let cell = Cell_code_access.find t.definition.cells step.kind in
              let next, result =
                Scheduler.submit t.scheduler (fun () -> Cell_engine.handle cell stored step.op value)
                |> Scheduler.await in
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
          Fun.protect ~finally:(fun () -> Execution_access.release t.store address) (fun () ->
            try
              if stored <> None then fail "CellExists" ("Cell already exists: " ^ address);
              let cell = Cell_code_access.find t.definition.cells kind in
              let state = Scheduler.submit t.scheduler (fun () -> Cell_engine.initialize address cell) |> Scheduler.await in
              Execution_access.commit t.store id key state value;
              value
            with exn -> raise (Error (error_of_exn ~path:address exn)))
let run t id =
  let execution = Execution_access.locked t.store (fun () -> Execution_access.find_execution t.store id) in
  let outcome =
    try
      let flow = Flow_access.resolve t.definition execution.flow_id in
      let result = Flow_engine.evaluate ~capacity:t.scheduler.capacity
        ~step:(operate t id) ~reproduce:(reproduce t id) flow.ast execution.input |> Cell_engine.single in
      Schema.validate flow.spec.output result; Ok result
    with exn -> Result.Error (error_of_exn exn) in
  let failure =
    try Execution_access.finish t.store id outcome; None
    with exn -> Some (error_of_exn exn) in
  Execution_access.completed t.store id failure
let launch t id =
  try ignore (Thread.create (fun () -> run t id) ())
  with exn -> Execution_access.completed t.store id (Some (error_of_exn exn)); raise exn
let call ?request_id ?(internal = false) t ~flow input =
  if Domain.DLS.get Cell_engine.in_handler then fail "Reentrant" "System.call is not allowed inside a cell callback";
  if not internal && t.definition.init_flow = Some flow then fail "Flow" "init_flow is internal";
  let definition = Flow_access.resolve t.definition flow in
  Schema.validate definition.spec.input input;
  let id = Option.value ~default:(fresh ()) request_id in
  if id = "" then fail "Identity" "Empty request ID";
  if Execution_access.start t.store ~internal id flow input then launch t id;
  match Execution_access.await t.store id with
  | Ok value -> value | Result.Error error -> raise (Error error)
let create ~workers ~storage ~id definition =
  if id = "" then fail "Identity" "Empty System ID";
  let store = Revision_manager.prepare definition storage id in
  let scheduler =
    try Scheduler.create workers with exn -> ignore (Execution_access.close store); raise exn in
  let t = {definition; store; scheduler; close_mutex = Mutex.create ()} in
  try
    if not (Execution_access.initialized store) then (
      Option.iter (fun flow -> ignore (call ~request_id:"~kom:init" ~internal:true t ~flow (`Assoc []))) definition.init_flow;
      Execution_access.mark_initialized store);
    List.iter (fun execution ->
      if execution.outcome = None && Execution_access.resume store execution.request_id
      then launch t execution.request_id) (Execution_access.snapshot store).executions;
    t
  with exn -> ignore (Execution_access.close store); Scheduler.close scheduler; raise exn
let close t =
  if Domain.DLS.get Cell_engine.in_handler then fail "Reentrant" "System.close is not allowed inside a cell callback";
  Scheduler.locked t.close_mutex (fun () ->
    match Execution_access.close t.store with
    | true -> Scheduler.close t.scheduler
    | false -> ()
    | exception exn -> Scheduler.close t.scheduler; raise exn)
