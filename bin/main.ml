open Yojson.Safe.Util
module Runtime = Kom_runtime.Runtime

let absolute path =
  if Filename.is_relative path
  then Filename.concat (Sys.getcwd ()) path
  else path

let read_json path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () -> Yojson.Safe.from_channel input)

let write_json path json =
  let temporary = path ^ ".tmp" in
  let output = open_out_bin temporary in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () ->
      Yojson.Safe.to_channel output json ;
      flush output ;
      Unix.fsync (Unix.descr_of_out_channel output) ;
      close_out output ;
      Unix.rename temporary path )

let control env directory fields =
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.connect
      ~sw
      (Eio.Stdenv.net env)
      (`Unix (Filename.concat directory "control.sock"))
  in
  Eio.Flow.copy_string (Yojson.Safe.to_string (`Assoc fields) ^ "\n") socket ;
  let response =
    Eio.Buf_read.line (Eio.Buf_read.of_flow ~max_size:1_048_576 socket)
    |> Yojson.Safe.from_string
  in
  match member "error" response with
  | `String error -> failwith error
  | _ -> member "result" response

let status env directory =
  try Some (control env directory [("command", `String "status")]) with
  | Unix.Unix_error _
   |Eio.Io _ ->
      None

let wait ?timeout env condition =
  let loop () =
    while not (condition ()) do
      Eio.Time.sleep (Eio.Stdenv.clock env) 0.05
    done
  in
  match timeout with
  | None -> loop ()
  | Some seconds ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) seconds loop

let released directory =
  if Sys.file_exists (Filename.concat directory "control.sock")
  then false
  else
    let fd =
      Unix.openfile (Filename.concat directory "runtime.lock") [Unix.O_RDWR] 0
    in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        try
          Unix.lockf fd Unix.F_TLOCK 0 ;
          true
        with
        | Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> false )

let () =
  let directory = ref "kom-data"
  and port = ref None
  and foreground = ref false
  and workers = ref None
  and plugin = ref None
  and assets = ref None
  and args = ref [] in
  Arg.parse
    [ ( "--directory"
      , Arg.Set_string directory
      , "Runtime directory (default kom-data)" )
    ; ( "--port"
      , Arg.Int (fun n -> port := Some n)
      , "Loopback HTTP port (default 8080)" )
    ; ( "--workers"
      , Arg.Int (fun n -> workers := Some n)
      , "Worker domains per application" )
    ; ("--foreground", Arg.Set foreground, "Run in foreground")
    ; ( "--plugin"
      , Arg.String (fun path -> plugin := Some path)
      , "Load a plugin before serving" )
    ; ( "--assets"
      , Arg.String (fun path -> assets := Some path)
      , "Import Todo assets for --plugin" ) ]
    (fun arg -> args := !args @ [arg])
    "kom [--directory DIR] start|stop|restart|add plugin FILE|remove \
     APP|apps|call APP FLOW JSON|put APP PATH FILE|files APP|delete APP PATH" ;
  let directory = absolute !directory in
  let run env =
    let start ~serve =
      if (not serve) && status env directory <> None
      then failwith "Runtime is already running" ;
      let config =
        try read_json (Filename.concat directory "config.json") with
        | Sys_error _ -> `Assoc []
      in
      let number override field default =
        Option.value
          ~default:
            ( match member field config with
            | `Int value -> value
            | _ -> default )
          override
      in
      let port = number !port "port" 8080
      and workers = number !workers "workers" 4 in
      if port < 1 || port > 65535 || workers < 1
      then invalid_arg "Invalid port or worker count" ;
      if serve || !foreground
      then (
        Eio.Switch.run @@ fun sw ->
        let runtime =
          Runtime.create
            ~sw
            ~domain_mgr:(Eio.Stdenv.domain_mgr env)
            ~directory
            ~workers
            ()
        in
        write_json
          (Filename.concat directory "config.json")
          (`Assoc [("port", `Int port); ("workers", `Int workers)]) ;
        Option.iter
          (fun source ->
            let app = Runtime.load runtime (absolute source) in
            Option.iter
              (fun source ->
                List.iter
                  (fun name ->
                    let input = open_in_bin (Filename.concat source name) in
                    let body =
                      Fun.protect
                        ~finally:(fun () -> close_in input)
                        (fun () ->
                          really_input_string input (in_channel_length input) )
                    in
                    Kom_runtime.Files.write
                      (Runtime.files runtime ~app)
                      name
                      body )
                  ["index.html"; "task.html"; "app.js"] )
              !assets )
          !plugin ;
        Runtime.serve
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~clock:(Eio.Stdenv.clock env)
          ~port
          runtime )
      else
        let child_args =
          [ Sys.executable_name
          ; "serve"
          ; "--directory"
          ; directory
          ; "--port"
          ; string_of_int port
          ; "--workers"
          ; string_of_int workers ]
          @ Option.fold
              ~none:[]
              ~some:(fun path -> ["--plugin"; absolute path])
              !plugin
          @ Option.fold
              ~none:[]
              ~some:(fun path -> ["--assets"; absolute path])
              !assets
        in
        (* The child claims the directory before writing configuration or opening HTTP. *)
        if not (Sys.file_exists directory) then Unix.mkdir directory 0o700 ;
        let log =
          Unix.openfile
            (Filename.concat directory "runtime.log")
            [Unix.O_CREAT; Unix.O_APPEND; Unix.O_WRONLY]
            0o600
        in
        let null = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
        let pid =
          Fun.protect
            ~finally:(fun () ->
              Unix.close log ;
              Unix.close null )
            (fun () ->
              Unix.create_process
                Sys.executable_name
                (Array.of_list child_args)
                null
                log
                log )
        in
        ( try
            wait ~timeout:15. env (fun () ->
                match Unix.waitpid [Unix.WNOHANG] pid with
                | 0, _ -> status env directory <> None
                | _ ->
                    failwith
                      ( "Runtime failed to start; see "
                      ^ Filename.concat directory "runtime.log" ) )
          with
        | exn ->
            ( try Unix.kill pid Sys.sigterm with
            | Unix.Unix_error _ -> () ) ;
            raise exn ) ;
        Printf.printf "Kom started (PID %d), http://127.0.0.1:%d\n%!" pid port
    in
    let stop () =
      ignore (control env directory [("command", `String "stop")]) ;
      wait env (fun () -> released directory)
    in
    let send fields =
      control env directory fields
      |> Yojson.Safe.pretty_to_string
      |> print_endline
    in
    match !args with
    | ["start"] -> start ~serve:false
    | ["serve"] -> start ~serve:true
    | ["stop"] -> stop ()
    | ["restart"] ->
        stop () ;
        start ~serve:false
    | ["add"; "plugin"; source] ->
        send [("command", `String "add"); ("source", `String (absolute source))]
    | ["remove"; app] ->
        send [("command", `String "remove"); ("app", `String app)]
    | ["apps"] -> send [("command", `String "status")]
    | ["call"; app; flow; message] ->
        send
          [ ("command", `String "call")
          ; ("app", `String app)
          ; ("flow", `String flow)
          ; ("message", Yojson.Safe.from_string message) ]
    | ["put"; app; path; source] ->
        send
          [ ("command", `String "put")
          ; ("app", `String app)
          ; ("path", `String path)
          ; ("source", `String (absolute source)) ]
    | ["files"; app] -> send [("command", `String "files"); ("app", `String app)]
    | ["delete"; app; path] ->
        send
          [ ("command", `String "delete")
          ; ("app", `String app)
          ; ("path", `String path) ]
    | _ -> invalid_arg "Unknown command; run kom --help"
  in
  if !args = ["serve"] then ignore (Unix.setsid ()) ;
  try Eio_main.run run with
  | exn ->
      prerr_endline (Printexc.to_string exn) ;
      exit 1
