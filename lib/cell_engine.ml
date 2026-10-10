open Native_contract
let in_handler = Domain.DLS.new_key (fun () -> false)
let callback f =
  let previous = Domain.DLS.get in_handler in
  Domain.DLS.set in_handler true;
  Fun.protect f ~finally:(fun () -> Domain.DLS.set in_handler previous)
let decode codec text =
  match callback (fun () -> codec.of_string text) with
  | Ok state -> state | Result.Error message -> fail "State" message
let initialize address (Cell (revision, spec)) =
  let state = callback spec.state.init in
  let data = callback (fun () -> spec.state.to_string state) in
  ignore (decode spec.state data);
  {address; kind = spec.id; revision; version = spec.state.version; data}
let validate_stored (Cell (revision, spec)) (stored : stored_cell) =
  if stored.kind <> spec.id || stored.revision <> revision || stored.version <> spec.state.version
  then fail "State" ("Unsupported cell revision or state version: " ^ stored.address);
  ignore (decode spec.state stored.data)
let single = function
  | Message message -> message | _ -> fail "Shape" "Operation requires one message"
let flat = function
  | Group values -> List.map single values | _ -> fail "Shape" "Operation requires a flat group"
let handle (Cell (revision, spec)) (stored : stored_cell) name value =
  if stored.kind <> spec.id || stored.revision <> revision || stored.version <> spec.state.version
  then fail "State" "Cell implementation mismatch";
  let state = decode spec.state stored.data in
  let operation =
    match List.find_opt (fun operation -> operation_name operation = name) spec.operations with
    | Some operation -> operation | None -> fail "Operation" ("Unknown operation: " ^ name)
  in
  let next, result =
    match operation with
    | Transformer op ->
        let message = single value in
        Schema.validate op.input message;
        let next, result = callback (fun () -> op.impl state message) in
        Schema.validate op.output result; Schema.preserve op.output message result;
        next, Message result
    | Expander op ->
        let message = single value in
        Schema.validate op.input message;
        let next, messages = callback (fun () -> op.impl state message) in
        List.iter (Schema.validate op.output) messages;
        next, Group (List.map (fun message -> Message message) messages)
    | Joiner op ->
        let messages = flat value in
        List.iter (Schema.validate op.input) messages;
        let next, result = callback (fun () -> op.impl state messages) in
        Schema.validate op.output result;
        next, Message result
    | Router op ->
        let message = single value in
        Schema.validate op.input message;
        let next, (port, result) = callback (fun () -> op.impl state message) in
        let output =
          match List.assoc_opt port op.output with
          | Some output -> output | None -> fail "Router" ("Undeclared port: " ^ port)
        in
        Schema.validate output result; Schema.preserve output message result;
        next, Port (port, result)
  in
  let data = callback (fun () -> spec.state.to_string next) in
  ignore (decode spec.state data);
  {stored with data}, result
