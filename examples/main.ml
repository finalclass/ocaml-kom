module Todo = System
open Kom
let read_file path =
  let input = open_in_bin path in
  Fun.protect (fun () -> really_input_string input (in_channel_length input))
    ~finally:(fun () -> close_in input)

let rpc_error id code message =
  `Assoc ["jsonrpc", `String "2.0"; "id", id;
    "error", `Assoc ["code", `Int code; "message", `String message]]
let rpc_one system request =
  try
    let fields = Json.fields request in
    let id = Option.value ~default:`Null (List.assoc_opt "id" fields) in
    if Json.get_string "jsonrpc" request <> "2.0" then raise (Json.Error "Expected JSON-RPC 2.0");
    (match id with `Null | `String _ | `Int _ | `Intlit _ | `Float _ -> ()
     | _ -> raise (Json.Error "Invalid request ID"));
    let method_ = Json.get_string "method" request in
    let notification = not (List.mem_assoc "id" fields) in
    let response =
      try
        let params = Option.value ~default:(`Assoc []) (List.assoc_opt "params" fields) in
        ignore (Json.fields params);
        let result = if method_ = "kom.catalog" then Kom.System.catalog system
          else Kom.System.call system ~flow:method_ params in
        `Assoc ["jsonrpc", `String "2.0"; "id", id; "result", result]
      with
      | Json.Error message -> rpc_error id (-32602) message
      | Kom.Error error ->
          let code = match error.code with "Flow" -> -32601 | "Contract" -> -32602 | "NotFound" -> -32004 | _ -> -32000 in
          rpc_error id code error.message
      | _ -> rpc_error id (-32603) "Internal error"
    in
    if notification then None else Some response
  with Json.Error _ -> Some (rpc_error `Null (-32600) "Invalid request")
let rpc system body =
  try
    match Json.of_string body with
    | `List [] -> Some (rpc_error `Null (-32600) "Empty batch")
    | `List requests ->
        (match List.filter_map (rpc_one system) requests with [] -> None | responses -> Some (`List responses))
    | request -> rpc_one system request
  with Json.Error _ -> Some (rpc_error `Null (-32700) "Parse error")

let task_params task = [
  "task_id", Template.String (Json.get_string "task_id" task);
  "name", Template.String (Json.get_string "name" task);
]
let serve system index_page task_page script request output =
  let path = List.hd (String.split_on_char '?' request.Http.path) in
  match request.method_, path with
  | "GET", "/" ->
      let result = Kom.System.call system ~flow:"list_tasks" (`Assoc []) in
      Template.parse index_page ~params:["tasks", Template.List (List.map task_params (Json.get_list "tasks" result))]
      |> Http.send_string ~output
  | "GET", "/app.js" ->
      Http.send_string ~content_type:"application/javascript; charset=utf-8" ~output script
  | "GET", "/catalog" ->
      Http.send_string ~content_type:"application/json" ~output (Json.to_string (Kom.System.catalog system))
  | "GET", path when String.starts_with ~prefix:"/tasks/" path ->
      let task_id = String.sub path 7 (String.length path - 7) in
      let task = Kom.System.call system ~flow:"read_task"
        (`Assoc ["task_id", `String task_id]) in
      Template.parse task_page ~params:(task_params task) |> Http.send_string ~output
  | "POST", "/rpc" ->
      let content_type = Option.value ~default:"" (List.assoc_opt "content-type" request.headers)
        |> String.split_on_char ';' |> List.hd |> String.trim |> String.lowercase_ascii in
      if content_type <> "application/json" then
        Http.send_string ~status:"415 Unsupported Media Type" ~output "Expected application/json"
      else
        (match rpc system request.body with
         | None -> Http.send_string ~status:"204 No Content" ~output ""
         | Some response -> Http.send_string ~content_type:"application/json" ~output (Json.to_string response))
  | "POST", ("/add_task" | "/remove_task" as path) ->
      let params = Http.parse_payload request.body
        |> List.map (fun (name, value) -> name, `String value) |> (fun fields -> `Assoc fields) in
      let flow = String.sub path 1 (String.length path - 1) in
      ignore (Kom.System.call system ~flow params);
      Http.redirect ~output "/"
  | _ -> Http.send_string ~status:"404 Not Found" ~output "Nie znaleziono strony"

let () =
  let port = ref 8080 and database = ref "todo.sqlite" and assets = ref "examples" in
  Arg.parse [
    "--port", Arg.Set_int port, "HTTP port";
    "--db", Arg.Set_string database, "SQLite database";
    "--assets", Arg.Set_string assets, "Directory with HTML and JavaScript";
  ] (fun _ -> raise (Arg.Bad "Unexpected argument")) "Kom Todo MPA";
  let index_page = read_file (Filename.concat !assets "index.html")
  and task_page = read_file (Filename.concat !assets "task.html")
  and script = read_file (Filename.concat !assets "app.js") in
  let system = Todo.create ~database:!database () in
  let server = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt server Unix.SO_REUSEADDR true;
  Unix.bind server (Unix.ADDR_INET (Unix.inet_addr_loopback, !port));
  Unix.listen server 32;
  let running = ref true and socket_open = ref true in
  let close_socket () = if !socket_open then (
    socket_open := false; Unix.close server) in
  let stop _ = running := false; close_socket () in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle stop);
  Sys.set_signal Sys.sigint (Sys.Signal_handle stop);
  Printf.printf "Todo: http://127.0.0.1:%d\n%!" !port;
  Fun.protect (fun () ->
    while !running do
      try
        let client, _ = Unix.accept server in
        Unix.setsockopt_float client Unix.SO_RCVTIMEO 10.;
        ignore (Thread.create (fun client ->
          let input = Unix.in_channel_of_descr client
          and output = Unix.out_channel_of_descr (Unix.dup client) in
          Fun.protect (fun () ->
            try serve system index_page task_page script (Http.read_req input) output
            with
            | Kom.Error error ->
                let status = if error.code = "NotFound" then "404 Not Found" else "400 Bad Request" in
                (try Http.send_string ~status ~output (Template.escape error.message) with _ -> ())
            | _ -> (try Http.send_string ~status:"400 Bad Request" ~output "Invalid request" with _ -> ()))
            ~finally:(fun () -> close_in_noerr input; close_out_noerr output)) client)
      with
      | Unix.Unix_error ((Unix.EBADF | Unix.EINTR | Unix.EINVAL), _, _) when not !running -> ()
    done) ~finally:(fun () -> close_socket (); Kom.System.close system)
