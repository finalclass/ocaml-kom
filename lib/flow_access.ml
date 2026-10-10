open Native_contract
let template text =
  let length = String.length text in
  let rec read index parts =
    match String.index_from_opt text index '{' with
    | None ->
        let parts = if index < length then Literal (String.sub text index (length - index)) :: parts else parts in
        {text; parts = List.rev parts}
    | Some start ->
        if start + 3 > length || String.sub text start 3 <> "{$."
        then fail "Address" ("Invalid address expression: " ^ text);
        let finish = match String.index_from_opt text (start + 3) '}' with
          | Some finish -> finish | None -> fail "Address" "Unclosed address expression" in
        let field = String.sub text (start + 3) (finish - start - 3) |> String.split_on_char '.' in
        if List.exists ((=) "") field then fail "Address" "Empty address field";
        let parts = if start > index then Literal (String.sub text index (start - index)) :: parts else parts in
        read (finish + 1) (Field field :: parts)
  in
  if text = "" then fail "Address" "Empty address";
  read 0 []
let pattern target =
  List.map (function Literal text -> `String text | Field _ -> `Null) target.parts
let render target value =
  let rec field value = function [] -> value | name :: rest -> field (Json.get name value) rest in
  let address = String.concat "" (List.map (function
    | Literal text -> text
    | Field path ->
        let message = match value with Message message -> message
          | _ -> fail "Shape" "Address requires one message" in
        Json.as_string (field message path)) target.parts) in
  if address = "" then fail "Address" "Empty instance address";
  address
let tokenize text =
  let length = String.length text in
  let separator = function ' ' | '\t' | '\r' | '\n' | ',' | ';' -> true | _ -> false in
  let rec loop index tokens =
    if index = length then Array.of_list (List.rev tokens)
    else if separator text.[index] then loop (index + 1) tokens
    else if text.[index] = '(' || text.[index] = ')' then
      loop (index + 1) (String.make 1 text.[index] :: tokens)
    else
      let finish = ref index in
      while !finish < length && not (separator text.[!finish]) &&
            text.[!finish] <> '(' && text.[!finish] <> ')' do incr finish done;
      loop !finish (String.sub text index (!finish - index) :: tokens)
  in loop 0 []
let parse text =
  let tokens = tokenize text in
  let index = ref 0 in
  let peek () = if !index < Array.length tokens then Some tokens.(!index) else None in
  let take () = match peek () with
    | None -> fail "Parse" "Unexpected end of Flow"
    | Some token -> incr index; token in
  let expect token = if take () <> token then fail "Parse" ("Expected " ^ token) in
  let rec node () =
    match take () with
    | "!sequence" -> Sequence (nodes ())
    | "!parallel" -> Parallel (nodes ())
    | "!parallel_each" ->
        expect "("; let body = node () in expect ")"; Each body
    | "!flatten" ->
        if peek () = Some "(" then (expect "("; expect ")");
        Flatten
    | "!reproduce" ->
        let kind = take () in expect "as"; Reproduce (kind, template (take ()))
    | "!branch" ->
        expect "("; let source = node () in
        let rec cases acc =
          match peek () with
          | Some ")" -> ignore (take ()); List.rev acc
          | None -> fail "Parse" "Unclosed branch"
          | _ ->
              let port = take () in expect "(";
              let body = node () in expect ")";
              cases ((port, body) :: acc)
        in Branch (source, cases [])
    | token when token = "(" || token = ")" || String.starts_with ~prefix:"!" token ->
        fail "Parse" ("Unknown Flow instruction: " ^ token)
    | op ->
        let address = take () in
        if not (String.starts_with ~prefix:"@" address) then fail "Parse" "Expected @address";
        Step {op; target = template (String.sub address 1 (String.length address - 1)); kind = ""}
  and nodes () =
    expect "(";
    let rec read acc =
      match peek () with
      | Some ")" -> ignore (take ()); List.rev acc
      | None -> fail "Parse" "Unclosed Flow block"
      | _ -> read (node () :: acc)
    in read []
  in
  let ast = node () in
  if peek () <> None then fail "Parse" "Unexpected token after Flow";
  ast
let rec ast_json = function
  | Step step -> `Assoc [
      "type", `String "step"; "operation", `String step.op;
      "target", `String step.target.text; "cell_kind", `String step.kind]
  | Reproduce (kind, target) -> `Assoc [
      "type", `String "reproduce"; "cell_kind", `String kind; "target", `String target.text]
  | Sequence nodes -> `Assoc ["type", `String "sequence"; "nodes", `List (List.map ast_json nodes)]
  | Parallel nodes -> `Assoc ["type", `String "parallel"; "nodes", `List (List.map ast_json nodes)]
  | Each node -> `Assoc ["type", `String "parallel_each"; "body", ast_json node]
  | Flatten -> `Assoc ["type", `String "flatten"]
  | Branch (source, cases) -> `Assoc [
      "type", `String "branch"; "source", ast_json source;
      "cases", `List (List.map (fun (port, body) ->
        `Assoc ["port", `String port; "body", ast_json body]) cases)]
let rec ast_of_json json =
  match Json.get_string "type" json with
  | "step" -> Step {op = Json.get_string "operation" json;
      target = template (Json.get_string "target" json); kind = ""}
  | "reproduce" -> Reproduce (Json.get_string "cell_kind" json, template (Json.get_string "target" json))
  | "sequence" -> Sequence (List.map ast_of_json (Json.get_list "nodes" json))
  | "parallel" -> Parallel (List.map ast_of_json (Json.get_list "nodes" json))
  | "parallel_each" -> Each (ast_of_json (Json.get "body" json))
  | "flatten" -> Flatten
  | "branch" -> Branch (ast_of_json (Json.get "source" json),
      List.map (fun entry -> Json.get_string "port" entry, ast_of_json (Json.get "body" entry))
        (Json.get_list "cases" json))
  | name -> fail "Parse" ("Unknown AST node: " ^ name)
let define ?(version = 1) (spec : flow_spec) =
  if spec.id = "" || version < 1 then fail "Flow" "Invalid Flow identity or version";
  Schema.check_definition spec.input; Schema.check_definition spec.output;
  {version; spec; ast = parse spec.body}
let describe flow = `Assoc [
  "id", `String flow.spec.id; "version", `Int flow.version;
  "input", Schema.fields_json flow.spec.input; "output", Schema.fields_json flow.spec.output;
  "body", ast_json flow.ast]
let of_json json =
  Json.check json;
  let spec = {id = Json.get_string "id" json;
    input = Schema.fields_of_json (Json.get "input" json);
    output = Schema.fields_of_json (Json.get "output" json); body = ""} in
  let version = Json.get_int "version" json in
  if spec.id = "" || version < 1 then fail "Flow" "Invalid Flow identity or version";
  Schema.check_definition spec.input; Schema.check_definition spec.output;
  {version; spec; ast = ast_of_json (Json.get "body" json)}
let resolve definition id =
  match List.find_opt (fun flow -> flow.spec.id = id) definition.flows with
  | Some flow -> flow | None -> fail "Flow" ("Unknown Flow: " ^ id)
let rec creations = function
  | Reproduce (kind, target) -> [target, kind]
  | Sequence nodes | Parallel nodes -> List.concat_map creations nodes
  | Each body -> creations body
  | Branch (source, cases) -> creations source @ List.concat_map (fun (_, body) -> creations body) cases
  | Step _ | Flatten -> []
