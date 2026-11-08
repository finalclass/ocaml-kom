open Ppxlib

let error ~loc message = Location.raise_errorf ~loc "kom: %s" message

let cell_attr =
  Attribute.declare
    "kom.cell"
    Attribute.Context.module_binding
    Ast_pattern.__
    Fun.id

let cell_floating =
  Attribute.Floating.declare
    "kom.cell"
    Attribute.Floating.Context.structure_item
    Ast_pattern.__
    Fun.id

let kinds = ["transformer"; "expander"; "joiner"; "router"]

let op_attrs =
  List.map
    (fun kind ->
      ( kind
      , Attribute.declare
          ("kom." ^ kind)
          Attribute.Context.value_binding
          Ast_pattern.__
          Fun.id ) )
    kinds

let operation binding =
  match
    List.filter_map
      (fun (kind, attribute) ->
        Option.map
          (fun payload -> (kind, payload))
          (Attribute.get attribute binding) )
      op_attrs
  with
  | [] -> None
  | [op] -> Some op
  | _ ->
      error
        ~loc:binding.pvb_loc
        "a function can have only one operation attribute"

let options ~loc = function
  | PStr [] -> []
  | PStr
      [ { pstr_desc= Pstr_eval ({pexp_desc= Pexp_record (fields, None); _}, [])
        ; _ } ] ->
      let fields =
        List.map
          (fun (name, value) ->
            match name.txt with
            | Lident name -> (name, value)
            | _ -> error ~loc:name.loc "option names must be unqualified" )
          fields
      in
      let names = List.map fst fields in
      if List.length names <> List.length (List.sort_uniq String.compare names)
      then error ~loc "duplicate option" ;
      fields
  | _ ->
      error ~loc "expected an attribute record, for example { output = patch }"

let allowed ~loc names fields =
  List.iter
    (fun (name, _) ->
      if not (List.mem name names) then error ~loc ("unknown option: " ^ name) )
    fields

let string value =
  match value.pexp_desc with
  | Pexp_constant (Pconst_string (text, _, _)) when text <> "" -> text
  | _ -> error ~loc:value.pexp_loc "expected a nonempty string literal"

let rec strings value =
  match value.pexp_desc with
  | Pexp_construct ({txt= Lident "[]"; _}, None) -> []
  | Pexp_construct
      ({txt= Lident "::"; _}, Some {pexp_desc= Pexp_tuple [head; tail]; _}) ->
      string head :: strings tail
  | _ -> error ~loc:value.pexp_loc "expected a literal list of strings"

let name binding =
  match binding.pvb_pat.ppat_desc with
  | Ppat_var name -> name.txt
  | _ -> error ~loc:binding.pvb_loc "an operation must be a named function"

let module_type ty =
  match ty.ptyp_desc with
  | Ptyp_constr ({txt= Ldot (path, "t"); _}, []) ->
      String.concat "." (Longident.flatten_exn path)
  | _ ->
      error
        ~loc:ty.ptyp_loc
        "use an explicit module type such as Input.t or Output.t"

let unary expected ty =
  match ty.ptyp_desc with
  | Ptyp_constr ({txt= path; _}, [inner])
    when String.concat "." (Longident.flatten_exn path) = expected ->
      inner
  | _ -> error ~loc:ty.ptyp_loc ("expected " ^ expected ^ " type annotation")

let pair ty =
  match ty.ptyp_desc with
  | Ptyp_tuple [left; right] -> (left, right)
  | _ -> error ~loc:ty.ptyp_loc "expected a pair type annotation"

let parse ~loc source =
  let lexbuf = Lexing.from_string source in
  Location.init lexbuf loc.loc_start.pos_fname ;
  let items = Parse.implementation lexbuf in
  let mapper =
    object
      inherit Ast_traverse.map

      method! location _ = {loc with loc_ghost= true}
    end
  in
  mapper#structure items

let list_source xs =
  "[" ^ String.concat "; " (List.map (Printf.sprintf "%S") xs) ^ "]"

let generated binding kind payload =
  let loc = binding.pvb_loc in
  let fields = options ~loc payload in
  allowed ~loc ["id"; "output"; "remove"; "ports"] fields ;
  let policy =
    match List.assoc_opt "output" fields with
    | Some
        { pexp_desc=
            Pexp_ident
              {txt= Lident (("patch" | "fresh" | "patch_selected") as policy); _}
        ; _ } ->
        policy
    | _ -> error ~loc "specify output = patch, fresh or patch_selected"
  in
  if
    (kind = "joiner" && policy = "patch")
    || (kind <> "joiner" && policy = "patch_selected")
  then
    error
      ~loc
      "patch is for single-input operations; patch_selected is for Joiners" ;
  let remove = Option.map strings (List.assoc_opt "remove" fields) in
  if policy = "fresh" && remove <> None
  then error ~loc "fresh output cannot specify remove" ;
  if List.mem_assoc "ports" fields
  then
    error
      ~loc
      "ports are not declared here; a Router's result type lists them as \
       constructors of a [@@deriving kom_route] variant" ;
  let params, result =
    match binding.pvb_expr.pexp_desc with
    | Pexp_function (params, Some (Pconstraint result), _) -> (params, result)
    | _ ->
        error
          ~loc
          "annotate the function result as State.t * Output.t (including the \
           operation's list or port wrapper)"
  in
  let patterns =
    List.map
      (fun param ->
        match param.pparam_desc with
        | Pparam_val (Nolabel, None, pattern) -> pattern
        | _ ->
            error
              ~loc:param.pparam_loc
              "operations take three positional arguments: db, state, message" )
      params
  in
  let state, input =
    match patterns with
    | [ _
      ; {ppat_desc= Ppat_constraint (_, state); _}
      ; {ppat_desc= Ppat_constraint (_, input); _} ] ->
        (state, input)
    | _ ->
        error
          ~loc
          "annotate state and message arguments; expected db (state : State.t) \
           (msg : Input.t Kom.Msg.t)"
  in
  let state_module = module_type state in
  let input = if kind = "joiner" then unary "list" input else input in
  let input_module = module_type (unary "Kom.Msg.t" input) in
  let result_state, output = pair result in
  if module_type result_state <> state_module
  then error ~loc "input and result state annotations must name the same module" ;
  let output =
    match kind with
    | "expander" -> unary "list" output
    | "joiner" when policy = "patch_selected" ->
        let base, output = pair output in
        if module_type (unary "Kom.Msg.t" base) <> input_module
        then error ~loc "selected message must have the input type" ;
        output
    | _ -> output
  in
  let output_module = module_type output in
  let fn = name binding in
  let id =
    match List.assoc_opt "id" fields with
    | None -> fn
    | Some value -> string value
  in
  let policy = if kind = "router" then policy ^ "_route" else policy in
  let source =
    Printf.sprintf
      "let %s_operation = Kom.Cell.%s ~id:%S ~input:(module %s) \
       ~output:(Kom.Output.%s %s (module %s)) ~impl:%s"
      fn
      kind
      id
      input_module
      policy
      (Option.fold
         ~none:""
         ~some:(fun values -> "~remove:" ^ list_source values)
         remove )
      output_module
      fn
  in
  parse ~loc source

let remove_attrs names attrs =
  List.filter (fun attr -> not (List.mem attr.attr_name.txt names)) attrs

let binding_names items =
  let names = ref [] in
  let visitor =
    object (self)
      inherit Ast_traverse.iter

      method! pattern pattern =
        match pattern.ppat_desc with
        | Ppat_var name -> names := name.txt :: !names
        | _ -> self#pattern_desc pattern.ppat_desc
    end
  in
  List.iter
    (fun item ->
      match item.pstr_desc with
      | Pstr_value (_, bindings) ->
          List.iter (fun binding -> visitor#pattern binding.pvb_pat) bindings
      | Pstr_primitive value -> names := value.pval_name.txt :: !names
      | _ -> () )
    items ;
  !names

let floating_cell item =
  match item.pstr_desc with
  | Pstr_attribute _ ->
      Option.map
        (fun payload -> (item.pstr_loc, payload))
        (Attribute.Floating.convert [cell_floating] item)
  | _ -> None

let file_module loc =
  let name =
    loc.loc_start.pos_fname
    |> Filename.basename
    |> Filename.remove_extension
    |> String.capitalize_ascii
  in
  let ident c =
    match c with
    | 'A' .. 'Z'
     |'a' .. 'z'
     |'0' .. '9'
     |'_'
     |'\'' ->
        true
    | _ -> false
  in
  match name.[0] with
  | 'A' .. 'Z' when String.for_all ident name -> name
  | _
   |(exception Invalid_argument _) ->
      ""

let generated_cell ~loc ~payload ~default_id items =
  let fields = options ~loc payload in
  allowed ~loc ["id"] fields ;
  if List.mem "cell" (binding_names items)
  then error ~loc "the cell value is generated; remove the manual cell binding" ;
  let operations =
    List.concat_map
      (fun item ->
        match item.pstr_desc with
        | Pstr_value (_, bindings) ->
            List.filter_map
              (fun binding ->
                Option.map
                  (fun _ -> name binding ^ "_operation")
                  (operation binding) )
              bindings
        | _ -> [] )
      items
  in
  let states =
    List.filter
      (fun item ->
        match item.pstr_desc with
        | Pstr_module binding -> binding.pmb_name.txt = Some "State"
        | _ -> false )
      items
  in
  if List.length states <> 1
  then error ~loc "a cell must declare exactly one State module" ;
  let id =
    match List.assoc_opt "id" fields with
    | Some value -> string value
    | None when default_id <> "" -> default_id
    | None -> error ~loc "specify the cell id, for example { id = \"Cell\" }"
  in
  parse
    ~loc
    (Printf.sprintf
       "let cell = Kom.Cell.define {id=%S; state=(module State); \
        operations=[%s]}"
       id
       (String.concat "; " operations) )

let mapper =
  object (self)
    inherit Ast_traverse.map as super

    (* The name of the module whose structure is being traversed, or None at
       the top level of a compilation unit. *)
    val mutable scope : string option = None

    method! structure items =
      let cells, items =
        List.partition_map
          (fun item ->
            match floating_cell item with
            | Some cell -> Left cell
            | None -> Right item )
          items
      in
      let names = ref (binding_names items) in
      let processed =
        List.concat_map
          (fun item ->
            match item.pstr_desc with
            | Pstr_value (recursive, bindings) ->
                let operations =
                  List.filter_map
                    (fun binding ->
                      Option.map (fun op -> (binding, op)) (operation binding) )
                    bindings
                in
                if
                  operations <> []
                  && (recursive = Recursive || List.length bindings <> 1)
                then
                  error
                    ~loc:item.pstr_loc
                    "decorated operations must be separate, non-recursive let \
                     bindings" ;
                let extra =
                  List.concat_map
                    (fun (binding, (kind, payload)) ->
                      let generated_name = name binding ^ "_operation" in
                      if List.mem generated_name !names
                      then
                        error
                          ~loc:binding.pvb_loc
                          ("generated name already exists: " ^ generated_name) ;
                      names := generated_name :: !names ;
                      generated binding kind payload )
                    operations
                in
                let bindings =
                  List.map
                    (fun binding ->
                      { binding with
                        pvb_attributes=
                          remove_attrs
                            (List.map (fun kind -> "kom." ^ kind) kinds)
                            binding.pvb_attributes } )
                    bindings
                in
                super#structure_item
                  {item with pstr_desc= Pstr_value (recursive, bindings)}
                :: extra
            | _ -> [self#structure_item item] )
          items
      in
      match cells with
      | [] -> processed
      | [(loc, payload)] ->
          let default_id =
            match scope with
            | Some module_name -> module_name
            | None -> file_module loc
          in
          processed @ generated_cell ~loc ~payload ~default_id items
      | _ :: (loc, _) :: _ ->
          error ~loc "a module can declare only one kom.cell attribute"

    method! module_binding binding =
      let binding =
        match Attribute.get cell_attr binding with
        | None -> binding
        | Some payload -> (
            let loc = binding.pmb_loc in
            if binding.pmb_name.txt = None
            then error ~loc "cell modules must be named" ;
            match binding.pmb_expr.pmod_desc with
            | Pmod_structure items ->
                if List.exists (fun item -> floating_cell item <> None) items
                then
                  error
                    ~loc
                    "use either [@@kom.cell] on the module or [@@@kom.cell] \
                     inside it, not both" ;
                let floating =
                  Ast_builder.Default.pstr_attribute
                    ~loc
                    (Ast_builder.Default.attribute
                       ~loc
                       ~name:{txt= "kom.cell"; loc}
                       ~payload )
                in
                { binding with
                  pmb_attributes=
                    remove_attrs ["kom.cell"] binding.pmb_attributes
                ; pmb_expr=
                    { binding.pmb_expr with
                      pmod_desc= Pmod_structure (items @ [floating]) } }
            | _ ->
                error
                  ~loc
                  "kom.cell requires a direct module ... = struct ... end \
                   definition" )
      in
      let outer = scope in
      scope <- binding.pmb_name.txt ;
      Fun.protect
        ~finally:(fun () -> scope <- outer)
        (fun () -> super#module_binding binding)
  end

let () = Driver.register_transformation "kom.cells" ~impl:mapper#structure
