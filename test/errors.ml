let check condition message = if not condition then failwith message

let check_printed exn expected =
  let actual = Printexc.to_string exn in
  if actual <> expected
  then failwith (Printf.sprintf "Expected %S, got %S" expected actual)

let test_printer () =
  let error : Kom.error =
    {code= "Contract"; message= "Expected an integer"; path= None}
  in
  check_printed
    (Kom.Error error)
    {|Kom.Error {code = "Contract"; message = "Expected an integer"}|} ;
  check_printed
    (Kom.Error {error with path= Some "orders/0/amount"})
    {|Kom.Error {code = "Contract"; message = "Expected an integer"; path = "orders/0/amount"}|} ;
  check_printed
    (Kom.Error {error with path= Some ""})
    {|Kom.Error {code = "Contract"; message = "Expected an integer"; path = ""}|} ;
  check_printed
    (Kom.Error {code= "C\""; message= "line 1\nline 2"; path= Some "a\\b"})
    {|Kom.Error {code = "C\""; message = "line 1\nline 2"; path = "a\\b"}|} ;
  let exn = Kom.Error error in
  ignore (Printexc.to_string exn) ;
  match raise exn with
  | _ -> assert false
  | exception Kom.Error caught ->
      check (caught == error) "Printing changed the error payload"

exception Other_error of string

let test_other_exceptions () =
  check_printed (Failure "ordinary failure") {|Failure("ordinary failure")|} ;
  check_printed (Invalid_argument "argument") {|Invalid_argument("argument")|} ;
  check_printed Not_found "Not_found" ;
  check_printed End_of_file "End_of_file" ;
  Printexc.register_printer (function
    | Other_error message -> Some ("Other: " ^ message)
    | _ -> None ) ;
  check_printed (Other_error "details") "Other: details" ;
  test_printer ()

let test_init_flow () =
  let flow =
    Kom.Flow.define {id= "setup"; input= []; output= []; body= "!sequence()"}
  in
  List.iter
    (fun (id, flows) ->
      match Kom.System.define ~cell_kinds:[] ~init_flow:id ~flows () with
      | _ -> failwith "Missing init_flow was accepted"
      | exception Kom.Error {code; message; path} ->
          check (code = "Flow") "Unexpected init_flow error code" ;
          check (path = None) "Unexpected init_flow error path" ;
          check
            ( message
            = Printf.sprintf
                "Unknown init_flow %S: no flow with this id is defined in \
                 flows. Add the flow to flows or omit the optional init_flow \
                 argument."
                id )
            "Missing init_flow diagnostic lost its name or guidance" )
    [("init", []); ("bootstrap", [flow])] ;
  ignore (Kom.System.define ~cell_kinds:[] ~flows:[] ()) ;
  ignore (Kom.System.define ~cell_kinds:[] ~init_flow:"setup" ~flows:[flow] ())

let () =
  test_printer () ;
  test_other_exceptions () ;
  test_init_flow () ;
  print_endline
    "PASS error printing, exception handling and init_flow diagnostics"
