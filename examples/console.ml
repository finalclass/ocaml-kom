let words line =
  line
  |> String.trim
  |> String.map (function
    | '\t' -> ' '
    | c -> c )
  |> String.split_on_char ' '
  |> List.filter (fun word -> word <> "")

let run system =
  let call operation address message =
    if address <> "a" && address <> "b"
    then invalid_arg "Unknown counter: expected a or b" ;
    let result =
      Kom.System.call system ~flow:(operation ^ "_" ^ address) message
    in
    let value = Yojson.Safe.Util.(result |> member "value" |> to_int) in
    print_endline (string_of_int value)
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
        prerr_endline ("Error: " ^ message) ;
        true
    | Kom.Error error ->
        prerr_endline ("Error: " ^ error.code ^ ": " ^ error.message) ;
        true
  in
  let rec loop () =
    match read_line () with
    | line -> if command line then loop ()
    | exception End_of_file -> ()
  in
  loop ()

let () = Kom_main.run Counter_example.System.definition run
