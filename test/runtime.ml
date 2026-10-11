open Kom
open Kom.Cell
open Kom.Schema
open Yojson.Safe.Util

let empty = `Assoc []

let check condition message = if not condition then failwith message

let expect code f =
  match f () with
  | _ -> failwith ("Expected " ^ code)
  | exception Kom.Error error ->
      check (error.code = code) (error.code ^ ": " ^ error.message)

let flow ?(output = []) id body = Flow.define {id; input= []; output; body}

let definition
    ?(version = 1)
    ?(decode = Recovery_model.state.of_string)
    ?(hold = fun () -> ())
    ?(reentrant = fun () -> ())
    revision =
  let state = {Recovery_model.state with version; of_string= decode} in
  let operations =
    List.map
      (fun (op, impl) ->
        Transformer
          {op; input= []; output= [("n", Int); ("revision", Int)]; impl} )
      [ ( "increment"
        , fun _ n _ ->
            let n = n + revision in
            (n, `Assoc [("n", `Int n); ("revision", `Int revision)]) )
      ; ( "hold"
        , fun _ n _ ->
            hold () ;
            (n, `Assoc [("n", `Int n); ("revision", `Int revision)]) )
      ; ( "reentrant"
        , fun _ n _ ->
            reentrant () ;
            (n, `Assoc [("n", `Int n); ("revision", `Int revision)]) ) ]
  in
  let cell = Cell.define ~revision {id= "counter"; state; operations} in
  System.define
    ~cell_kinds:[cell]
    ~init_flow:"init"
    ~flows:
      [ flow "init" "!reproduce counter as counter"
      ; flow
          ~output:[("n", Int); ("revision", Int)]
          "increment"
          "increment @counter"
      ; flow ~output:[("n", Int); ("revision", Int)] "hold" "hold @counter"
      ; flow
          ~output:[("n", Int); ("revision", Int)]
          "reentrant"
          "reentrant @counter" ]
    ()

let use env ?(storage = Storage.memory) definition f =
  Eio.Switch.run @@ fun sw ->
  let system =
    System.create
      ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~workers:2
      ~storage
      definition
  in
  Fun.protect ~finally:(fun () -> System.close system) (fun () -> f sw system)

let () =
  Eio_main.run @@ fun env ->
  let target = ref None in
  let host_domain = Domain.self () in
  let next =
    definition
      ~decode:(fun text ->
        check
          (Domain.self () <> host_domain)
          "Replacement codec ran on HTTP scheduler domain" ;
        Recovery_model.state.of_string text )
      10
  in
  use
    env
    (definition
       ~reentrant:(fun () -> System.replace (Option.get !target) next)
       1 )
    (fun _ system ->
      target := Some system ;
      expect "Reentrant" (fun () -> System.call system ~flow:"reentrant" empty) ;
      expect "State" (fun () ->
          System.replace system (definition ~version:2 2) ) ;
      expect "State" (fun () ->
          System.replace
            system
            (definition ~decode:(fun _ -> Error "Invalid replacement codec") 2) ) ;
      check
        (member "revision" (System.call system ~flow:"increment" empty) = `Int 1)
        "Failed replace changed code" ) ;
  let fail = ref false in
  let storage =
    Storage.wrap
      (fun ~id:_ backend ->
        { backend with
          commit=
            (fun writes ->
              if !fail then failwith "Injected commit failure" ;
              backend.commit writes ) } )
      Storage.memory
  in
  use env ~storage (definition 1) (fun _ system ->
      ignore (System.call system ~flow:"increment" empty) ;
      fail := true ;
      expect "Store" (fun () -> System.replace system next) ;
      fail := false ;
      check
        (member "n" (System.call system ~flow:"increment" empty) = `Int 2)
        "Store failure changed state or code" ;
      System.replace system next ;
      check
        (member "n" (System.call system ~flow:"increment" empty) = `Int 12)
        "Replace lost state" ) ;
  let entered, entered_u = Eio.Promise.create ()
  and release, release_u = Eio.Promise.create () in
  use
    env
    (definition
       ~hold:(fun () ->
         Eio.Promise.resolve entered_u () ;
         Eio.Promise.await release )
       1 )
    (fun sw system ->
      (* Cancellation of the caller must not make the accepted operation disappear
       from replacement's drain barrier. *)
      Eio.Fiber.first
        (fun () -> ignore (System.call system ~flow:"hold" empty))
        (fun () -> Eio.Promise.await entered) ;
      let switched = ref false and buffered = ref None in
      Eio.Fiber.fork ~sw (fun () ->
          System.replace system next ;
          switched := true ) ;
      Eio.Fiber.yield () ;
      Eio.Fiber.fork ~sw (fun () ->
          buffered := Some (System.call system ~flow:"increment" empty) ) ;
      Eio.Fiber.yield () ;
      check
        ((not !switched) && !buffered = None)
        "Replace bypassed accepted work" ;
      Eio.Promise.resolve release_u () ;
      while !buffered = None do
        Eio.Fiber.yield ()
      done ;
      check
        (!switched && member "revision" (Option.get !buffered) = `Int 10)
        "Buffered call used old code" ) ;
  Eio.Switch.run (fun sw ->
      let runtime =
        Kom_runtime.Runtime.create
          ~sw
          ~domain_mgr:(Eio.Stdenv.domain_mgr env)
          ()
      in
      let cleanups = ref 0 in
      Kom_runtime.Runtime.install
        runtime
        (Kom_runtime.App.define
           ~id:"embedded"
           ~system:(definition 1)
           ~cleanup:(fun () -> incr cleanups)
           () ) ;
      let result =
        Kom_runtime.Runtime.call runtime ~app:"embedded" ~flow:"increment" empty
      in
      check (member "n" result = `Int 1) "Embedded runtime failed" ;
      Kom_runtime.Runtime.close runtime ;
      Kom_runtime.Runtime.close runtime ;
      check (!cleanups = 1) "Cleanup is not once" ;
      expect "Closed" (fun () ->
          Kom_runtime.Runtime.call
            runtime
            ~app:"embedded"
            ~flow:"increment"
            empty ) ) ;
  print_endline
    "PASS replacement codec/store rollback, reentrancy, cancelled caller drain \
     and embedded lifecycle"
