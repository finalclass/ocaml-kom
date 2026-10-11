open Yojson.Safe.Util
module Todo = System
open Kom

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

let serve system index_page task_page script request output =
  let path = List.hd (String.split_on_char '?' request.Http.path) in
  match (request.method_, path) with
  | "GET", "/" ->
      let query =
        match String.split_on_char '?' request.path with
        | [_; query] -> Http.parse_payload query
        | _ -> []
      in
      let finished = List.assoc_opt "finished" query = Some "1" in
      let params =
        List.filter_map
          (fun (name, value) ->
            match (name, value) with
            | ("min_priority" | "max_priority" | "limit"), value
              when value <> "" ->
                Some (name, `Int (int_of_string value))
            | "cursor", value when value <> "" -> Some (name, `String value)
            | _ -> None )
          query
      in
      let params =
        if List.mem_assoc "limit" params
        then params
        else ("limit", `Int 20) :: params
      in
      let result =
        Kom.System.call
          system
          ~flow:(if finished then "list_finished_tasks" else "list_tasks")
          (`Assoc params)
      in
      let encode text =
        String.concat
          ""
          (List.init (String.length text) (fun i ->
               Printf.sprintf "%%%02X" (Char.code text.[i]) ) )
      in
      let next_url =
        match member "cursor" result with
        | `String cursor ->
            `String
              ( "/?"
              ^ String.concat
                  "&"
                  (List.map
                     (fun (name, value) -> encode name ^ "=" ^ encode value)
                     (("cursor", cursor) :: List.remove_assoc "cursor" query) )
              )
        | _ -> `Null
      in
      let page =
        `Assoc
          ( ("next_url", next_url)
          :: ("finished", `Bool finished)
          :: to_assoc result )
      in
      Mustache.render
        ~strict:true
        index_page
        (Ezjsonm.from_string (Yojson.Safe.to_string page))
      |> Http.send_string ~output
  | "GET", "/app.js" ->
      Http.send_string
        ~content_type:"application/javascript; charset=utf-8"
        ~output
        script
  | "GET", "/catalog" ->
      Http.send_string
        ~content_type:"application/json"
        ~output
        (Yojson.Safe.to_string (Kom.System.catalog system))
  | "GET", path when String.starts_with ~prefix:"/tasks/" path ->
      let task_id = String.sub path 7 (String.length path - 7) in
      let task =
        Kom.System.call
          system
          ~flow:"read_task"
          (`Assoc [("task_id", `String task_id)])
      in
      Mustache.render
        ~strict:true
        task_page
        (Ezjsonm.from_string (Yojson.Safe.to_string task))
      |> Http.send_string ~output
  | "POST", "/rpc" -> (
      let content_type =
        Option.value ~default:"" (List.assoc_opt "content-type" request.headers)
        |> String.split_on_char ';'
        |> List.hd
        |> String.trim
        |> String.lowercase_ascii
      in
      if content_type <> "application/json"
      then
        Http.send_string
          ~status:"415 Unsupported Media Type"
          ~output
          "Expected application/json"
      else
        match rpc system request.body with
        | None -> Http.send_string ~status:"204 No Content" ~output ""
        | Some response ->
            Http.send_string
              ~content_type:"application/json"
              ~output
              (Yojson.Safe.to_string response) )
  | "POST", (("/add_task" | "/remove_task" | "/update_task") as path) ->
      let params =
        Http.parse_payload request.body
        |> List.map (fun (name, value) ->
            ( name
            , match name with
              | "priority" -> `Int (int_of_string value)
              | "done" -> `Bool (value = "true" || value = "on")
              | _ -> `String value ) )
        |> fun fields -> `Assoc fields
      in
      let flow = String.sub path 1 (String.length path - 1) in
      let params =
        if flow = "update_task" && member "done" params = `Null
        then `Assoc (("done", `Bool false) :: to_assoc params)
        else params
      in
      ignore (Kom.System.call system ~flow params) ;
      Http.redirect ~output "/"
  | _ ->
      Http.send_string ~status:"404 Not Found" ~output "Nie znaleziono strony"

let () =
  let port = ref 8080
  and database = ref "todo.sqlite"
  and assets = ref "examples" in
  Arg.parse
    [ ("--port", Arg.Set_int port, "HTTP port")
    ; ("--db", Arg.Set_string database, "SQLite database")
    ; ("--assets", Arg.Set_string assets, "Directory with HTML and JavaScript")
    ]
    (fun _ -> raise (Arg.Bad "Unexpected argument"))
    "Kom Todo MPA" ;
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let index_page =
    Eio.Path.(load (Eio.Stdenv.cwd env / Filename.concat !assets "index.html"))
    |> Mustache.of_string
  and task_page =
    Eio.Path.(load (Eio.Stdenv.cwd env / Filename.concat !assets "task.html"))
    |> Mustache.of_string
  and script =
    Eio.Path.(load (Eio.Stdenv.cwd env / Filename.concat !assets "app.js"))
  in
  let system =
    Todo.create
      ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~database:!database
      ()
  in
  let server =
    Eio.Net.listen
      ~sw
      ~reuse_addr:true
      ~backlog:32
      (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, !port))
  in
  let stop, stop_u = Eio.Promise.create () in
  let request_stop _ =
    if not (Eio.Promise.is_resolved stop) then Eio.Promise.resolve stop_u ()
  in
  let old_term = Sys.signal Sys.sigterm (Sys.Signal_handle request_stop)
  and old_int = Sys.signal Sys.sigint (Sys.Signal_handle request_stop) in
  Printf.printf "Todo: http://127.0.0.1:%d\n%!" !port ;
  Fun.protect
    (fun () ->
      Eio.Net.run_server
        ~stop
        ~max_connections:128
        ~on_error:(fun exn -> prerr_endline (Printexc.to_string exn))
        server
        (fun client _ ->
          let input = Eio.Buf_read.of_flow ~max_size:1_048_576 client in
          try
            let request =
              Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10. (fun () ->
                  Http.read_req input )
            in
            serve system index_page task_page script request client
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | Kom.Error error ->
              let status =
                if error.code = "NotFound"
                then "404 Not Found"
                else "400 Bad Request"
              in
              Http.send_string
                ~status
                ~output:client
                (Mustache.escape_html error.message)
          | _ ->
              Http.send_string
                ~status:"400 Bad Request"
                ~output:client
                "Invalid request" ) )
    ~finally:(fun () ->
      Sys.set_signal Sys.sigterm old_term ;
      Sys.set_signal Sys.sigint old_int ;
      Kom.System.close system )
