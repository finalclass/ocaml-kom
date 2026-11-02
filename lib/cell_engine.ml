open Native_contract

let in_handler = Eio.Fiber.create_key ()

let callback f = Eio.Fiber.with_binding in_handler true f

let is_callback () = Eio.Fiber.get in_handler = Some true

let decode codec text =
  match callback (fun () -> codec.of_string text) with
  | Ok state -> state
  | Result.Error message -> fail "State" message

let initialize address (Cell (_, revision, spec)) =
  let state = callback spec.state.init in
  let data = callback (fun () -> spec.state.to_string state) in
  ignore (decode spec.state data) ;
  {address; kind= spec.id; revision; version= spec.state.version; data}

let validate_stored (Cell (_, revision, spec)) (stored : stored_cell) =
  if
    stored.kind <> spec.id
    || stored.revision <> revision
    || stored.version <> spec.state.version
  then
    fail
      "State"
      ("Unsupported cell revision or state version: " ^ stored.address) ;
  ignore (decode spec.state stored.data)

let single = function
  | Message message -> message
  | _ -> fail "Shape" "Operation requires one message"

let flat = function
  | Group values -> List.map single values
  | _ -> fail "Shape" "Operation requires a flat group"

let handle db (Cell (_, revision, spec)) (stored : stored_cell) name value =
  if
    stored.kind <> spec.id
    || stored.revision <> revision
    || stored.version <> spec.state.version
  then fail "State" "Cell implementation mismatch" ;
  let state = decode spec.state stored.data in
  let operation =
    match
      List.find_opt
        (fun operation -> operation_name operation = name)
        spec.operations
    with
    | Some operation -> operation
    | None -> fail "Operation" ("Unknown operation: " ^ name)
  in
  let next, result =
    match operation with
    | Typed op -> callback (fun () -> op.impl db state value)
    | Raw (Transformer op) ->
        let message = single value in
        Schema.validate op.input message.body ;
        let next, result = callback (fun () -> op.impl db state message.body) in
        Schema.validate op.output result ;
        Schema.preserve op.output message.body result ;
        (next, Message {message with body= result})
    | Raw (Expander op) ->
        let message = single value in
        Schema.validate op.input message.body ;
        let next, messages =
          callback (fun () -> op.impl db state message.body)
        in
        List.iter (Schema.validate op.output) messages ;
        ( next
        , Group
            (List.map
               (fun body -> Message {id= Typed_api.Msg.fresh_id (); body})
               messages ) )
    | Raw (Joiner op) ->
        let messages = flat value in
        List.iter
          (fun (message : message) -> Schema.validate op.input message.body)
          messages ;
        let next, result =
          callback (fun () ->
              op.impl db state (List.map (fun (m : message) -> m.body) messages) )
        in
        Schema.validate op.output result ;
        (next, Message {id= Typed_api.Msg.fresh_id (); body= result})
    | Raw (Router op) ->
        let message = single value in
        Schema.validate op.input message.body ;
        let next, (port, result) =
          callback (fun () -> op.impl db state message.body)
        in
        let output =
          match List.assoc_opt port op.output with
          | Some output -> output
          | None -> fail "Router" ("Undeclared port: " ^ port)
        in
        Schema.validate output result ;
        Schema.preserve output message.body result ;
        (next, Port (port, {message with body= result}))
  in
  let data = callback (fun () -> spec.state.to_string next) in
  ignore (decode spec.state data) ;
  ({stored with data}, result)
