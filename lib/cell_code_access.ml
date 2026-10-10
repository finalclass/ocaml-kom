open Native_contract
let id (Cell (_, spec)) = spec.id
let find cells kind =
  match List.find_opt (fun cell -> id cell = kind) cells with
  | Some cell -> cell | None -> fail "CellKind" ("Unknown cell kind: " ^ kind)
let metadata = function
  | Transformer spec -> spec.op, "transformer", spec.input, ["output", spec.output]
  | Expander spec -> spec.op, "expander", spec.input, ["output", spec.output]
  | Joiner spec -> spec.op, "joiner", spec.input, ["output", spec.output]
  | Router spec -> spec.op, "router", spec.input, spec.output
let describe (Cell (revision, spec)) =
  `Assoc [
    "id", `String spec.id; "revision", `Int revision;
    "state_version", `Int spec.state.version;
    "operations", `List (List.map (fun operation ->
      let name, shape, input, outputs = metadata operation in
      `Assoc [
        "op", `String name; "shape", `String shape;
        "input", Schema.fields_json input;
        "outputs", `List (List.map (fun (port, fields) ->
          `Assoc ["port", `String port; "output", Schema.fields_json fields]) outputs);
      ]) spec.operations);
  ]
let validate (Cell (revision, spec)) =
  if spec.id = "" || revision < 1 || spec.state.version < 1
  then fail "CellKind" "Invalid cell identity or version";
  let names = List.map operation_name spec.operations in
  if List.exists ((=) "") names ||
    List.length names <> List.length (List.sort_uniq String.compare names)
  then fail "Operation" "Empty or duplicate operation";
  List.iter (fun operation ->
    let _, _, input, outputs = metadata operation in
    Schema.check_definition input;
    List.iter (fun (_, output) -> Schema.check_definition output) outputs;
    let ports = List.map fst outputs in
    if List.exists ((=) "") ports || outputs = [] ||
      List.length ports <> List.length (List.sort_uniq String.compare ports)
    then fail "Router" "Empty or duplicate output port") spec.operations
