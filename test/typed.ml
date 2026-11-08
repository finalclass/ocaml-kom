open Kom
open Yojson.Safe.Util

let check condition message = if not condition then failwith message

let expect code f =
  match f () with
  | _ -> failwith ("Expected " ^ code)
  | exception Kom.Error error ->
      check (error.code = code) (error.code ^ ": " ^ error.message)

module State = struct
  type t = int [@@deriving yojson]

  let version = 1

  let init () = 0
end

module Empty = struct
  type t = unit [@@deriving kom]
end

module Input = struct
  type t = {user: string} [@@deriving kom]
end

module Greeting = struct
  type t = {greeting: string} [@@deriving kom]
end

module Choice = struct
  type t =
    | A of Greeting.t
    | B of Greeting.t
  [@@deriving kom_route]
end

module Item = struct
  type t = {amount: int} [@@deriving kom]
end

module Summary = struct
  type t =
    { total: int
    ; count: int }
  [@@deriving kom]
end

module Other = struct
  type t = {other: string} [@@deriving kom]
end

module TagA = struct
  type tag =
    | A
    | B
  [@@deriving kom]

  type t = {tag: tag} [@@deriving kom]
end

module TagB = struct
  type tag =
    | B
    | C
  [@@deriving kom]

  type t = {tag: tag} [@@deriving kom]
end

module Nested = struct
  type user =
    { name: string
    ; language: string option }
  [@@deriving kom]

  type tag =
    | Ready
    | Waiting of int
    | Failed of string * int
  [@@deriving kom]

  type 'a box = {value: 'a} [@@deriving kom]

  type t =
    { user: user
    ; values: int list
    ; pair: string * bool
    ; tag: tag
    ; boxes: string box array
    ; nullable: int option list }
  [@@deriving kom]
end

module UserName = struct
  type user = {name: string} [@@deriving kom]

  type t = {user: user} [@@deriving kom]
end

module UserAge = struct
  type user = {age: int} [@@deriving kom]

  type t = {user: user} [@@deriving kom]
end

let greet _db state msg =
  check (Msg.id msg <> "") "missing identity" ;
  (state + 1, Greeting.{greeting= "Cześć, " ^ (Msg.data msg).Input.user})

let operations =
  [ Cell.transformer
      ~id:"tag_a"
      ~input:(module TagA)
      ~output:(Output.patch (module Empty))
      ~impl:(fun _db state _ -> (state, ()))
  ; Cell.transformer
      ~id:"tag_b"
      ~input:(module TagB)
      ~output:(Output.patch (module Empty))
      ~impl:(fun _db state _ -> (state, ()))
  ; Cell.transformer
      ~id:"greet"
      ~input:(module Input)
      ~output:(Output.patch (module Greeting))
      ~impl:greet
  ; Cell.transformer
      ~id:"fresh"
      ~input:(module Input)
      ~output:(Output.fresh (module Greeting))
      ~impl:greet
  ; Cell.transformer
      ~id:"clean"
      ~input:(module Empty)
      ~output:(Output.patch ~remove:["user"] (module Empty))
      ~impl:(fun _db state _ -> (state, ()))
  ; Cell.transformer
      ~id:"other"
      ~input:(module Other)
      ~output:(Output.patch (module Empty))
      ~impl:(fun _db state _ -> (state, ()))
  ; Cell.transformer
      ~id:"set_other"
      ~input:(module Empty)
      ~output:(Output.patch (module Other))
      ~impl:(fun _db state _ -> (state, Other.{other= "created"}))
  ; Cell.transformer
      ~id:"name"
      ~input:(module UserName)
      ~output:(Output.patch (module Empty))
      ~impl:(fun _db state _ -> (state, ()))
  ; Cell.transformer
      ~id:"age"
      ~input:(module UserAge)
      ~output:(Output.patch (module Empty))
      ~impl:(fun _db state _ -> (state, ()))
  ; Cell.expander
      ~id:"items"
      ~input:(module Empty)
      ~output:(Output.patch (module Item))
      ~impl:(fun _db state _ -> (state, [Item.{amount= 3}; Item.{amount= 4}]))
  ; Cell.expander
      ~id:"none"
      ~input:(module Empty)
      ~output:(Output.fresh (module Item))
      ~impl:(fun _db state _ -> (state, []))
  ; Cell.joiner
      ~id:"sum"
      ~input:(module Item)
      ~output:(Output.fresh (module Summary))
      ~impl:(fun _db state messages ->
        let ids = List.map Msg.id messages in
        check
          (List.length ids = List.length (List.sort_uniq String.compare ids))
          "expander reused message IDs" ;
        ( state
        , Summary.
            { total=
                List.fold_left
                  (fun n msg -> n + (Msg.data msg).Item.amount)
                  0
                  messages
            ; count= List.length messages } ) )
  ; Cell.joiner
      ~id:"selected"
      ~input:(module Item)
      ~output:(Output.patch_selected ~remove:["temporary"] (module Summary))
      ~impl:(fun _db state messages ->
        match messages with
        | [] -> failwith "Cannot select from an empty group"
        | base :: _ ->
            check
              (Msg.raw base |> member "extra" = `Bool true)
              "lost full payload" ;
            (state, (base, Summary.{total= 7; count= List.length messages})) )
  ; Cell.joiner
      ~id:"forged"
      ~input:(module Item)
      ~output:(Output.patch_selected (module Summary))
      ~impl:(fun _db state messages ->
        match messages with
        | [] -> failwith "empty"
        | base :: _ ->
            let forged =
              Msg.of_json ~id:(Msg.id base) (Msg.raw base)
              |> Msg.decode (module Item)
            in
            (state, (forged, Summary.{total= 0; count= 0})) )
  ; Cell.router
      ~id:"choose"
      ~input:(module Input)
      ~output:(Output.patch_route (module Choice))
      ~impl:(fun db state msg ->
        let state, output = greet db state msg in
        (state, Choice.A output) ) ]

let cell = Cell.define {id= "Greeter"; state= (module State); operations}

let flow id body = Flow.define ~id ~body ()

let define flows =
  System.define
    ~cell_kinds:[cell]
    ~init_flow:"init"
    ~flows:(flow "init" "!reproduce Greeter as @g" :: flows)
    ()

let catalog_flow definition id =
  Kom.run definition (fun sys ->
      System.catalog sys
      |> member "flows"
      |> to_list
      |> List.find (fun json -> member "id" json = `String id) )

let test_codecs () =
  let value =
    Nested.
      { user= {name= "Jan"; language= None}
      ; values= [1; 2]
      ; pair= ("x", true)
      ; tag= Failed ("bad", 3)
      ; boxes= [|{value= "box"}|]
      ; nullable= [None; Some 2] }
  in
  let encoded = Msg.encode (module Nested) value in
  let decoded = Msg.decode (module Nested) encoded in
  check (Msg.data decoded = value) "nested codec roundtrip" ;
  let without_option =
    Msg.raw encoded
    |> to_assoc
    |> List.map (function
      | "user", _ ->
          ("user", `Assoc [("name", `String "Jan"); ("extra", `Int 2)])
      | field -> field )
    |> Msg.define
  in
  check
    ( (Msg.decode (module Nested) without_option |> Msg.data).user.language
    = None )
    "missing optional field" ;
  expect "Contract" (fun () ->
      Msg.decode (module Input) (Msg.define [("user", `Int 1)]) ) ;
  expect "Contract" (fun () ->
      Msg.decode
        (module Nested)
        (Msg.define
           ( ("tag", `List [`String "Unknown"])
           :: List.remove_assoc "tag" (to_assoc (Msg.raw encoded)) ) ) ) ;
  print_endline
    "PASS generated record, nested, option, tuple, variant and generic codecs"

let test_parser () =
  List.iter
    (fun body -> ignore (flow "parse" body))
    [ "!reproduce Greeter as @first; greet @first"
    ; "\n!reproduce Greeter as @first\r\n\ngreet @first;\n"
    ; "!sequence(\n!reproduce Greeter as @first; greet @first\n)"
    ; "!transaction(!reproduce Greeter as @first; greet @first)"
    ; "!branch(choose @g; A(greet @g); B(greet @g))" ] ;
  List.iter
    (fun body -> expect "Parse" (fun () -> flow "bad" body))
    [ "!reproduce Greeter as @first greet @first"
    ; "!reproduce Greeter as first"
    ; "!sequence(greet @g greet @g)"
    ; "!parallel(greet @g, greet @g)"
    ; "!sequence()!sequence()"
    ; "!branch(choose @g A(greet @g); B(greet @g))" ] ;
  print_endline "PASS statement separators and @ creation syntax"

let test_inference () =
  let definition =
    define
      [ flow "greet" "greet @g"
      ; flow "fresh" "fresh @g"
      ; flow "sum" "items @g; sum @g"
      ; flow "empty" "none @g; sum @g"
      ; flow "selected" "items @g; selected @g"
      ; flow "forged" "items @g; forged @g"
      ; flow "branch" "!branch(choose @g; A(other @g); B(!sequence()))"
      ; flow
          "branch_source"
          "!branch(choose @g; A(set_other @g); B(!sequence())); other @g"
      ; flow "nested" "name @g; age @g"
      ; flow "tags" "tag_a @g; tag_b @g"
      ; flow
          "dynamic"
          "!reproduce Greeter as @person.{$.user}; greet @person.{$.user}"
      ; flow "collision" "!reproduce Greeter as @g" ]
  in
  let contract = catalog_flow definition "greet" in
  let names key =
    member key contract
    |> to_list
    |> List.map (fun v -> member "name" v |> to_string)
  in
  check (names "input" = ["user"]) "inferred input" ;
  check
    (List.sort String.compare (names "output") = ["greeting"; "user"])
    "inferred patch output" ;
  let branch = catalog_flow definition "branch" in
  check
    (List.length (branch |> member "input" |> to_list) = 2)
    "branch requirement not inferred" ;
  let branch = catalog_flow definition "branch_source" in
  check
    (List.length (branch |> member "input" |> to_list) = 2)
    "branch provenance not inferred" ;
  Kom.run definition (fun sys ->
      let msg =
        Msg.define
          [ ("user", `String "John")
          ; ("extra", `Bool true)
          ; ("temporary", `Int 2) ]
      in
      let result = System.call sys ~flow:"greet" ~msg in
      check (Msg.id result = Msg.id msg) "patch changed ID" ;
      check
        (Msg.raw result |> member "greeting" = `String "Cześć, John")
        "greeting" ;
      check
        (Msg.raw result |> member "extra" = `Bool true)
        "patch discarded extras" ;
      let result = System.call sys ~flow:"fresh" ~msg in
      check (Msg.id result <> Msg.id msg) "fresh reused ID" ;
      check
        (List.length (to_assoc (Msg.raw result)) = 1)
        "fresh retained extras" ;
      let result = System.call sys ~flow:"sum" ~msg in
      check (Msg.raw result |> member "total" = `Int 7) "sum" ;
      check (Msg.raw result |> member "count" = `Int 2) "count" ;
      let result = System.call sys ~flow:"empty" ~msg in
      check (Msg.raw result |> member "total" = `Int 0) "empty join" ;
      let result = System.call sys ~flow:"selected" ~msg in
      check (Msg.raw result |> member "extra" = `Bool true) "selected base" ;
      check
        (not (List.mem_assoc "temporary" (to_assoc (Msg.raw result))))
        "removal" ;
      expect "Identity" (fun () -> System.call sys ~flow:"forged" ~msg) ;
      expect "CellExists" (fun () -> System.call sys ~flow:"collision" ~msg) ;
      expect "Contract" (fun () ->
          System.call sys ~flow:"greet" ~msg:(Msg.define []) ) ;
      ignore (System.call sys ~flow:"dynamic" ~msg) ;
      ignore
        (System.call
           sys
           ~flow:"tags"
           ~msg:(Msg.encode (module TagA) TagA.{tag= B}) ) ;
      expect "Contract" (fun () ->
          System.call
            sys
            ~flow:"tags"
            ~msg:(Msg.encode (module TagA) TagA.{tag= A}) ) ;
      ignore
        (System.call
           sys
           ~flow:"nested"
           ~msg:
             (Msg.define
                [("user", `Assoc [("name", `String "John"); ("age", `Int 30)])] ) ) ) ;
  expect "Contract" (fun () -> define [flow "bad" "clean @g; greet @g"]) ;
  expect "Contract" (fun () -> define [flow "bad" "fresh @g; greet @g"]) ;
  expect "Contract" (fun () -> define [flow "bad" "greet @g; name @g"]) ;
  print_endline
    "PASS inferred contracts, patch/fresh, removals, joiners, branches and \
     identity"

let test_persistence () =
  let path = Filename.temp_file "kom-typed-" ".sqlite" in
  let definition = define [flow "greet" "greet @g"; flow "fresh" "fresh @g"] in
  let message = Msg.define [("user", `String "Persisted")] in
  let call () =
    Kom.run ~storage:(Kom_sqlite.storage path) definition (fun sys ->
        System.call ~request_id:"same" sys ~flow:"fresh" ~msg:message )
  in
  let first = call () and second = call () in
  check
    (Msg.id first = Msg.id second && Msg.raw first = Msg.raw second)
    "persisted outcome identity" ;
  List.iter
    (fun suffix ->
      let file = path ^ suffix in
      if Sys.file_exists file then Sys.remove file )
    [""; "-wal"; "-shm"] ;
  print_endline "PASS typed message persistence and deduplication"

let () =
  test_codecs () ;
  test_parser () ;
  test_inference () ;
  test_persistence ()
