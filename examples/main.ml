let tasks : string list ref = ref []

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

module TasksIndex = struct
  let init () = [] 

  let on state msg = function
    | "index" -> (msg.task :: state, msg)
    | "list" -> (state, (msg with tasks = state))
    | _ -> failwith "not implemented"
end

module Task = struct
  let init () = ""

  let on state = function
    | "init" -> (msg.task, msg)
  end

let () =
  let server = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt server Unix.SO_REUSEADDR true ;
  Unix.bind server (Unix.ADDR_INET (Unix.inet_addr_loopback, 8080)) ;
  Unix.listen server 10 ;
  let html = read_file "./examples/index.html" in

  Kom.System.define
    ~flows:
      Kom.Flow.
        [ on "init" (new_cell ~id:"tasks_index" (module TasksIndex))
        ; on
            "add"
            (sequence
               [ new_cell ~id:"task.{$.index}" (module Task)
                   ; step ~cell:"task.{$.index}" ~operation:"init"
               ; step ~cell:"tasks_index" ~operation:"index" ] ) ] ;

  while true do
    let client, _ = Unix.accept server in
    let input = Unix.in_channel_of_descr client in
    let output = Unix.out_channel_of_descr client in
    let req = Http.read_req input in

    match req with
    | Http.Get target -> (
        let path, params =
          match String.index_opt target '?' with
          | None -> (target, [])
          | Some index ->
              ( String.sub target 0 index
              , Http.parse_payload
                  (String.sub
                     target
                     (index + 1)
                     (String.length target - index - 1) ) )
        in
        match path with
        | "/" ->
            html
            |> Template.parse ~params:[("todo", Template.List !tasks)]
            |> Http.send_string ~output
        | "/add-task" ->
            ( match List.assoc_opt "task" params with
            | Some task when task <> "" -> tasks := !tasks @ [task]
            | _ -> () ) ;
            Http.redirect ~output "/"
        | _ -> Http.send_string ~status:"404 Not Found" ~output "Not found" )
    | Http.Post _ -> failwith "not supported yet"
  done
