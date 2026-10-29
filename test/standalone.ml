open Kom

let check condition message = if not condition then failwith message

let empty = `Assoc []

let value message = Yojson.Safe.Util.(message |> member "value" |> to_int)

let definition = Counter_example.System.definition

exception Callback_failed

let test_lifecycle () =
  let closed = ref 0 in
  let storage =
    Storage.wrap
      (fun ~id backend ->
        check (id = "standalone") "System ID was not forwarded" ;
        { backend with
          close=
            (fun () ->
              incr closed ;
              backend.close () ) } )
      Storage.memory
  in
  let result =
    Kom_main.run ~id:"standalone" ~workers:1 ~storage definition (fun system ->
        check (!closed = 0) "Storage closed before callback" ;
        System.call system ~flow:"add_a" (`Assoc [("amount", `Int 3)]) |> value )
  in
  check (result = 3) "Callback result was not returned" ;
  check (!closed = 1) "Normal return did not close storage exactly once" ;
  ( match
      Kom_main.run ~id:"standalone" ~storage definition (fun _ ->
          raise Callback_failed )
    with
  | _ -> failwith "Callback exception was swallowed"
  | exception Callback_failed -> () ) ;
  check (!closed = 2) "Callback exception leaked storage" ;
  match Kom_main.run ~workers:0 definition (fun _ -> assert false) with
  | _ -> failwith "Invalid worker count was ignored"
  | exception Kom.Error error ->
      check (error.code = "Workers") "Unexpected worker validation error"

let test_initialization_failure () =
  let closed = ref 0 in
  let storage =
    Storage.wrap
      (fun ~id:_ backend ->
        { backend with
          close=
            (fun () ->
              incr closed ;
              backend.close () ) } )
      Storage.memory
  in
  let cell =
    Cell.define
      { id= "broken"
      ; state= {Cell.unit_state with init= (fun () -> failwith "Broken init")}
      ; operations= [] }
  in
  let broken =
    System.define
      ~cell_kinds:[cell]
      ~init_flow:"init"
      ~flows:
        [ Flow.define
            { id= "init"
            ; input= []
            ; output= []
            ; body= "!reproduce broken as broken" } ]
      ()
  in
  ( match Kom_main.run ~storage broken (fun _ -> assert false) with
  | _ -> failwith "Initialization failure was swallowed"
  | exception Kom.Error _ -> () ) ;
  check (!closed = 1) "Failed initialization leaked storage"

let test_sqlite_reopen () =
  let path = Filename.temp_file "kom-main-" ".sqlite" in
  Fun.protect
    ~finally:(fun () ->
      Sys.readdir (Filename.dirname path)
      |> Array.iter (fun name ->
          if String.starts_with ~prefix:(Filename.basename path) name
          then Sys.remove (Filename.concat (Filename.dirname path) name) ) )
    (fun () ->
      let run = Kom_main.run ~storage:(Kom_sqlite.storage path) definition in
      ( match
          run (fun system ->
              ignore
                (System.call system ~flow:"add_a" (`Assoc [("amount", `Int 7)])) ;
              raise Callback_failed )
        with
      | _ -> failwith "Callback exception was swallowed"
      | exception Callback_failed -> () ) ;
      check
        ( run (fun system -> System.call system ~flow:"read_a" empty |> value)
        = 7 )
        "SQLite could not reopen with committed state after an exception" ;
      check
        ( run (fun system -> System.call system ~flow:"read_a" empty |> value)
        = 7 )
        "SQLite could not reopen after normal return" )

let () =
  test_lifecycle () ;
  print_endline "PASS standalone result, options and callback cleanup" ;
  test_initialization_failure () ;
  print_endline "PASS standalone initialization cleanup" ;
  test_sqlite_reopen () ;
  print_endline "PASS standalone SQLite persistence and reopen"
