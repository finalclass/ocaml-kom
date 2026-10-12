open Kom
open Yojson.Safe.Util

let check condition message = if not condition then failwith message

let empty = `Assoc []

let with_database f =
  let path = Filename.temp_file "kom-connections-" ".sqlite" in
  Sys.remove path ;
  Fun.protect
    (fun () -> f path)
    ~finally:(fun () ->
      Sys.readdir (Filename.dirname path)
      |> Array.iter (fun name ->
          if String.starts_with ~prefix:(Filename.basename path) name
          then Sys.remove (Filename.concat (Filename.dirname path) name) ) )

let definition =
  let view =
    Db.view
      { id= "values"
      ; version= 1
      ; key= Db.int
      ; map= (fun row -> Some (row |> member "n" |> to_int, row)) }
  in
  let cell =
    Cell.define
      ~views:[Db.View view]
      { id= "counter"
      ; state= Recovery_model.state
      ; operations=
          List.map
            (fun (op, increment) ->
              Cell.Transformer
                { op
                ; input= []
                ; output= [("n", Schema.Int)]
                ; impl=
                    (fun db state _ ->
                      let stored = Db.get db ~id:"value" in
                      check
                        ( Option.map (fun row -> member "n" row) stored
                        = if state = 0 then None else Some (`Int state) )
                        "Document differs from committed cell state" ;
                      let next = state + increment in
                      let result = `Assoc [("n", `Int next)] in
                      if increment <> 0 then Db.put db ~id:"value" result ;
                      let page = Db.query db view (fun (n, _) -> Some n) in
                      check
                        (page.items = if next = 0 then [] else [next])
                        "View differs from document" ;
                      (next, result) ) } )
            [("increment", 1); ("read", 0)] }
  in
  let flow id output body = Flow.define {id; input= []; output; body} in
  System.define
    ~cell_kinds:[cell]
    ~init_flow:"init"
    ~flows:
      ( flow
          "init"
          []
          "!sequence(!reproduce counter as a !reproduce counter as b)"
      :: List.concat_map
           (fun address ->
             List.map
               (fun op ->
                 flow
                   (op ^ "_" ^ address)
                   [("n", Schema.Int)]
                   (op ^ " @" ^ address) )
               ["increment"; "read"] )
           ["a"; "b"] )
    ()

let test_serialization env =
  with_database @@ fun path ->
  let active = Atomic.make false in
  let gets = Atomic.make 0
  and scans = Atomic.make 0
  and commits = Atomic.make 0
  and closes = Atomic.make 0 in
  let guard count f =
    check
      (Atomic.compare_and_set active false true)
      "Concurrent operations reached the same SQLite backend" ;
    Fun.protect
      ~finally:(fun () -> Atomic.set active false)
      (fun () ->
        ignore (Atomic.fetch_and_add count 1) ;
        Eio.Fiber.yield () ;
        f () )
  in
  let storage =
    Storage.wrap
      (fun ~id:_ backend ->
        { Storage.get= (fun key -> guard gets (fun () -> backend.get key))
        ; scan= (fun range -> guard scans (fun () -> backend.scan range))
        ; commit= (fun writes -> guard commits (fun () -> backend.commit writes))
        ; close= (fun () -> guard closes backend.close) } )
      (Kom_sqlite.storage path)
  in
  Eio.Switch.run (fun sw ->
      let system =
        System.create
          ~sw
          ~domain_mgr:(Eio.Stdenv.domain_mgr env)
          ~workers:4
          ~storage
          definition
      in
      Fun.protect
        ~finally:(fun () -> System.close system)
        (fun () ->
          Eio.Fiber.all
            (List.init 40 (fun i () ->
                 let flow =
                   if i mod 2 = 0 then "increment_a" else "increment_b"
                 in
                 ignore (System.call system ~flow empty) ) ) ;
          List.iter
            (fun flow ->
              check
                (member "n" (System.call system ~flow empty) = `Int 20)
                "Parallel operations lost a committed update" )
            ["read_a"; "read_b"] ) ) ;
  check
    (Atomic.get gets > 0 && Atomic.get scans > 0 && Atomic.get commits > 0)
    "The test did not exercise every backend operation" ;
  check (Atomic.get closes = 1) "Backend was not closed exactly once"

let test_connections env =
  with_database @@ fun path ->
  let entered, enter = Eio.Promise.create () in
  let second_entered, second_enter = Eio.Promise.create () in
  let armed = Atomic.make false in
  let mutex = Mutex.create () and changed = Condition.create () in
  let released = ref false in
  let release () =
    Mutex.lock mutex ;
    released := true ;
    Condition.broadcast changed ;
    Mutex.unlock mutex
  in
  let before_commit () =
    if Atomic.exchange armed false
    then (
      Eio.Promise.resolve enter () ;
      Mutex.lock mutex ;
      while not !released do
        Condition.wait changed mutex
      done ;
      Mutex.unlock mutex )
  in
  let backends = ref [] in
  let storage =
    Storage.wrap
      (fun ~id backend ->
        backends := (id, backend) :: !backends ;
        backend )
      (Kom_sqlite.storage ~before_commit path)
  in
  Eio.Switch.run @@ fun sw ->
  let create id =
    System.create
      ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~id
      ~workers:1
      ~storage
      definition
  in
  let first = create "first" in
  Fun.protect ~finally:(fun () -> System.close first) @@ fun () ->
  let second = create "second" in
  Fun.protect ~finally:(fun () -> System.close second) @@ fun () ->
  check (List.length !backends = 2) "Systems reused an open backend" ;
  let a = List.assoc "first" !backends and b = List.assoc "second" !backends in
  check (a != b) "Systems share a backend" ;
  a.commit [("probe", Some "old-first")] ;
  b.commit [("probe", Some "old-second")] ;
  Atomic.set armed true ;
  let writer =
    Eio.Fiber.fork_promise ~sw (fun () ->
        a.commit [("probe", Some "new-first")] )
  in
  let other =
    Fun.protect ~finally:release (fun () ->
        Eio.Promise.await entered ;
        check
          (b.get "probe" = Some "old-second")
          "Another connection could not read during the open transaction" ;
        let observed =
          Eio_unix.run_in_systhread (fun () ->
              let reader = Sqlite3.db_open path in
              Fun.protect
                ~finally:(fun () -> ignore (Sqlite3.db_close reader))
                (fun () ->
                  let rows = ref [] in
                  Sqlite3.Rc.check
                    (Sqlite3.exec
                       reader
                       ~cb:(fun row _ -> rows := row :: !rows)
                       "SELECT value FROM kom_kv WHERE system='first' AND \
                        key='probe'" ) ;
                  !rows ) )
        in
        check
          (observed = [[|Some "old-first"|]])
          "Uncommitted data escaped the first connection" ;
        let other =
          Eio.Fiber.fork_promise ~sw (fun () ->
              Eio.Promise.resolve second_enter () ;
              b.commit [("probe", Some "new-second")] )
        in
        Eio.Promise.await second_entered ;
        other )
  in
  Eio.Promise.await_exn writer ;
  Eio.Promise.await_exn other ;
  check (a.get "probe" = Some "new-first") "First commit was lost" ;
  check (b.get "probe" = Some "new-second") "Second commit was lost" ;
  Eio.Fiber.both
    (fun () -> ignore (System.call first ~flow:"increment_a" empty))
    (fun () -> ignore (System.call second ~flow:"increment_a" empty)) ;
  List.iter
    (fun system ->
      check
        (member "n" (System.call system ~flow:"read_a" empty) = `Int 1)
        "Systems did not preserve independent cell state" )
    [first; second]

let () =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () ->
      test_serialization env ;
      print_endline "PASS SQLite backend serialization" ;
      test_connections env ;
      print_endline "PASS SQLite independent connections and commit isolation" )
