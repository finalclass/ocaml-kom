let common =
  {|
module I = struct
  type t = {user: string}
  let kom = Kom.Codec.make ~schema:(Kom.Schema.Object ["user", String])
    ~encode:(fun value -> `Assoc ["user", `String value.user])
    ~decode:(fun _ -> Ok {user="test"})
end
module O = struct
  type t = {greeting: string}
  let kom = Kom.Codec.make ~schema:(Kom.Schema.Object ["greeting", String])
    ~encode:(fun value -> `Assoc ["greeting", `String value.greeting])
    ~decode:(fun _ -> Ok {greeting="test"})
end
|}

let examples =
  [ ( true
    , {|
let op : int Kom.Cell.operation = Kom.Cell.transformer ~id:"greet"
  ~input:(module I) ~output:(Kom.Output.patch (module O))
  ~impl:(fun _db state msg -> state, O.{greeting=(Kom.Msg.data msg).I.user})
|}
    )
  ; ( false
    , {|
let op : int Kom.Cell.operation = Kom.Cell.transformer ~id:"greet"
  ~input:(module I) ~output:(Kom.Output.patch (module O))
  ~impl:(fun _db state msg -> state, Kom.Msg.data msg)
|}
    )
  ; ( false
    , {|
let op : int Kom.Cell.operation = Kom.Cell.transformer ~id:"greet"
  ~input:(module I) ~output:(Kom.Output.patch (module O))
  ~impl:(fun _db state (_msg : O.t Kom.Msg.t) -> state, O.{greeting="x"})
|}
    )
  ; ( false
    , {|
let op : int Kom.Cell.operation = Kom.Cell.joiner ~id:"join"
  ~input:(module I) ~output:(Kom.Output.patch (module O))
  ~impl:(fun _db state _messages -> state, O.{greeting="x"})
|}
    )
  ; ( false
    , {|
let op : int Kom.Cell.operation = Kom.Cell.transformer ~id:"greet"
  ~input:(module I) ~output:(Kom.Output.patch_selected (module O))
  ~impl:(fun _db state msg -> state, (msg, O.{greeting="x"}))
|}
    ) ]

let () =
  let compiler = Sys.argv.(1) in
  let includes =
    ["-I"; Filename.dirname Sys.argv.(2); "-I"; Filename.dirname Sys.argv.(3)]
  in
  List.iter
    (fun (success, source) ->
      let file = Filename.temp_file "kom_contract_" ".ml" in
      let log = file ^ ".log" in
      Fun.protect
        ~finally:(fun () ->
          List.iter
            (fun path -> if Sys.file_exists path then Sys.remove path)
            [ file
            ; log
            ; Filename.chop_extension file ^ ".cmi"
            ; Filename.chop_extension file ^ ".cmo" ] )
        (fun () ->
          let output = open_out file in
          output_string output (common ^ source) ;
          close_out output ;
          let fd =
            Unix.openfile log [Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC] 0o600
          in
          let args = Array.of_list ((compiler :: includes) @ ["-c"; file]) in
          let pid = Unix.create_process compiler args Unix.stdin fd fd in
          Unix.close fd ;
          let _, status = Unix.waitpid [] pid in
          if status = Unix.WEXITED 0 <> success
          then (
            let input = open_in log in
            let details = really_input_string input (in_channel_length input) in
            close_in input ;
            failwith ("Unexpected compiler result: " ^ details) ) ) )
    examples ;
  print_endline "PASS compile-time input/output and output-mode constraints"
