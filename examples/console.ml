let words line =
  line
  |> String.trim
  |> String.map (function
    | '\t' -> ' '
    | c -> c )
  |> String.split_on_char ' '
  |> List.filter (fun word -> word <> "")

let run env system =
  let input =
    Eio.Buf_read.of_flow ~max_size:Sys.max_string_length (Eio.Stdenv.stdin env)
  in
  let call operation address message =
    if address <> "a" && address <> "b"
    then invalid_arg "Unknown counter: expected a or b" ;
    let result =
      Kom.System.call system ~flow:(operation ^ "_" ^ address) message
    in
    let value = Yojson.Safe.Util.(result |> member "value" |> to_int) in
    Eio.Flow.copy_string (string_of_int value ^ "\n") (Eio.Stdenv.stdout env)
  in
  let command line =
    try
      match words line with
      | ["quit"] -> false
      | ["add"; address; amount] ->
          let amount =
            match int_of_string_opt amount with
            | Some amount -> amount
            | None -> invalid_arg "Invalid amount: expected an integer"
          in
          call "add" address (`Assoc [("amount", `Int amount)]) ;
          true
      | ["show"; address] ->
          call "read" address (`Assoc []) ;
          true
      | _ -> invalid_arg "Expected: add <a|b> <integer>, show <a|b>, or quit"
    with
    | Invalid_argument message ->
        Eio.Flow.copy_string
          ("Error: " ^ message ^ "\n")
          (Eio.Stdenv.stderr env) ;
        true
    | Kom.Error error ->
        Eio.Flow.copy_string
          ("Error: " ^ error.code ^ ": " ^ error.message ^ "\n")
          (Eio.Stdenv.stderr env) ;
        true
  in
  let rec loop () =
    match Eio.Buf_read.line input with
    | line -> if command line then loop ()
    | exception End_of_file -> ()
  in
  loop ()

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let system =
    Kom.System.create
      ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      Counter_example.System.definition
  in
  Fun.protect
    (fun () -> run env system)
    ~finally:(fun () -> Kom.System.close system)
