open Yojson.Safe.Util
open Kom
open Cell
open Schema

let empty = `Assoc []

let check b text = if not b then failwith text

let expect code f =
  match f () with
  | _ -> failwith ("Expected " ^ code)
  | exception Kom.Error e -> check (e.code = code) (e.code ^ ": " ^ e.message)

let flow ?(input = []) ?(output = []) id body =
  Flow.define {id; input; output; body}

let use env ?(storage = Storage.memory) definition f =
  Eio.Switch.run @@ fun sw ->
  let s =
    System.create
      ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~storage
      definition
  in
  Fun.protect (fun () -> f s) ~finally:(fun () -> System.close s)

let call s flow msg = System.call s ~flow msg

let optional f key msg =
  match member key msg with
  | `Null -> None
  | v -> Some (f v)

let row id key keep =
  `Assoc [("id", `String id); ("key", `Int key); ("keep", `Bool keep)]

let leaked = ref None

let paging =
  [ ("from", Optional Int)
  ; ("to", Optional Int)
  ; ("limit", Optional Int)
  ; ("cursor", Optional String)
  ; ("even", Optional Bool) ]

let output = [("keys", List Int); ("cursor", Optional String)]

let definition ?(version = 1) ?(offset = 0) ?(mapping = fun _ -> ()) () =
  let selected =
    Db.view
      { id= "selected"
      ; version
      ; key= Db.int
      ; map=
          (fun row ->
            mapping row ;
            if member "keep" row |> to_bool
            then Some ((member "key" row |> to_int) + offset, row)
            else None ) }
  in
  let other =
    Db.view {id= "undeclared"; version= 1; key= Db.int; map= (fun _ -> None)}
  in
  let cell =
    Cell.define
      ~views:[Db.View selected]
      { id= "documents"
      ; state= Recovery_model.state
      ; operations=
          [ Transformer
              { op= "put"
              ; input= [("id", String); ("key", Int); ("keep", Bool)]
              ; output= []
              ; impl=
                  (fun db n msg ->
                    leaked := Some db ;
                    Db.put db ~id:(member "id" msg |> to_string) msg ;
                    (n + 1, msg) ) }
          ; Transformer
              { op= "delete"
              ; input= [("id", String)]
              ; output= []
              ; impl=
                  (fun db n msg ->
                    Db.delete db ~id:(member "id" msg |> to_string) ;
                    (n + 1, msg) ) }
          ; Transformer
              { op= "read"
              ; input= [("id", String)]
              ; output= [("row", Any); ("n", Int)]
              ; impl=
                  (fun db n msg ->
                    ( n
                    , `Assoc
                        ( ( "row"
                          , Option.value
                              ~default:`Null
                              (Db.get db ~id:(member "id" msg |> to_string)) )
                        :: ("n", `Int n)
                        :: to_assoc msg ) ) ) }
          ; Transformer
              { op= "query"
              ; input= paging
              ; output
              ; impl=
                  (fun db n msg ->
                    let page =
                      Db.query
                        ?from_key:(optional to_int "from" msg)
                        ?to_key:(optional to_int "to" msg)
                        ?limit:(optional to_int "limit" msg)
                        ?after:(optional to_string "cursor" msg)
                        db
                        selected
                        (fun (key, _) ->
                          if
                            optional to_bool "even" msg = Some true
                            && key mod 2 <> 0
                          then None
                          else Some (`Int key) )
                    in
                    let fields =
                      ("keys", `List page.items)
                      :: List.remove_assoc "cursor" (to_assoc msg)
                    in
                    ( n
                    , `Assoc
                        ( match page.cursor with
                        | None -> fields
                        | Some c -> ("cursor", `String c) :: fields ) ) ) }
          ; Transformer
              { op= "undeclared"
              ; input= []
              ; output= []
              ; impl=
                  (fun db n msg ->
                    ignore (Db.query db other (fun v -> Some v)) ;
                    (n, msg) ) }
          ; Transformer
              { op= "bad"
              ; input= []
              ; output= []
              ; impl=
                  (fun db _ _ ->
                    Db.put db ~id:"bad" (row "bad" 99 true) ;
                    failwith "rollback" ) }
          ; Transformer
              { op= "fail"
              ; input= []
              ; output= []
              ; impl= (fun _ _ _ -> failwith "rollback") }
          ; Transformer
              { op= "seed"
              ; input= []
              ; output= []
              ; impl=
                  (fun db n msg ->
                    for i = 0 to 299 do
                      Db.put
                        db
                        ~id:(string_of_int i)
                        (row (string_of_int i) (i - 150) true)
                    done ;
                    (n, msg) ) } ] }
  in
  System.define
    ~cell_kinds:[cell]
    ~init_flow:"init"
    ~flows:
      [ flow
          "init"
          "!sequence(!reproduce documents as a !reproduce documents as b)"
      ; flow
          ~input:[("id", String); ("key", Int); ("keep", Bool)]
          "put"
          "put @a"
      ; flow ~input:[("id", String)] "delete" "delete @a"
      ; flow
          ~input:[("id", String)]
          ~output:[("row", Any); ("n", Int)]
          "read"
          "read @a"
      ; flow
          ~input:[("id", String)]
          ~output:[("row", Any); ("n", Int)]
          "read_b"
          "read @b"
      ; flow
          ~input:([("id", String); ("key", Int); ("keep", Bool)] @ paging)
          ~output
          "tx_query"
          "!transaction(!sequence(put @a query @a))"
      ; flow ~input:paging ~output "query" "query @a"
      ; flow ~input:paging ~output "query_b" "query @b"
      ; flow "bad" "bad @a"
      ; flow "undeclared" "undeclared @a"
      ; flow "seed" "seed @a"
      ; flow
          ~input:[("id", String); ("key", Int); ("keep", Bool)]
          "rollback"
          "!transaction(!sequence(put @a put @b !reproduce documents as new \
           fail @a))"
      ; flow
          ~input:[("id", String); ("key", Int); ("keep", Bool)]
          ~output:[("row", Any); ("n", Int)]
          "transaction"
          "!transaction(!sequence(put @a put @b read @a))"
      ; flow
          ~input:[("id", String); ("key", Int); ("keep", Bool)]
          "create"
          "!transaction(!sequence(!reproduce documents as new put @new))" ]
    ()

let ids r = r |> member "keys" |> to_list |> List.map to_int

let get s flow id = call s flow (`Assoc [("id", `String id)])

let test_documents env =
  use env (definition ()) (fun s ->
      ignore (call s "put" (row "one" (-3) true)) ;
      check
        (member "row" (get s "read_b" "one") = `Null)
        "document crossed cell boundary" ;
      check (ids (call s "query" empty) = [-3]) "initial index" ;
      expect "Db" (fun () ->
          Db.put (Option.get !leaked) ~id:"escaped" (row "escaped" 0 true) ) ;
      expect "Db" (fun () -> call s "undeclared" empty) ;
      ignore (call s "put" (row "one" 7 true)) ;
      check (ids (call s "query" empty) = [7]) "stale index key" ;
      ignore (call s "put" (row "two" 7 true)) ;
      let page = call s "query" (`Assoc [("limit", `Int 1)]) in
      check (ids page = [7]) "duplicate key first page" ;
      let page =
        call
          s
          "query"
          (`Assoc [("limit", `Int 1); ("cursor", member "cursor" page)])
      in
      check
        (ids page = [7] && member "cursor" page = `Null)
        "cursor skipped duplicate key" ;
      ignore (call s "delete" (`Assoc [("id", `String "two")])) ;
      ignore (call s "put" (row "one" 7 false)) ;
      check (ids (call s "query" empty) = []) "filter transition" ;
      expect "Exception" (fun () -> call s "bad" empty) ;
      check
        (member "row" (get s "read" "bad") = `Null)
        "failed operation leaked document" ;
      expect "Exception" (fun () -> call s "rollback" (row "tx" 1 true)) ;
      List.iter
        (fun flow ->
          check
            (member "row" (get s flow "tx") = `Null)
            "transaction leaked document" )
        ["read"; "read_b"] ;
      let committed = call s "transaction" (row "tx" 1 true) in
      check
        (member "row" committed <> `Null)
        "transaction cannot read own writes" ;
      ignore (call s "create" (row "new" 2 true)) ;
      ignore (call s "delete" (`Assoc [("id", `String "tx")])) ;
      check (ids (call s "query" empty) = []) "delete left index row" ;
      check
        (ids (call s "tx_query" (row "own-index" 44 true)) = [44])
        "transaction cannot query own index writes" ;
      ignore (call s "delete" (`Assoc [("id", `String "own-index")])) ;
      ignore (call s "seed" empty) ;
      let page =
        call
          s
          "query"
          (`Assoc
             [ ("from", `Int (-10))
             ; ("to", `Int 10)
             ; ("limit", `Int 3)
             ; ("even", `Bool true) ] )
      in
      check (ids page = [-10; -8; -6]) "range/predicate/limit order" ;
      let params =
        `Assoc
          [ ("from", `Int (-10))
          ; ("to", `Int 10)
          ; ("limit", `Int 3)
          ; ("even", `Bool true)
          ; ("cursor", member "cursor" page) ]
      in
      check (ids (call s "query" params) = [-4; -2; 0]) "cursor pagination" ;
      expect "Db" (fun () -> call s "query_b" params) ;
      expect "Db" (fun () ->
          call s "query" (`Assoc [("cursor", member "cursor" page)]) ) ;
      check
        ( List.length
            (ids
               (call
                  s
                  "query"
                  (`Assoc [("limit", `Int 500); ("even", `Bool true)]) ) )
        = 150 )
        "filter across scan batches" )

let cleanup path =
  Sys.readdir (Filename.dirname path)
  |> Array.iter (fun name ->
      if String.starts_with ~prefix:(Filename.basename path) name
      then Sys.remove (Filename.concat (Filename.dirname path) name) )

let test_versions env =
  let path = Filename.temp_file "kom-views-" ".sqlite" in
  Sys.remove path ;
  Fun.protect
    ~finally:(fun () -> cleanup path)
    (fun () ->
      let storage = Kom_sqlite.storage path in
      let old_cursor = ref `Null in
      use env ~storage (definition ()) (fun s ->
          ignore (call s "put" (row "saved" 3 true)) ;
          ignore (call s "put" (row "saved-again" 4 true)) ;
          old_cursor :=
            member "cursor" (call s "query" (`Assoc [("limit", `Int 1)])) ) ;
      let count = Atomic.make 0 in
      use
        env
        ~storage
        (definition
           ~mapping:(fun _ -> ignore (Atomic.fetch_and_add count 1))
           () )
        (fun s ->
          check (ids (call s "query" empty) = [3; 4]) "restored index" ;
          check (Atomic.get count = 0) "unchanged version rebuilt" ) ;
      expect "Exception" (fun () ->
          use
            env
            ~storage
            (definition ~version:2 ~mapping:(fun _ -> failwith "bad mapper") ())
            ignore ) ;
      use env ~storage (definition ()) (fun s ->
          check
            (ids (call s "query" empty) = [3; 4])
            "failed rebuild damaged old index" ) ;
      use env ~storage (definition ~version:2 ~offset:10 ()) (fun s ->
          check (ids (call s "query" empty) = [13; 14]) "eager version rebuild" ) ;
      use env ~storage (definition ~version:2 ~offset:10 ()) (fun s ->
          check
            (ids (call s "query" empty) = [13; 14])
            "published rebuilt version" ;
          expect "Db" (fun () ->
              call s "query" (`Assoc [("cursor", !old_cursor)]) ) ) )

let test_conflict env =
  let entered, enter = Eio.Promise.create ()
  and released, release = Eio.Promise.create () in
  let cell =
    Cell.define
      { id= "counter"
      ; state= Recovery_model.state
      ; operations=
          [ Transformer
              { op= "inc"
              ; input= []
              ; output= []
              ; impl= (fun _ n msg -> (n + 1, msg)) }
          ; Transformer
              { op= "wait"
              ; input= []
              ; output= []
              ; impl=
                  (fun _ n msg ->
                    Eio.Promise.resolve enter () ;
                    Eio.Promise.await released ;
                    (n, msg) ) }
          ; Transformer
              { op= "read"
              ; input= []
              ; output= [("n", Int)]
              ; impl=
                  (fun _ n msg -> (n, `Assoc (("n", `Int n) :: to_assoc msg)))
              }
          ; Joiner
              { op= "join"
              ; input= []
              ; output= []
              ; impl= (fun _ n _ -> (n, empty)) } ] }
  in
  let def =
    System.define
      ~cell_kinds:[cell]
      ~init_flow:"init"
      ~flows:
        [ flow
            "init"
            "!sequence(!reproduce counter as a !reproduce counter as b \
             !reproduce counter as c)"
        ; flow "tx" "!transaction(!sequence(inc @a wait @b))"
        ; flow "inc" "inc @a"
        ; flow ~output:[("n", Int)] "read" "read @a"
        ; flow
            "parallel"
            "!transaction(!sequence(!parallel(inc @a inc @c) join @b))"
        ; flow ~output:[("n", Int)] "read_c" "read @c" ]
      ()
  in
  use env def (fun s ->
      Eio.Switch.run @@ fun sw ->
      let tx = Eio.Fiber.fork_promise ~sw (fun () -> call s "tx" empty) in
      Eio.Promise.await entered ;
      ignore (call s "inc" empty) ;
      Eio.Promise.resolve release () ;
      expect "Conflict" (fun () -> Eio.Promise.await_exn tx) ;
      check
        (member "n" (call s "read" empty) = `Int 1)
        "conflicting transaction changed state" ;
      ignore (call s "parallel" empty) ;
      check
        ( member "n" (call s "read" empty) = `Int 2
        && member "n" (call s "read_c" empty) = `Int 1 )
        "parallel transaction context" )

let test_keys env =
  let by_name =
    Db.view
      { id= "name"
      ; version= 1
      ; key= Db.string
      ; map= (fun row -> Some (row |> member "id" |> to_string, row)) }
  in
  let by_pair =
    Db.view
      { id= "pair"
      ; version= 1
      ; key= Db.pair Db.int Db.string
      ; map=
          (fun row ->
            Some
              ( (row |> member "key" |> to_int, row |> member "id" |> to_string)
              , row ) ) }
  in
  let cell =
    Cell.define
      ~views:[Db.View by_name; Db.View by_pair]
      { id= "keys"
      ; state= unit_state
      ; operations=
          [ Transformer
              { op= "check"
              ; input= []
              ; output= []
              ; impl=
                  (fun db () msg ->
                    List.iter
                      (fun row ->
                        Db.put db ~id:(row |> member "id" |> to_string) row )
                      [ row "aa" 0 true
                      ; row "a" 0 true
                      ; row "" (-1) true
                      ; row "z" (-1) true ] ;
                    let names =
                      Db.query db by_name (fun (name, _) -> Some name)
                    in
                    check
                      (names.items = [""; "a"; "aa"; "z"])
                      "string key order" ;
                    let pairs =
                      Db.query db by_pair (fun (key, _) -> Some key)
                    in
                    check
                      (pairs.items = [(-1, ""); (-1, "z"); (0, "a"); (0, "aa")])
                      "pair key order" ;
                    let range =
                      Db.query
                        ~from_key:(0, "a")
                        ~to_key:(0, "a")
                        db
                        by_pair
                        (fun (key, _) -> Some key )
                    in
                    check (range.items = [(0, "a")]) "inclusive pair range" ;
                    ((), msg) ) } ] }
  in
  let def =
    System.define
      ~cell_kinds:[cell]
      ~init_flow:"init"
      ~flows:[flow "init" "!reproduce keys as keys"; flow "check" "check @keys"]
      ()
  in
  use env def (fun s -> ignore (call s "check" empty))

let test_owner env =
  let holder = ref None in
  let entered, enter = Eio.Promise.create ()
  and released, release = Eio.Promise.create () in
  let cell =
    Cell.define
      { id= "owner"
      ; state= unit_state
      ; operations=
          [ Transformer
              { op= "wait"
              ; input= []
              ; output= []
              ; impl=
                  (fun db () msg ->
                    holder := Some db ;
                    Eio.Promise.resolve enter () ;
                    Eio.Promise.await released ;
                    ((), msg) ) }
          ; Transformer
              { op= "steal"
              ; input= []
              ; output= []
              ; impl=
                  (fun _ () msg ->
                    Db.put
                      (Option.get !holder)
                      ~id:"foreign"
                      (row "foreign" 0 true) ;
                    ((), msg) ) } ] }
  in
  let def =
    System.define
      ~cell_kinds:[cell]
      ~init_flow:"init"
      ~flows:
        [ flow "init" "!sequence(!reproduce owner as a !reproduce owner as b)"
        ; flow "wait" "wait @a"
        ; flow "steal" "steal @b" ]
      ()
  in
  use env def (fun s ->
      Eio.Switch.run @@ fun sw ->
      let waiting =
        Eio.Fiber.fork_promise ~sw (fun () -> call s "wait" empty)
      in
      Eio.Promise.await entered ;
      expect "Db" (fun () -> call s "steal" empty) ;
      Eio.Promise.resolve release () ;
      ignore (Eio.Promise.await_exn waiting) )

let test_atomic_failures env =
  let path = Filename.temp_file "kom-atomic-" ".sqlite" in
  Sys.remove path ;
  let armed = Atomic.make false in
  let view =
    Db.view
      { id= "values"
      ; version= 1
      ; key= Db.int
      ; map=
          (fun doc ->
            let n = doc |> member "n" |> to_int in
            if n < 0 then failwith "mapper failure" else Some (n, doc) ) }
  in
  let state =
    { version= 1
    ; init= (fun () -> ref 0)
    ; to_string= (fun n -> string_of_int !n)
    ; of_string=
        (fun text ->
          match int_of_string_opt text with
          | Some n when n >= 0 -> Ok (ref n)
          | _ -> Error "bad state" ) }
  in
  let cell =
    Cell.define
      ~views:[Db.View view]
      { id= "mutable"
      ; state
      ; operations=
          [ Transformer
              { op= "put"
              ; input= []
              ; output= []
              ; impl=
                  (fun db n msg ->
                    incr n ;
                    Db.put db ~id:"value" (`Assoc [("n", `Int !n)]) ;
                    (n, msg) ) }
          ; Transformer
              { op= "arm"
              ; input= []
              ; output= []
              ; impl=
                  (fun _ n msg ->
                    Atomic.set armed true ;
                    (n, msg) ) }
          ; Transformer
              { op= "invalid"
              ; input= []
              ; output= [("n", Int)]
              ; impl=
                  (fun _ n msg ->
                    incr n ;
                    (n, `Assoc (("n", `String "bad") :: to_assoc msg)) ) }
          ; Transformer
              { op= "codec"
              ; input= []
              ; output= []
              ; impl=
                  (fun _ n msg ->
                    n := -1 ;
                    (n, msg) ) }
          ; Transformer
              { op= "mapping"
              ; input= []
              ; output= []
              ; impl=
                  (fun db n msg ->
                    incr n ;
                    Db.put db ~id:"value" (`Assoc [("n", `Int (-1))]) ;
                    (n, msg) ) }
          ; Transformer
              { op= "read"
              ; input= []
              ; output= [("n", Int); ("document", Any); ("keys", List Int)]
              ; impl=
                  (fun db n msg ->
                    let page = Db.query db view (fun (n, _) -> Some (`Int n)) in
                    ( n
                    , `Assoc
                        ( ("n", `Int !n)
                        :: ( "document"
                           , Option.value ~default:`Null (Db.get db ~id:"value")
                           )
                        :: ("keys", `List page.items)
                        :: to_assoc msg ) ) ) } ] }
  in
  let initial =
    flow "init" "!sequence(!reproduce mutable as a !reproduce mutable as b)"
  in
  let def =
    System.define
      ~cell_kinds:[cell]
      ~init_flow:"init"
      ~flows:
        [ initial
        ; flow "validation" "!transaction(!sequence(put @a invalid @b))"
        ; flow "codec" "!transaction(!sequence(put @a codec @b))"
        ; flow "mapping" "!transaction(!sequence(put @a mapping @b))"
        ; flow "storage" "!transaction(!sequence(put @a arm @b))"
        ; flow
            "create_fail"
            "!transaction(!sequence(!reproduce mutable as new put @new invalid \
             @b))"
        ; flow
            "create"
            "!transaction(!sequence(!reproduce mutable as new put @new))"
        ; flow
            ~output:[("n", Int); ("document", Any); ("keys", List Int)]
            "read_a"
            "read @a"
        ; flow
            ~output:[("n", Int); ("document", Any); ("keys", List Int)]
            "read_b"
            "read @b" ]
      ()
  in
  expect "Transaction" (fun () ->
      System.define
        ~cell_kinds:[cell]
        ~flows:[initial; flow "nested" "!transaction(!transaction(put @a))"]
        () ) ;
  Fun.protect
    ~finally:(fun () -> cleanup path)
    (fun () ->
      let storage =
        Kom_sqlite.storage
          ~before_commit:(fun () ->
            if Atomic.exchange armed false
            then failwith "injected commit failure" )
          path
      in
      let unchanged s =
        List.iter
          (fun flow ->
            let r = call s flow empty in
            check
              ( member "n" r = `Int 0
              && member "document" r = `Null
              && member "keys" r = `List [] )
              "transaction leaked state, document or index" )
          ["read_a"; "read_b"]
      in
      use env ~storage def (fun s ->
          List.iter
            (fun (flow, code) ->
              expect code (fun () -> call s flow empty) ;
              unchanged s )
            [ ("validation", "Contract")
            ; ("codec", "State")
            ; ("mapping", "Exception")
            ; ("storage", "Store")
            ; ("create_fail", "Contract") ] ;
          ignore (call s "create" empty) ) ;
      use env ~storage def unchanged )

let () =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () ->
      List.iter
        (fun (name, f) ->
          ( try f env with
          | Kom.Error e ->
              Printf.eprintf
                "%s: %s (%s)\n%!"
                e.code
                e.message
                (Option.value ~default:"" e.path) ;
              raise (Kom.Error e) ) ;
          Printf.printf "PASS %s\n%!" name )
        [ ("atomic validation, codecs, mapping and SQLite", test_atomic_failures)
        ; ("ordered string and pair keys", test_keys)
        ; ("active handle owner", test_owner)
        ; ("private documents, views and transactions", test_documents)
        ; ("view versions and failed rebuild", test_versions)
        ; ("transaction conflict and parallel", test_conflict) ] )
