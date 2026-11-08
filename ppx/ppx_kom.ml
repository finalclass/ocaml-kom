open Ppxlib

let quoted = Printf.sprintf "%S"

let codec_name name = if name = "t" then "kom" else name ^ "_kom"

let fail ~loc message = Location.raise_errorf ~loc "deriving kom: %s" message

let path_name path = String.concat "." (Longident.flatten_exn path)

let codec_path path =
  let parts = Longident.flatten_exn path in
  String.concat
    "."
    (List.mapi
       (fun i name ->
         if i = List.length parts - 1 then codec_name name else name )
       parts )

let rec codec ty =
  let loc = ty.ptyp_loc in
  match ty.ptyp_desc with
  | Ptyp_var name -> name ^ "_kom"
  | Ptyp_constr ({txt= path; _}, args) ->
      let primitive =
        match (path_name path, args) with
        | (("string" | "int" | "float" | "bool" | "unit") as name), [] ->
            Some ("Kom.Codec." ^ name)
        | (("list" | "array" | "option") as name), [_] ->
            Some ("Kom.Codec." ^ name)
        | "Yojson.Safe.t", [] -> Some "Kom.Codec.json"
        | _ -> None
      in
      let name = Option.value ~default:(codec_path path) primitive in
      "(" ^ String.concat " " (name :: List.map codec args) ^ ")"
  | Ptyp_tuple types ->
      let names = List.mapi (fun i _ -> "item" ^ string_of_int i) types in
      let encodes =
        List.map2
          (fun name ty -> "Kom.Codec.encode " ^ codec ty ^ " " ^ name)
          names
          types
      in
      let decode =
        List.fold_right2
          (fun name ty next ->
            "Result.bind (Kom.Codec.decode "
            ^ codec ty
            ^ " "
            ^ name
            ^ ") (fun "
            ^ name
            ^ " -> "
            ^ next
            ^ ")" )
          names
          types
          ("Ok (" ^ String.concat ", " names ^ ")")
      in
      "(Kom.Codec.make ~schema:(Kom.Schema.Tuple ["
      ^ String.concat
          "; "
          (List.map (fun ty -> "Kom.Codec.schema " ^ codec ty) types)
      ^ "]) ~encode:(fun ("
      ^ String.concat ", " names
      ^ ") -> `List ["
      ^ String.concat "; " encodes
      ^ "]) ~decode:(function `List ["
      ^ String.concat "; " names
      ^ "] -> "
      ^ decode
      ^ " | _ -> Error \"Expected tuple\"))"
  | _ ->
      fail
        ~loc
        "supported types: records, variants, aliases, tuples, lists, arrays \
         and options"

let optional ty =
  match ty.ptyp_desc with
  | Ptyp_constr ({txt= Lident "option"; _}, [inner]) -> Some inner
  | _ -> None

let record fields =
  List.iter
    (fun field ->
      if field.pld_mutable = Mutable
      then fail ~loc:field.pld_loc "mutable fields are not supported" ;
      if field.pld_attributes <> []
      then
        fail
          ~loc:field.pld_loc
          "field attributes are not supported; use the OCaml field name as the \
           JSON key" )
    fields ;
  let schema =
    List.map
      (fun field ->
        let value = "Kom.Codec.schema " ^ codec field.pld_type in
        quoted field.pld_name.txt
        ^ ", "
        ^
        if optional field.pld_type = None
        then value
        else "Kom.Schema.Optional (" ^ value ^ ")" )
      fields
  in
  let encode =
    List.map
      (fun field ->
        quoted field.pld_name.txt
        ^ ", Kom.Codec.encode "
        ^ codec field.pld_type
        ^ " value."
        ^ field.pld_name.txt )
      fields
  in
  let decode =
    List.fold_right
      (fun field next ->
        let name = field.pld_name.txt in
        let decoder =
          match optional field.pld_type with
          | None -> "Kom.Codec.field " ^ codec field.pld_type
          | Some inner -> "Kom.Codec.optional_field " ^ codec inner
        in
        "Result.bind ("
        ^ decoder
        ^ " "
        ^ quoted name
        ^ " fields) (fun "
        ^ name
        ^ " -> "
        ^ next
        ^ ")" )
      fields
      ( "Ok {"
      ^ String.concat "; " (List.map (fun f -> f.pld_name.txt) fields)
      ^ "}" )
  in
  "Kom.Codec.make ~schema:(Kom.Schema.Object ["
  ^ String.concat "; " schema
  ^ "]) ~encode:(fun value -> `Assoc ["
  ^ String.concat "; " encode
  ^ "]) ~decode:(function `Assoc fields -> "
  ^ decode
  ^ " | _ -> Error \"Expected object\")"

let variant constructors =
  let parts =
    List.map
      (fun constructor ->
        if constructor.pcd_res <> None
        then fail ~loc:constructor.pcd_loc "GADT declarations are not supported" ;
        let types =
          match constructor.pcd_args with
          | Pcstr_tuple types -> types
          | Pcstr_record _ ->
              fail
                ~loc:constructor.pcd_loc
                "use a named record type for variant payloads"
        in
        let name = constructor.pcd_name.txt in
        let vars = List.mapi (fun i _ -> "arg" ^ string_of_int i) types in
        let pattern =
          name ^ if vars = [] then "" else " (" ^ String.concat ", " vars ^ ")"
        in
        let schema =
          quoted name
          ^ ", ["
          ^ String.concat
              "; "
              (List.map (fun ty -> "Kom.Codec.schema " ^ codec ty) types)
          ^ "]"
        in
        let encode =
          "| "
          ^ pattern
          ^ " -> `List ["
          ^ String.concat
              "; "
              ( ("`String " ^ quoted name)
              :: List.map2
                   (fun v ty -> "Kom.Codec.encode " ^ codec ty ^ " " ^ v)
                   vars
                   types )
          ^ "]"
        in
        let decode =
          List.fold_right2
            (fun v ty next ->
              "Result.bind (Kom.Codec.decode "
              ^ codec ty
              ^ " "
              ^ v
              ^ ") (fun "
              ^ v
              ^ " -> "
              ^ next
              ^ ")" )
            vars
            types
            ("Ok (" ^ pattern ^ ")")
        in
        ( schema
        , encode
        , "| `List ["
          ^ String.concat "; " (("`String " ^ quoted name) :: vars)
          ^ "] -> "
          ^ decode ) )
      constructors
  in
  "Kom.Codec.make ~schema:(Kom.Schema.Tagged ["
  ^ String.concat "; " (List.map (fun (s, _, _) -> s) parts)
  ^ "]) ~encode:(function "
  ^ String.concat " " (List.map (fun (_, e, _) -> e) parts)
  ^ ") ~decode:(function "
  ^ String.concat " " (List.map (fun (_, _, d) -> d) parts)
  ^ " | _ -> Error \"Unknown variant or invalid payload\")"

let declarations ~loc:_ ~path:_ (_, declarations) =
  let pending = ref (List.map (fun d -> d.ptype_name.txt) declarations) in
  List.concat_map
    (fun declaration ->
      let name = declaration.ptype_name.txt in
      let check =
        object
          inherit Ast_traverse.iter as super

          method! core_type ty =
            ( match ty.ptyp_desc with
            | Ptyp_constr ({txt= Lident referenced; _}, _)
              when List.mem referenced !pending ->
                fail
                  ~loc:ty.ptyp_loc
                  "recursive or forward-referenced types are not supported; \
                   declare dependencies first"
            | _ -> () ) ;
            super#core_type ty
        end
      in
      check#type_declaration declaration ;
      pending := List.filter (( <> ) name) !pending ;
      let params =
        List.map
          (fun (ty, _) ->
            match ty.ptyp_desc with
            | Ptyp_var name -> name
            | _ -> fail ~loc:ty.ptyp_loc "type parameters must be named" )
          declaration.ptype_params
      in
      let body =
        match (declaration.ptype_kind, declaration.ptype_manifest) with
        | Ptype_record fields, _ -> record fields
        | Ptype_variant constructors, _ -> variant constructors
        | Ptype_abstract, Some ty -> codec ty
        | _ ->
            fail
              ~loc:declaration.ptype_loc
              "abstract/open types cannot derive a codec"
      in
      let type_name =
        match params with
        | [] -> name
        | _ ->
            "("
            ^ String.concat ", " (List.map (fun p -> "'" ^ p) params)
            ^ ") "
            ^ name
      in
      let args =
        String.concat
          " "
          (List.map
             (fun p -> "(" ^ p ^ "_kom : '" ^ p ^ " Kom.Codec.t)")
             params )
      in
      let code =
        "let "
        ^ codec_name name
        ^ " "
        ^ args
        ^ " : "
        ^ type_name
        ^ " Kom.Codec.t = "
        ^ body
      in
      Parse.implementation (Lexing.from_string code) )
    declarations

let () =
  Deriving.add "kom" ~str_type_decl:(Deriving.Generator.make_noarg declarations)
  |> Deriving.ignore

let route_fail ~loc message =
  Location.raise_errorf ~loc "deriving kom_route: %s" message

let route_name name = if name = "t" then "route" else name ^ "_route"

(* A route is a variant whose constructors are a Router's ports. Each carries
   at most one payload: that port's output record. *)
let route_declarations ~loc:_ ~path:_ (_, declarations) =
  List.concat_map
    (fun declaration ->
      let loc = declaration.ptype_loc in
      let constructors =
        match (declaration.ptype_kind, declaration.ptype_params) with
        | Ptype_variant (_ :: _ as constructors), [] -> constructors
        | Ptype_variant _, [] ->
            route_fail ~loc "a route needs at least one constructor"
        | Ptype_variant _, _ ->
            route_fail ~loc "route types cannot have type parameters"
        | _ -> route_fail ~loc "deriving kom_route requires a variant type"
      in
      let ports =
        List.map
          (fun constructor ->
            let loc = constructor.pcd_loc in
            if constructor.pcd_res <> None
            then route_fail ~loc "GADT declarations are not supported" ;
            match constructor.pcd_args with
            | Pcstr_tuple [] -> (constructor.pcd_name.txt, None)
            | Pcstr_tuple [ty] -> (constructor.pcd_name.txt, Some ty)
            | _ ->
                route_fail
                  ~loc
                  "a route constructor carries at most one named record payload" )
          constructors
      in
      let contract (name, ty) =
        Printf.sprintf
          "(%S, %s)"
          name
          ( match ty with
          | None -> "[]"
          | Some ty -> "Kom.Codec.fields " ^ codec ty )
      in
      let split (name, ty) =
        match ty with
        | None -> Printf.sprintf "| %s -> (%S, `Assoc [])" name name
        | Some ty ->
            Printf.sprintf
              "| %s arg -> (%S, Kom.Codec.encode %s arg)"
              name
              name
              (codec ty)
      in
      let name = declaration.ptype_name.txt in
      let code =
        Printf.sprintf
          "let %s : %s Kom.Route.t = Kom.Route.define [%s] (function %s)"
          (route_name name)
          name
          (String.concat "; " (List.map contract ports))
          (String.concat " " (List.map split ports))
      in
      Parse.implementation (Lexing.from_string code) )
    declarations

let () =
  Deriving.add
    "kom_route"
    ~str_type_decl:(Deriving.Generator.make_noarg route_declarations)
  |> Deriving.ignore

let () = ignore Cell_deriver.mapper

module Cell_deriver = Cell_deriver
