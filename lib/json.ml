type t = Yojson.Safe.t
exception Error of string
let fail message = raise (Error message)
let rec check = function
  | `Assoc fields ->
      let names = List.map fst fields in
      if List.length names <> List.length (List.sort_uniq String.compare names)
      then fail "Duplicate JSON object key";
      List.iter (fun (_, value) -> check value) fields
  | `List values -> List.iter check values
  | `Float value when not (Float.is_finite value) -> fail "Non-finite JSON number"
  | `Intlit value ->
      (match (try Yojson.Safe.from_string value with _ -> fail "Invalid JSON integer") with
       | `Int _ | `Intlit _ -> () | _ -> fail "Invalid JSON integer")
  | _ -> ()
let of_string text =
  let value = try Yojson.Safe.from_string text with Yojson.Json_error message -> fail message in
  check value; value
let to_string value = check value; Yojson.Safe.to_string value
let object_ fields = let value = `Assoc fields in check value; value
let string value = `String value
let int value = `Int value
let array values = `List values
let null = `Null
let is_null value = value = `Null
let fields = function `Assoc fields -> fields | _ -> fail "Expected JSON object"
let get name value =
  match List.assoc_opt name (fields value) with
  | Some value -> value | None -> fail ("Missing field: " ^ name)
let as_string = function `String value -> value | _ -> fail "Expected String"
let get_string name value = as_string (get name value)
let get_int name value =
  match get name value with `Int value -> value | _ -> fail ("Expected Int: " ^ name)
let get_bool name value =
  match get name value with `Bool value -> value | _ -> fail ("Expected Bool: " ^ name)
let get_list name value =
  match get name value with `List values -> values | _ -> fail ("Expected List: " ^ name)
let get_string_list name value = List.map as_string (get_list name value)
let set name value object_value =
  `Assoc ((name, value) :: List.remove_assoc name (fields object_value))
let rec canonical = function
  | `Assoc fields ->
      `Assoc (List.map (fun (name, value) -> name, canonical value)
        (List.sort (fun (a, _) (b, _) -> String.compare a b) fields))
  | `List values -> `List (List.map canonical values)
  | value -> value
let equal left right = canonical left = canonical right
