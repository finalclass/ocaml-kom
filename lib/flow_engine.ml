open Native_contract

type shape =
  | Scalar of Schema.fields
  | Batch of shape
  | Fixed of shape list
  | Routes of (string * Schema.fields) list

let scalar = function
  | Scalar fields -> fields
  | _ -> fail "Shape" "Expected one message"

let flat = function
  | Batch (Scalar fields) -> [fields]
  | Fixed effects -> List.map scalar effects
  | _ -> fail "Shape" "Expected a flat group; use !flatten for subgroups"

let rec leaves = function
  | Scalar fields -> [fields]
  | Batch shape -> leaves shape
  | Fixed effects -> List.concat_map leaves effects
  | Routes _ -> fail "Shape" "Route must be consumed by !branch"

let target_fields target shape =
  List.iter
    (function
      | Literal _ -> ()
      | Field path ->
          if Schema.project (scalar shape) path <> Schema.String
          then
            fail "Address" "Address expression requires a required String field" )
    target.parts

let kind_for bindings target =
  match
    List.find_opt
      (fun (known, _) -> Flow_access.pattern known = Flow_access.pattern target)
      bindings
  with
  | Some (_, kind) -> kind
  | None ->
      fail "Address" ("No reproduce declaration for address: " ^ target.text)

let rec combine left right =
  match (left, right) with
  | Scalar left, Scalar right -> Scalar (Schema.common [left; right])
  | Batch left, Batch right -> Batch (combine left right)
  | Fixed left, Fixed right when List.length left = List.length right ->
      Fixed (List.map2 combine left right)
  | _ -> fail "Shape" "Branch cases must return compatible shapes"

let compile cells bindings flow =
  let rec transactions inside = function
    | Transaction body ->
        if inside
        then fail "Transaction" "Nested transactions are not supported" ;
        transactions true body
    | Sequence nodes
     |Parallel nodes ->
        List.iter (transactions inside) nodes
    | Each body -> transactions inside body
    | Branch (source, cases) ->
        transactions inside source ;
        List.iter (fun (_, body) -> transactions inside body) cases
    | _ -> ()
  in
  transactions false flow.ast ;
  let rec node shape = function
    | Transaction body ->
        let body, shape = node shape body in
        (Transaction body, shape)
    | Reproduce (kind, target) as ast ->
        ignore (Cell_code_access.find cells kind) ;
        target_fields target shape ;
        (ast, shape)
    | Step step ->
        target_fields step.target shape ;
        let kind = kind_for bindings step.target in
        let (Cell (_, _, spec)) = Cell_code_access.find cells kind in
        let operation =
          match
            List.find_opt
              (fun operation -> operation_name operation = step.op)
              spec.operations
          with
          | Some operation -> operation
          | None ->
              fail "Operation" ("Unknown operation: " ^ kind ^ "." ^ step.op)
        in
        let output =
          match operation with
          | Transformer op ->
              let fields = scalar shape in
              Schema.require fields op.input ;
              Scalar (Schema.merge fields op.output)
          | Expander op ->
              Schema.require (scalar shape) op.input ;
              Batch (Scalar op.output)
          | Joiner op ->
              List.iter
                (fun fields -> Schema.require fields op.input)
                (flat shape) ;
              Scalar op.output
          | Router op ->
              let fields = scalar shape in
              Schema.require fields op.input ;
              Routes
                (List.map
                   (fun (port, output) -> (port, Schema.merge fields output))
                   op.output )
        in
        (Step {step with kind}, output)
    | Sequence nodes ->
        let nodes, shape =
          List.fold_left
            (fun (nodes, shape) ast ->
              let ast, shape = node shape ast in
              (ast :: nodes, shape) )
            ([], shape)
            nodes
        in
        (Sequence (List.rev nodes), shape)
    | Parallel nodes ->
        let compiled = List.map (node shape) nodes in
        (Parallel (List.map fst compiled), Fixed (List.map snd compiled))
    | Each body ->
        let fields = Schema.common (flat shape) in
        let body, output = node (Scalar fields) body in
        (Each body, Batch output)
    | Flatten ->
        ( match shape with
        | Batch _
         |Fixed _ ->
            ()
        | _ -> fail "Shape" "!flatten requires a group" ) ;
        (Flatten, Batch (Scalar (Schema.common (leaves shape))))
    | Branch (source, cases) ->
        let source, ports = node shape source in
        let ports =
          match ports with
          | Routes ports -> ports
          | _ -> fail "Router" "Branch source must be a Router"
        in
        let names = List.map fst cases |> List.sort String.compare in
        if
          names <> (List.map fst ports |> List.sort String.compare)
          || List.length names
             <> List.length (List.sort_uniq String.compare names)
        then fail "Router" "Branch must cover each Router port exactly once" ;
        let cases =
          List.map
            (fun (port, body) ->
              let body, output = node (Scalar (List.assoc port ports)) body in
              (port, body, output) )
            cases
        in
        let effects = List.map (fun (_, _, shape) -> shape) cases in
        let output =
          match effects with
          | first :: rest -> List.fold_left combine first rest
          | [] -> fail "Router" "Empty branch"
        in
        ( Branch (source, List.map (fun (port, body, _) -> (port, body)) cases)
        , output )
  in
  try
    let ast, output = node (Scalar flow.spec.input) flow.ast in
    Schema.require (scalar output) flow.spec.output ;
    {flow with ast}
  with
  | exn -> raise (Error (error_of_exn ~path:flow.spec.id exn))

let parallel_map f items =
  let failure = ref None in
  let results =
    Eio.Fiber.List.filter_map
      (fun (index, item) ->
        match !failure with
        | Some _ -> None
        | None -> (
          try Some (f index item) with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
              if !failure = None then failure := Some exn ;
              None ) )
      (List.mapi (fun index item -> (index, item)) items)
  in
  match !failure with
  | Some exn -> raise exn
  | None -> results

let rec flatten = function
  | Message _ as value -> [value]
  | Group values -> List.concat_map flatten values
  | Port _ -> fail "Shape" "Route must be consumed by !branch"

let evaluate ~transaction ~step ~reproduce ast input =
  let rec node path ast value =
    match ast with
    | Transaction body ->
        transaction path (fun () -> node (path @ [0]) body value)
    | Step operation -> step path operation value
    | Reproduce (kind, target) -> reproduce path kind target value
    | Sequence nodes ->
        List.fold_left
          (fun value (index, ast) -> node (path @ [index]) ast value)
          value
          (List.mapi (fun index ast -> (index, ast)) nodes)
    | Parallel nodes ->
        Group
          (parallel_map
             (fun index ast -> node (path @ [index]) ast value)
             nodes )
    | Each body ->
        let values =
          match value with
          | Group values -> values
          | _ -> fail "Shape" "parallel_each requires a group"
        in
        List.iter
          (function
            | Message _ -> ()
            | _ -> fail "Shape" "Each requires a flat group" )
          values ;
        Group
          (parallel_map
             (fun index value -> node (path @ [index]) body value)
             values )
    | Flatten -> (
      match value with
      | Group _ -> Group (flatten value)
      | _ -> fail "Shape" "!flatten requires a group" )
    | Branch (source, cases) ->
        let result = node (path @ [0]) source value in
        let port, message =
          match result with
          | Port (port, message) -> (port, message)
          | _ -> fail "Router" "Branch source did not produce a port"
        in
        let index, body =
          match
            List.find_opt
              (fun (_, (name, _)) -> name = port)
              (List.mapi (fun index case -> (index, case)) cases)
          with
          | Some (index, (_, body)) -> (index, body)
          | None -> fail "Router" "Unknown branch port"
        in
        node (path @ [index + 1]) body (Message message)
  in
  node [] ast (Message input)
