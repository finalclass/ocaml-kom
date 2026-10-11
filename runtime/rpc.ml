open Yojson.Safe.Util

let rpc_error id code message =
  `Assoc
    [ ("jsonrpc", `String "2.0")
    ; ("id", id)
    ; ("error", `Assoc [("code", `Int code); ("message", `String message)]) ]

let rpc_one system request =
  try
    let fields = to_assoc request in
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
    then invalid_arg "Duplicate request key" ;
    let id = Option.value ~default:`Null (List.assoc_opt "id" fields) in
    if request |> member "jsonrpc" |> to_string <> "2.0"
    then invalid_arg "Expected JSON-RPC 2.0" ;
    ( match id with
    | `Null
     |`String _
     |`Int _
     |`Intlit _ ->
        ()
    | `Float value when Float.is_finite value -> ()
    | _ -> invalid_arg "Invalid request ID" ) ;
    let method_ = request |> member "method" |> to_string in
    let notification = not (List.mem_assoc "id" fields) in
    let response =
      try
        let params =
          Option.value ~default:(`Assoc []) (List.assoc_opt "params" fields)
        in
        ignore (to_assoc params) ;
        let result =
          if method_ = "kom.catalog"
          then Kom.System.catalog system
          else Kom.System.call system ~flow:method_ params
        in
        `Assoc [("jsonrpc", `String "2.0"); ("id", id); ("result", result)]
      with
      | Type_error (message, _) -> rpc_error id (-32602) message
      | Kom.Error error ->
          let code =
            match error.code with
            | "Flow" -> -32601
            | "Contract" -> -32602
            | "NotFound" -> -32004
            | _ -> -32000
          in
          rpc_error id code error.message
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> rpc_error id (-32603) "Internal error"
    in
    if notification then None else Some response
  with
  | Type_error _
   |Invalid_argument _ ->
      Some (rpc_error `Null (-32600) "Invalid request")

let rpc system body =
  try
    match Yojson.Safe.from_string body with
    | `List [] -> Some (rpc_error `Null (-32600) "Empty batch")
    | `List requests -> (
      match List.filter_map (rpc_one system) requests with
      | [] -> None
      | responses -> Some (`List responses) )
    | request -> rpc_one system request
  with
  | Yojson.Json_error _ -> Some (rpc_error `Null (-32700) "Parse error")
