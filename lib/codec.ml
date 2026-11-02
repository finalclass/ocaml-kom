type 'a t =
  { schema: Schema.t
  ; encode: 'a -> Yojson.Safe.t
  ; decode: Yojson.Safe.t -> ('a, string) result }

let make ~schema ~encode ~decode = {schema; encode; decode}

let schema codec = codec.schema

let encode codec value = codec.encode value

let decode codec value = codec.decode value

let fields codec =
  match codec.schema with
  | Schema.Object fields -> fields
  | _ -> invalid_arg "Kom messages must have a record/object type"

let string =
  make
    ~schema:Schema.String
    ~encode:(fun value -> `String value)
    ~decode:(function
      | `String value -> Ok value
      | _ -> Error "Expected string" )

let int =
  make
    ~schema:Schema.Int
    ~encode:(fun value -> `Int value)
    ~decode:(function
      | `Int value -> Ok value
      | _ -> Error "Expected int" )

let float =
  make
    ~schema:Schema.Number
    ~encode:(fun value -> `Float value)
    ~decode:(function
      | `Float value -> Ok value
      | `Int value -> Ok (float_of_int value)
      | _ -> Error "Expected number" )

let bool =
  make
    ~schema:Schema.Bool
    ~encode:(fun value -> `Bool value)
    ~decode:(function
      | `Bool value -> Ok value
      | _ -> Error "Expected bool" )

let unit =
  make
    ~schema:(Schema.Object [])
    ~encode:(fun () -> `Assoc [])
    ~decode:(function
      | `Assoc _ -> Ok ()
      | _ -> Error "Expected object" )

let json =
  make ~schema:Schema.Any ~encode:Fun.id ~decode:(fun value -> Ok value)

let rec traverse decode = function
  | [] -> Ok []
  | value :: rest ->
      Result.bind (decode value) (fun value ->
          Result.map (fun rest -> value :: rest) (traverse decode rest) )

let list codec =
  make
    ~schema:(Schema.List codec.schema)
    ~encode:(fun values -> `List (List.map codec.encode values))
    ~decode:(function
      | `List values -> traverse codec.decode values
      | _ -> Error "Expected list" )

let array codec =
  let values = list codec in
  make
    ~schema:values.schema
    ~encode:(fun a -> values.encode (Array.to_list a))
    ~decode:(fun json -> Result.map Array.of_list (values.decode json))

let option codec =
  make
    ~schema:(Schema.Any_of [Schema.Null; codec.schema])
    ~encode:(function
      | None -> `Null
      | Some value -> codec.encode value )
    ~decode:(function
      | `Null -> Ok None
      | value -> Result.map Option.some (codec.decode value) )

let field codec name fields =
  match List.assoc_opt name fields with
  | None -> Error ("Missing field: " ^ name)
  | Some value ->
      Result.map_error (fun error -> name ^ ": " ^ error) (codec.decode value)

let optional_field codec name fields =
  match List.assoc_opt name fields with
  | None
   |Some `Null ->
      Ok None
  | Some value ->
      Result.map
        Option.some
        (Result.map_error
           (fun error -> name ^ ": " ^ error)
           (codec.decode value) )
