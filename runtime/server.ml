open Yojson.Safe.Util

let read_req input =
  let invalid message = failwith ("Http.read_req: " ^ message) in
  let read_line () = Eio.Buf_read.line input in
  let request = read_line () in
  let meth, path =
    match String.split_on_char ' ' request with
    | [m; p; ("HTTP/1.0" | "HTTP/1.1")] when p <> "" -> (m, p)
    | _ -> invalid "invalid request line"
  in
  if meth <> "GET" && meth <> "POST" then invalid "unsupported method" ;
  let rec read_headers headers =
    match read_line () with
    | "" -> List.rev headers
    | line -> (
      match String.index_opt line ':' with
      | Some index when index > 0 ->
          let name = String.sub line 0 index in
          if name <> String.trim name then invalid "invalid header name" ;
          let value =
            String.sub line (index + 1) (String.length line - index - 1)
            |> String.trim
          in
          read_headers ((String.lowercase_ascii name, value) :: headers)
      | _ -> invalid "invalid header" )
  in
  let headers = read_headers [] in
  if List.mem_assoc "transfer-encoding" headers
  then invalid "unsupported Transfer-Encoding" ;
  let length =
    match
      List.filter_map
        (fun (name, value) ->
          if name = "content-length" then Some value else None )
        headers
    with
    | [] -> 0
    | [value]
      when value <> "" && String.for_all (fun c -> c >= '0' && c <= '9') value
      -> (
      match int_of_string_opt value with
      | Some length when length >= 0 && length <= 1_048_576 -> length
      | _ -> invalid "invalid Content-Length" )
    | _ -> invalid "invalid Content-Length"
  in
  let body = Eio.Buf_read.take length input in
  {Web.method_= meth; target= path; headers; body}

let send output (response : Web.response) =
  let reason =
    match response.status with
    | 200 -> "OK"
    | 204 -> "No Content"
    | 303 -> "See Other"
    | 400 -> "Bad Request"
    | 404 -> "Not Found"
    | 415 -> "Unsupported Media Type"
    | _ -> "Response"
  in
  let headers =
    ("Content-Length", string_of_int (String.length response.body))
    :: ("Connection", "close")
    :: response.headers
  in
  let valid text =
    not (String.contains text '\r' || String.contains text '\n')
  in
  if not (List.for_all (fun (key, value) -> valid key && valid value) headers)
  then invalid_arg "Invalid response header" ;
  Eio.Flow.copy_string
    (Printf.sprintf
       "HTTP/1.1 %d %s\r\n%s\r\n%s"
       response.status
       reason
       (String.concat
          ""
          (List.map (fun (key, value) -> key ^ ": " ^ value ^ "\r\n") headers) )
       response.body )
    output

let route runtime request =
  let path = Web.path request.Web.target in
  if String.starts_with ~prefix:"/apps/" path
  then
    let rest = String.sub request.target 6 (String.length request.target - 6) in
    let boundary =
      match String.index_opt rest '/' with
      | Some i -> i
      | None -> String.length (Web.path rest)
    in
    let app = String.sub rest 0 boundary in
    let base_path = "/apps/" ^ app in
    if boundary = String.length rest || rest.[boundary] = '?'
    then Web.redirect (base_path ^ "/")
    else
      Runtime_manager.handle
        runtime
        ~app
        ~base_path
        { request with
          target= String.sub rest boundary (String.length rest - boundary) }
  else
    match Runtime_manager.apps runtime |> to_list with
    | [app] ->
        Runtime_manager.handle
          runtime
          ~app:(app |> member "id" |> to_string)
          request
    | apps when path = "/" && request.method_ = "GET" ->
        Web.response
          ( "<!doctype html><title>Kom</title><h1>Applications</h1><ul>"
          ^ String.concat
              ""
              (List.map
                 (fun app ->
                   let id = app |> member "id" |> to_string in
                   "<li><a href=\"/apps/" ^ id ^ "/\">" ^ id ^ "</a></li>" )
                 apps )
          ^ "</ul>" )
    | _ -> Web.response ~status:404 "Not found"

let control runtime stop request =
  let string key = request |> member key |> to_string in
  match string "command" with
  | "status" ->
      `Assoc
        [("pid", `Int (Unix.getpid ())); ("apps", Runtime_manager.apps runtime)]
  | "add" -> `String (Runtime_manager.load runtime (string "source"))
  | "remove" ->
      Runtime_manager.remove runtime (string "app") ;
      `Null
  | "call" ->
      Runtime_manager.call
        runtime
        ~app:(string "app")
        ~flow:(string "flow")
        (member "message" request)
  | "put" ->
      File_access.import
        (Runtime_manager.files runtime ~app:(string "app"))
        (string "path")
        (string "source") ;
      `Null
  | "files" ->
      `List
        (List.map
           (fun path -> `String path)
           (File_access.list
              (Runtime_manager.files runtime ~app:(string "app")) ) )
  | "delete" ->
      File_access.delete
        (Runtime_manager.files runtime ~app:(string "app"))
        (string "path") ;
      `Null
  | "stop" ->
      stop () ;
      `Null
  | _ -> invalid_arg "Unknown control command"

let run ~sw ~net ~clock ~port runtime =
  let socket =
    Filename.concat runtime.Runtime_manager.root.root "control.sock"
  in
  ( try Unix.unlink socket with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> () ) ;
  let stop, stop_u = Eio.Promise.create () in
  let request_stop () =
    if not (Eio.Promise.is_resolved stop) then Eio.Promise.resolve stop_u ()
  in
  let http =
    Eio.Net.listen
      ~sw
      ~reuse_addr:true
      ~backlog:128
      net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let admin = Eio.Net.listen ~sw ~backlog:16 net (`Unix socket) in
  Unix.chmod socket 0o600 ;
  let old_term =
    Sys.signal Sys.sigterm (Sys.Signal_handle (fun _ -> request_stop ()))
  and old_int =
    Sys.signal Sys.sigint (Sys.Signal_handle (fun _ -> request_stop ()))
  in
  let on_error exn = prerr_endline (Printexc.to_string exn) in
  Fun.protect
    ~finally:(fun () ->
      Sys.set_signal Sys.sigterm old_term ;
      Sys.set_signal Sys.sigint old_int ;
      Runtime_manager.close runtime )
    (fun () ->
      Printf.printf "Kom: http://127.0.0.1:%d\n%!" port ;
      Eio.Fiber.both
        (fun () ->
          Eio.Net.run_server
            ~stop
            ~max_connections:128
            ~on_error
            http
            (fun client _ ->
              try
                let request =
                  Eio.Time.with_timeout_exn clock 10. (fun () ->
                      read_req (Eio.Buf_read.of_flow ~max_size:1_048_576 client) )
                in
                send client (route runtime request)
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | Kom.Error error ->
                  send
                    client
                    (Web.response
                       ~status:
                         ( if error.code = "NotFound" || error.code = "App"
                           then 404
                           else 400 )
                       ~content_type:"text/plain; charset=utf-8"
                       error.message )
              | _ -> send client (Web.response ~status:400 "Invalid request") ) )
        (fun () ->
          Eio.Net.run_server
            ~stop
            ~max_connections:16
            ~on_error
            admin
            (fun client _ ->
              let response =
                try
                  let request =
                    Eio.Time.with_timeout_exn clock 10. (fun () ->
                        Eio.Buf_read.line
                          (Eio.Buf_read.of_flow ~max_size:1_048_576 client) )
                    |> Yojson.Safe.from_string
                  in
                  `Assoc [("result", control runtime request_stop request)]
                with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | Kom.Error error ->
                    `Assoc
                      [("error", `String (error.code ^ ": " ^ error.message))]
                | exn -> `Assoc [("error", `String (Printexc.to_string exn))]
              in
              Eio.Flow.copy_string
                (Yojson.Safe.to_string response ^ "\n")
                client ) ) )
