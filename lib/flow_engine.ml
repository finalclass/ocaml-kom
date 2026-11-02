open Native_contract

type facts =
  { fields: Schema.fields
  ; inherited: string list option
  ; alternatives: facts list }

type shape =
  | Scalar of facts
  | Batch of shape
  | Fixed of shape list
  | Routes of (string * facts) list

let closed fields = {fields; inherited= None; alternatives= []}

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

let common = function
  | [value] -> value
  | values ->
      let inherited =
        List.fold_left
          (fun acc value ->
            match (acc, value.inherited) with
            | Some left, Some right ->
                Some (List.sort_uniq String.compare (left @ right))
            | _ -> None )
          (Some [])
          values
      in
      { fields= Schema.common (List.map (fun v -> v.fields) values)
      ; inherited= (if values = [] then None else inherited)
      ; alternatives= values }

let rec combine left right =
  match (left, right) with
  | Scalar left, Scalar right -> Scalar (common [left; right])
  | Batch left, Batch right -> Batch (combine left right)
  | Fixed left, Fixed right when List.length left = List.length right ->
      Fixed (List.map2 combine left right)
  | _ -> fail "Shape" "Branch cases must return compatible shapes"

let kind_for bindings target =
  match
    List.find_opt
      (fun (known, _) -> Flow_access.pattern known = Flow_access.pattern target)
      bindings
  with
  | Some (_, kind) -> kind
  | None ->
      fail "Address" ("No reproduce declaration for address: " ^ target.text)

(* Intersect requirements on the original input, including nested records.
   A contradiction is rejected, never weakened to Any. *)
let rec meet left right =
  match (left, right) with
  | Schema.Optional l, Schema.Optional r -> Schema.Optional (meet l r)
  | Schema.Optional l, r
   |l, Schema.Optional r ->
      meet l r
  | Schema.Object l, Schema.Object r -> Schema.Object (requirements l r)
  | Schema.List l, Schema.List r -> Schema.List (meet l r)
  | Schema.Dict l, Schema.Dict r -> Schema.Dict (meet l r)
  | Schema.Tuple l, Schema.Tuple r when List.length l = List.length r ->
      Schema.Tuple (List.map2 meet l r)
  | Schema.Tagged left, Schema.Tagged right ->
      let cases =
        List.filter_map
          (fun (tag, args) ->
            match List.assoc_opt tag right with
            | Some required when List.length args = List.length required -> (
              try Some (tag, List.map2 meet args required) with
              | Error _ -> None )
            | _ -> None )
          left
      in
      if cases = [] then fail "Contract" "Incompatible Flow input variant tags" ;
      Schema.Tagged cases
  | _ when Schema.accepts left right -> left
  | _ when Schema.accepts right left -> right
  | Schema.Any_of values, r -> alternatives values r
  | l, Schema.Any_of values -> alternatives values l
  | _ ->
      fail "Contract" "Incompatible requirements on the same Flow input field"

and alternatives values required =
  let values =
    List.filter_map
      (fun value ->
        try Some (meet value required) with
        | Error _ -> None )
      values
  in
  match values with
  | [] -> fail "Contract" "Incompatible Flow input alternatives"
  | _ -> Schema.union values

and requirements left right =
  List.fold_left
    (fun fields (name, value) ->
      let value =
        match List.assoc_opt name fields with
        | None -> value
        | Some previous -> meet previous value
      in
      Schema.merge fields [(name, value)] )
    left
    right

exception Need_input of Schema.fields

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
  let compile_with input =
    let rec require actual expected =
      if actual.alternatives <> []
      then List.iter (fun branch -> require branch expected) actual.alternatives
      else
        List.iter
          (fun (name, value) ->
            if not (Schema.covers actual.fields [(name, value)])
            then
              match actual.inherited with
              | Some excluded when flow.inferred && not (List.mem name excluded)
                ->
                  let next = requirements input [(name, value)] in
                  if next = input
                  then Schema.require actual.fields [(name, value)] ;
                  raise (Need_input next)
              | _ -> Schema.require actual.fields [(name, value)] )
          expected
    in
    let target_fields target shape =
      List.iter
        (function
          | Literal _ -> ()
          | Field path ->
              let rec nested = function
                | [] -> Schema.String
                | name :: rest -> Schema.Object [(name, nested rest)]
              in
              let expected =
                match nested path with
                | Schema.Object f -> f
                | _ -> []
              in
              let facts = scalar shape in
              if flow.inferred then require facts expected ;
              if Schema.project facts.fields path <> Schema.String
              then
                fail
                  "Address"
                  "Address expression requires a required String field" )
        target.parts
    in
    let rec output_mode facts output mode =
      if facts.alternatives <> []
      then
        common
          (List.map
             (fun branch -> output_mode branch output mode)
             facts.alternatives )
      else
        match mode with
        | Fresh -> closed output
        | Patch remove
         |Selected remove ->
            { fields=
                Schema.merge
                  (List.filter
                     (fun (name, _) -> not (List.mem name remove))
                     facts.fields )
                  output
            ; inherited=
                Option.map
                  (fun excluded ->
                    List.sort_uniq
                      String.compare
                      (excluded @ remove @ List.map fst output) )
                  facts.inherited
            ; alternatives= [] }
    in
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
                (fun op -> operation_name op = step.op)
                spec.operations
            with
            | Some op -> op
            | None ->
                fail "Operation" ("Unknown operation: " ^ kind ^ "." ^ step.op)
          in
          let output =
            match operation with
            | Raw (Transformer op) ->
                let facts = scalar shape in
                require facts op.input ;
                Scalar (output_mode facts op.output (Patch []))
            | Raw (Expander op) ->
                require (scalar shape) op.input ;
                Batch (Scalar (closed op.output))
            | Raw (Joiner op) ->
                List.iter (fun facts -> require facts op.input) (flat shape) ;
                Scalar (closed op.output)
            | Raw (Router op) ->
                let facts = scalar shape in
                require facts op.input ;
                Routes
                  (List.map
                     (fun (port, fields) ->
                       (port, output_mode facts fields (Patch [])) )
                     op.output )
            | Typed op -> (
                let inputs =
                  if op.shape = Join then flat shape else [scalar shape]
                in
                List.iter (fun facts -> require facts op.input) inputs ;
                let base = common inputs in
                let outputs =
                  List.map
                    (fun (port, fields) ->
                      (port, output_mode base fields op.output_mode) )
                    op.outputs
                in
                match op.shape with
                | One
                 |Join ->
                    Scalar (snd (List.hd outputs))
                | Many -> Batch (Scalar (snd (List.hd outputs)))
                | Route -> Routes outputs )
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
          let body, output = node (Scalar (common (flat shape))) body in
          (Each body, Batch output)
      | Flatten ->
          ( match shape with
          | Batch _
           |Fixed _ ->
              ()
          | _ -> fail "Shape" "!flatten requires a group" ) ;
          (Flatten, Batch (Scalar (common (leaves shape))))
      | Branch (source, cases) ->
          let source, ports = node shape source in
          let ports =
            match ports with
            | Routes ports -> ports
            | _ -> fail "Router" "Branch source must be a Router"
          in
          let names = List.map fst cases |> List.sort String.compare in
          if
            names <> List.sort String.compare (List.map fst ports)
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
          let output =
            match List.map (fun (_, _, output) -> output) cases with
            | first :: rest -> List.fold_left combine first rest
            | [] -> fail "Router" "Empty branch"
          in
          ( Branch (source, List.map (fun (port, body, _) -> (port, body)) cases)
          , output )
    in
    let ast, output =
      node
        (Scalar {fields= input; inherited= Some []; alternatives= []})
        flow.ast
    in
    let output = (scalar output).fields in
    if not flow.inferred then Schema.require output flow.spec.output ;
    { flow with
      ast
    ; spec=
        { flow.spec with
          input
        ; output= (if flow.inferred then output else flow.spec.output) } }
  in
  let rec infer input =
    try compile_with input with
    | Need_input next -> infer next
  in
  try
    transactions false flow.ast ;
    infer (if flow.inferred then [] else flow.spec.input)
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
