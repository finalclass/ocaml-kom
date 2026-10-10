type value =
  | String | Int | Float | Bool
  | List of value | Object of fields | Optional of value
and fields = (string * value) list
let rec describe = function
  | String -> `String "String" | Int -> `String "Int"
  | Float -> `String "Float" | Bool -> `String "Bool"
  | List value -> `Assoc ["list", describe value]
  | Object fields -> `Assoc ["object", fields_json fields]
  | Optional value -> `Assoc ["optional", describe value]
and fields_json fields =
  `List (List.map (fun (name, value) -> `Assoc ["name", `String name; "type", describe value]) fields)
let rec value_of_json = function
  | `String "String" -> String | `String "Int" -> Int
  | `String "Float" -> Float | `String "Bool" -> Bool
  | `Assoc ["list", value] -> List (value_of_json value)
  | `Assoc ["object", fields] -> Object (fields_of_json fields)
  | `Assoc ["optional", value] -> Optional (value_of_json value)
  | _ -> Json.fail "Unknown schema type"
and fields_of_json = function
  | `List values -> List.map (fun item ->
      Json.get_string "name" item, value_of_json (Json.get "type" item)) values
  | _ -> Json.fail "Expected schema fields"
let rec check_definition fields =
  let names = List.map fst fields in
  if List.exists ((=) "") names ||
     List.length names <> List.length (List.sort_uniq String.compare names)
  then Json.fail "Empty or duplicate schema field";
  List.iter (fun (_, value) -> check_type value) fields
and check_type = function
  | List value | Optional value -> check_type value
  | Object fields -> check_definition fields | _ -> ()
let rec validate_value path expected actual =
  let invalid () = Json.fail ("Schema mismatch at " ^ path) in
  match expected, actual with
  | String, `String _ | Int, `Int _ | Float, (`Float _ | `Int _)
  | Bool, `Bool _ -> ()
  | Optional _, `Null -> ()
  | Optional expected, actual -> validate_value path expected actual
  | List expected, `List values ->
      List.iteri (fun index value ->
        validate_value (path ^ "[" ^ string_of_int index ^ "]") expected value) values
  | Object expected, `Assoc _ -> validate_fields path expected actual
  | _ -> invalid ()
and validate_fields path expected actual =
  let fields = Json.fields actual in
  List.iter (fun (name, expected) ->
    match List.assoc_opt name fields, expected with
    | None, Optional _ -> ()
    | None, _ -> Json.fail ("Missing required field: " ^ path ^ "." ^ name)
    | Some value, _ -> validate_value (path ^ "." ^ name) expected value) expected
let validate expected actual = Json.check actual; validate_fields "$" expected actual
let rec accepts actual expected =
  match actual, expected with
  | Optional actual, Optional expected -> accepts actual expected
  | actual, Optional expected -> accepts actual expected
  | Int, Float -> true
  | List actual, List expected -> accepts actual expected
  | Object actual, Object expected -> covers actual expected
  | actual, expected -> actual = expected
and covers actual expected =
  List.for_all (fun (name, expected) ->
    match List.assoc_opt name actual, expected with
    | None, Optional _ -> true
    | Some actual, _ -> accepts actual expected | _ -> false) expected
let require actual expected =
  if not (covers actual expected) then Json.fail "Input fields are not guaranteed by previous output"
let merge input output =
  output @ List.filter (fun (name, _) -> not (List.mem_assoc name output)) input
let common fields =
  match fields with
  | [] -> []
  | first :: rest ->
      List.filter (fun (name, value) ->
        List.for_all (fun fields -> List.assoc_opt name fields = Some value) rest) first
let rec project fields = function
  | [] -> Json.fail "Empty field path"
  | [name] -> (match List.assoc_opt name fields with
      | Some value -> value | None -> Json.fail ("Unknown target field: " ^ name))
  | name :: rest -> (match List.assoc_opt name fields with
      | Some (Object nested) -> project nested rest
      | _ -> Json.fail ("Target field is not a required object: " ^ name))
let preserve output before after =
  List.iter (fun (name, value) ->
    if not (List.mem_assoc name output) then
      match List.assoc_opt name (Json.fields after) with
      | Some next when Json.equal value next -> ()
      | _ -> Json.fail ("Transformer changed undeclared field: " ^ name))
    (Json.fields before)
