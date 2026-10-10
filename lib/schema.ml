open Yojson.Safe.Util

type t =
  | Any | Null | String | Int | Number | Bool
  | List of t | Object of fields | Dict of t | Any_of of t list | Optional of t
and fields = (string * t) list
exception Error of string
let fail message = raise (Error message)
let rec check_json = function
  | `Assoc fields ->
      let names = List.map fst fields in
      if List.length names <> List.length (List.sort_uniq String.compare names)
      then fail "Duplicate JSON object key";
      List.iter (fun (_, value) -> check_json value) fields
  | `List values -> List.iter check_json values
  | `Float value when not (Float.is_finite value) -> fail "Non-finite JSON number"
  | `Intlit value ->
      (match Yojson.Safe.from_string value with
       | `Int _ | `Intlit _ -> () | _ -> fail "Invalid JSON integer")
  | _ -> ()
let rec describe = function
  | Any -> `String "Any" | Null -> `String "Null"
  | String -> `String "String" | Int -> `String "Int"
  | Number -> `String "Number" | Bool -> `String "Bool"
  | List value -> `Assoc ["list", describe value]
  | Object fields -> `Assoc ["object", fields_json fields]
  | Dict value -> `Assoc ["dict", describe value]
  | Any_of values -> `Assoc ["any_of", `List (List.map describe values)]
  | Optional value -> `Assoc ["optional", describe value]
and fields_json fields =
  `List (List.map (fun (name, value) -> `Assoc ["name", `String name; "type", describe value]) fields)
let rec value_of_json = function
  | `String "Any" -> Any | `String "Null" -> Null
  | `String "String" -> String | `String "Int" -> Int
  | `String "Number" -> Number | `String "Bool" -> Bool
  | `Assoc ["list", value] -> List (value_of_json value)
  | `Assoc ["object", fields] -> Object (fields_of_json fields)
  | `Assoc ["dict", value] -> Dict (value_of_json value)
  | `Assoc ["any_of", `List values] -> Any_of (List.map value_of_json values)
  | `Assoc ["optional", value] -> Optional (value_of_json value)
  | _ -> fail "Unknown schema type"
and fields_of_json = function
  | `List values -> List.map (fun item ->
      (item |> member "name" |> to_string), value_of_json (member "type" item)) values
  | _ -> fail "Expected schema fields"
let rec check_definition fields =
  let names = List.map fst fields in
  if List.length names <> List.length (List.sort_uniq String.compare names)
  then fail "Duplicate schema field";
  List.iter (fun (_, value) -> match value with
    | Optional value -> check_type value | value -> check_type value) fields
and check_type = function
  | List value | Dict value -> check_type value
  | Object fields -> check_definition fields
  | Any_of [] -> fail "Empty schema alternative"
  | Any_of values -> List.iter check_type values
  | Optional _ -> fail "Optional is only allowed as a field descriptor"
  | _ -> ()
let rec validate_value path expected actual =
  let invalid () = fail ("Schema mismatch at " ^ path) in
  match expected, actual with
  | Any, _ | Null, `Null | String, `String _ | Int, (`Int _ | `Intlit _)
  | Number, (`Float _ | `Int _ | `Intlit _) | Bool, `Bool _ -> ()
  | List expected, `List values ->
      List.iteri (fun index value ->
        validate_value (path ^ "[" ^ string_of_int index ^ "]") expected value) values
  | Object expected, `Assoc _ -> validate_fields path expected actual
  | Dict expected, `Assoc fields ->
      List.iter (fun (name, value) -> validate_value (path ^ "." ^ name) expected value) fields
  | Any_of alternatives, value ->
      if not (List.exists (fun expected ->
        try validate_value path expected value; true with Error _ -> false) alternatives)
      then invalid ()
  | _ -> invalid ()
and validate_fields path expected actual =
  let fields = to_assoc actual in
  List.iter (fun (name, expected) ->
    match List.assoc_opt name fields, expected with
    | None, Optional _ -> ()
    | None, _ -> fail ("Missing required field: " ^ path ^ "." ^ name)
    | Some value, Optional expected -> validate_value (path ^ "." ^ name) expected value
    | Some value, expected -> validate_value (path ^ "." ^ name) expected value) expected
let validate expected actual = check_json actual; validate_fields "$" expected actual
let rec accepts actual expected =
  match actual, expected with
  | _, Any -> true
  | Any_of alternatives, expected -> List.for_all (fun actual -> accepts actual expected) alternatives
  | actual, Any_of alternatives -> List.exists (accepts actual) alternatives
  | Int, Number -> true
  | List actual, List expected | Dict actual, Dict expected -> accepts actual expected
  | Object actual, Object expected -> covers actual expected
  | Object _, Dict expected -> accepts Any expected
  | Dict actual, Object expected ->
      List.for_all (function _, Optional expected -> accepts actual expected | _ -> false) expected
  | actual, expected -> actual = expected
and covers actual expected =
  List.for_all (fun (name, expected) ->
    match List.assoc_opt name actual, expected with
    | None, Optional expected -> accepts Any expected
    | Some (Optional actual), Optional expected -> accepts actual expected
    | Some actual, Optional expected -> accepts actual expected
    | Some (Optional _), _ -> false
    | Some actual, expected -> accepts actual expected
    | None, _ -> false) expected
let require actual expected =
  if not (covers actual expected) then fail "Input fields are not guaranteed by previous output"
let merge input output =
  output @ List.filter (fun (name, _) -> not (List.mem_assoc name output)) input
let union values =
  let rec flatten = function Any_of values -> List.concat_map flatten values | value -> [value] in
  let values = List.concat_map flatten values |> List.sort_uniq Stdlib.compare in
  let values = List.filter (fun value ->
    not (List.exists (fun other -> value <> other && accepts value other &&
      (not (accepts other value) || Stdlib.compare other value < 0)) values)) values in
  match values with [value] -> value | values -> Any_of values
let common fields =
  let names = List.concat_map (List.map fst) fields |> List.sort_uniq String.compare in
  List.map (fun name ->
    let values = List.map (List.assoc_opt name) fields in
    let required = List.for_all (function Some (Optional _) | None -> false | _ -> true) values in
    let value = union (List.map (function
      | None -> Any | Some (Optional value) | Some value -> value) values) in
    name, (if required then value else Optional value)) names
let rec project fields = function
  | [] -> fail "Empty field path"
  | name :: rest ->
      let value = match List.assoc_opt name fields with
        | Some (Optional _) | None -> fail ("Target field is not required: " ^ name)
        | Some value -> value in
      if rest = [] then union [value] else project_value value rest
and project_value value path =
  match value with
  | Object fields -> project fields path
  | Any_of values -> union (List.map (fun value -> project_value value path) values)
  | _ -> fail "Target field is not a required object"
let preserve output before after =
  List.iter (fun (name, value) ->
    if not (List.mem_assoc name output) then
      match List.assoc_opt name (to_assoc after) with
      | Some next when Yojson.Safe.equal value next -> ()
      | _ -> fail ("Transformer changed undeclared field: " ^ name))
    (to_assoc before)
