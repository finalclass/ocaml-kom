type value =
  | String of string
  | List of string list

type params = (string * value) list

type node =
  | Text of string
  | Variable of string
  | If of string * node list
  | Loop of string * node list

let parse source ~(params : params) =
  let length = String.length source in
  let starts_with index token =
    let token_length = String.length token in
    index + token_length <= length
    && String.sub source index token_length = token
  in
  let rec find_end index =
    if index + 1 >= length
    then None
    else if source.[index] = '}' && source.[index + 1] = '}'
    then Some index
    else find_end (index + 1)
  in
  let rec read_nodes start nested =
    let text = Buffer.create 32 in
    let flush nodes =
      if Buffer.length text = 0
      then nodes
      else
        let node = Text (Buffer.contents text) in
        Buffer.clear text ;
        node :: nodes
    in
    let rec loop index nodes =
      if index >= length
      then
        if nested
        then invalid_arg "Template.parse: missing {end}"
        else (List.rev (flush nodes), index)
      else if starts_with index "{{"
      then (
        match find_end (index + 2) with
        | Some finish ->
            let name = String.sub source (index + 2) (finish - index - 2) in
            loop (finish + 2) (Variable name :: flush nodes)
        | None ->
            Buffer.add_substring text source index (length - index) ;
            loop length nodes )
      else if starts_with index "{end}"
      then
        if nested
        then (List.rev (flush nodes), index + 5)
        else (
          Buffer.add_string text "{end}" ;
          loop (index + 5) nodes )
      else if starts_with index "{if " || starts_with index "{loop "
      then (
        let is_if = starts_with index "{if " in
        let name_start = index + if is_if then 4 else 6 in
        match String.index_from_opt source name_start '}' with
        | None ->
            Buffer.add_substring text source index (length - index) ;
            loop length nodes
        | Some finish ->
            let name =
              String.sub source name_start (finish - name_start) |> String.trim
            in
            if name = ""
            then invalid_arg "Template.parse: missing variable name" ;
            let body, next = read_nodes (finish + 1) true in
            let node = if is_if then If (name, body) else Loop (name, body) in
            loop next (node :: flush nodes) )
      else (
        Buffer.add_char text source.[index] ;
        loop (index + 1) nodes )
    in
    loop start []
  in
  let nodes, _ = read_nodes 0 false in
  let output = Buffer.create length in
  let rec render params nodes =
    List.iter
      (function
        | Text text -> Buffer.add_string output text
        | Variable name -> (
          match List.assoc_opt name params with
          | Some (String value) -> Buffer.add_string output value
          | Some (List _)
           |None ->
              Buffer.add_string output ("{{" ^ name ^ "}}") )
        | If (name, body) -> (
          match List.assoc_opt name params with
          | Some (String value) when value <> "" -> render params body
          | Some (List (_ :: _)) -> render params body
          | _ -> () )
        | Loop (name, body) -> (
          match List.assoc_opt name params with
          | Some (List items) ->
              List.iter
                (fun item -> render (("item", String item) :: params) body)
                items
          | _ -> () ) )
      nodes
  in
  render params nodes ;
  Buffer.contents output
