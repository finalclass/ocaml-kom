let run ?id ?workers ?storage definition f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let system =
    Kom.System.create
      ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ?id
      ?workers
      ?storage
      definition
  in
  Fun.protect (fun () -> f system) ~finally:(fun () -> Kom.System.close system)
