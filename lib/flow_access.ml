open Yojson.Safe.Util
open Native_contract

let template text =
  let length = String.length text in
  let rec read index parts =
    match String.index_from_opt text index '{' with
    | None ->
        let parts =
          if index < length
          then Literal (String.sub text index (length - index)) :: parts
          else parts
        in
        {text; parts= List.rev parts}
    | Some start ->
        if start + 3 > length || String.sub text start 3 <> "{$."
        then fail "Address" ("Invalid address expression: " ^ text) ;
        let finish =
          match String.index_from_opt text (start + 3) '}' with
          | Some finish -> finish
          | None -> fail "Address" "Unclosed address expression"
        in
        let field =
          String.sub text (start + 3) (finish - start - 3)
          |> String.split_on_char '.'
        in
        if List.exists (( = ) "") field
        then fail "Address" "Empty address field" ;
        let parts =
          if start > index
          then Literal (String.sub text index (start - index)) :: parts
          else parts
        in
        read (finish + 1) (Field field :: parts)
  in
  if text = "" then fail "Address" "Empty address" ;
  read 0 []

let pattern target =
  List.map
    (function
      | Literal text -> `String text
      | Field _ -> `Null )
    target.parts

let render target value =
  let rec field value = function
    | [] -> value
    | name :: rest -> field (member name value) rest
  in
  let address =
    String.concat
      ""
      (List.map
         (function
           | Literal text -> text
           | Field path ->
               let message =
                 match value with
                 | Message message -> message.body
                 | _ -> fail "Shape" "Address requires one message"
               in
               to_string (field message path) )
         target.parts )
  in
  if address = "" then fail "Address" "Empty instance address" ;
  address

let tokenize text =
  let length = String.length text in
  let boundary = function
    | ' '
     |'\t'
     |'\r'
     |'\n'
     |';'
     |'('
     |')'
     |',' ->
        true
    | _ -> false
  in
  let rec loop index tokens =
    if index = length
    then Array.of_list (List.rev tokens)
    else
      match text.[index] with
      | ' '
       |'\t' ->
          loop (index + 1) tokens
      | '\r'
       |'\n'
       |';' ->
          loop (index + 1) (";" :: tokens)
      | ('(' | ')' | ',') as ch -> loop (index + 1) (String.make 1 ch :: tokens)
      | _ ->
          let finish = ref index in
          while !finish < length && not (boundary text.[!finish]) do
            incr finish
          done ;
          loop !finish (String.sub text index (!finish - index) :: tokens)
  in
  loop 0 []

let parse text =
  let tokens = tokenize text in
  let index = ref 0 in
  let peek () =
    if !index < Array.length tokens then Some tokens.(!index) else None
  in
  let take () =
    match peek () with
    | None -> fail "Parse" "Unexpected end of Flow"
    | Some token ->
        incr index ;
        token
  in
  let expect token =
    if take () <> token then fail "Parse" ("Expected " ^ token)
  in
  let rec separators () =
    if peek () = Some ";"
    then (
      ignore (take ()) ;
      separators () )
  in
  let boundary closing =
    match peek () with
    | Some ";" -> separators ()
    | token when token = closing -> ()
    | Some token -> fail "Parse" ("Expected newline or ';' before " ^ token)
    | None -> fail "Parse" "Unclosed Flow block"
  in
  let address () =
    let value = take () in
    if (not (String.starts_with ~prefix:"@" value)) || String.length value = 1
    then fail "Parse" "Expected @address" ;
    template (String.sub value 1 (String.length value - 1))
  in
  let pack = function
    | [node] -> node
    | nodes -> Sequence nodes
  in
  let rec statements closing =
    separators () ;
    let rec read acc =
      if peek () = closing
      then List.rev acc
      else
        match peek () with
        | None -> fail "Parse" "Unclosed Flow block"
        | _ ->
            let value = node () in
            boundary closing ;
            read (value :: acc)
    in
    read []
  and block () =
    expect "(" ;
    let values = statements (Some ")") in
    expect ")" ;
    values
  and node () =
    match take () with
    | "!sequence" -> Sequence (block ())
    | "!parallel" -> Parallel (block ())
    | "!transaction" -> Transaction (pack (block ()))
    | "!parallel_each" -> Each (pack (block ()))
    | "!flatten" ->
        if peek () = Some "("
        then (
          expect "(" ;
          separators () ;
          expect ")" ) ;
        Flatten
    | "!reproduce" ->
        let kind = take () in
        if kind = ";" || kind = "(" || kind = ")"
        then fail "Parse" "Expected cell kind" ;
        expect "as" ;
        Reproduce (kind, address ())
    | "!branch" ->
        expect "(" ;
        separators () ;
        let source = node () in
        boundary (Some ")") ;
        let rec cases acc =
          match peek () with
          | Some ")" ->
              ignore (take ()) ;
              List.rev acc
          | None -> fail "Parse" "Unclosed branch"
          | _ ->
              let port = take () in
              let body = pack (block ()) in
              boundary (Some ")") ;
              cases ((port, body) :: acc)
        in
        Branch (source, cases [])
    | token
      when token = "("
           || token = ")"
           || token = ";"
           || token = ","
           || String.starts_with ~prefix:"!" token ->
        fail "Parse" ("Unknown Flow instruction: " ^ token)
    | op -> Step {op; target= address (); kind= ""}
  in
  pack (statements None)

let rec ast_json = function
  | Step step ->
      `Assoc
        [ ("type", `String "step")
        ; ("operation", `String step.op)
        ; ("target", `String step.target.text)
        ; ("cell_kind", `String step.kind) ]
  | Reproduce (kind, target) ->
      `Assoc
        [ ("type", `String "reproduce")
        ; ("cell_kind", `String kind)
        ; ("target", `String target.text) ]
  | Sequence nodes ->
      `Assoc
        [ ("type", `String "sequence")
        ; ("nodes", `List (List.map ast_json nodes)) ]
  | Parallel nodes ->
      `Assoc
        [ ("type", `String "parallel")
        ; ("nodes", `List (List.map ast_json nodes)) ]
  | Transaction node ->
      `Assoc [("type", `String "transaction"); ("body", ast_json node)]
  | Each node ->
      `Assoc [("type", `String "parallel_each"); ("body", ast_json node)]
  | Flatten -> `Assoc [("type", `String "flatten")]
  | Branch (source, cases) ->
      `Assoc
        [ ("type", `String "branch")
        ; ("source", ast_json source)
        ; ( "cases"
          , `List
              (List.map
                 (fun (port, body) ->
                   `Assoc [("port", `String port); ("body", ast_json body)] )
                 cases ) ) ]

let rec ast_of_json json =
  match json |> member "type" |> to_string with
  | "step" ->
      Step
        { op= json |> member "operation" |> to_string
        ; target= template (json |> member "target" |> to_string)
        ; kind= "" }
  | "reproduce" ->
      Reproduce
        ( json |> member "cell_kind" |> to_string
        , template (json |> member "target" |> to_string) )
  | "sequence" ->
      Sequence (List.map ast_of_json (json |> member "nodes" |> to_list))
  | "parallel" ->
      Parallel (List.map ast_of_json (json |> member "nodes" |> to_list))
  | "transaction" -> Transaction (ast_of_json (member "body" json))
  | "parallel_each" -> Each (ast_of_json (member "body" json))
  | "flatten" -> Flatten
  | "branch" ->
      Branch
        ( ast_of_json (member "source" json)
        , List.map
            (fun entry ->
              ( entry |> member "port" |> to_string
              , ast_of_json (member "body" entry) ) )
            (json |> member "cases" |> to_list) )
  | name -> fail "Parse" ("Unknown AST node: " ^ name)

let define ?(version = 1) (spec : flow_spec) =
  if spec.id = "" || version < 1
  then fail "Flow" "Invalid Flow identity or version" ;
  Schema.check_definition spec.input ;
  Schema.check_definition spec.output ;
  {version; spec; ast= parse spec.body; inferred= false}

let describe flow =
  `Assoc
    [ ("id", `String flow.spec.id)
    ; ("version", `Int flow.version)
    ; ("input", Schema.fields_json flow.spec.input)
    ; ("output", Schema.fields_json flow.spec.output)
    ; ("body", ast_json flow.ast) ]

let of_json json =
  Schema.check_json json ;
  let spec =
    { id= json |> member "id" |> to_string
    ; input= Schema.fields_of_json (member "input" json)
    ; output= Schema.fields_of_json (member "output" json)
    ; body= "" }
  in
  let version = json |> member "version" |> to_int in
  if spec.id = "" || version < 1
  then fail "Flow" "Invalid Flow identity or version" ;
  Schema.check_definition spec.input ;
  Schema.check_definition spec.output ;
  {version; spec; ast= ast_of_json (member "body" json); inferred= false}

let resolve definition id =
  match List.find_opt (fun flow -> flow.spec.id = id) definition.flows with
  | Some flow -> flow
  | None -> fail "Flow" ("Unknown Flow: " ^ id)

let rec creations = function
  | Reproduce (kind, target) -> [(target, kind)]
  | Sequence nodes
   |Parallel nodes ->
      List.concat_map creations nodes
  | Each body
   |Transaction body ->
      creations body
  | Branch (source, cases) ->
      creations source @ List.concat_map (fun (_, body) -> creations body) cases
  | Step _
   |Flatten ->
      []
