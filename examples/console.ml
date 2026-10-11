let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime =
    Kom_runtime.Runtime.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ()
  in
  Kom_runtime.Runtime.install runtime Todo_app.app ;
  ignore
    (Kom_runtime.Runtime.call
       runtime
       ~app:"todo"
       ~flow:"add_task"
       (`Assoc [("name", `String "Embedded example")]) ) ;
  Kom_runtime.Runtime.call runtime ~app:"todo" ~flow:"list_tasks" (`Assoc [])
  |> Yojson.Safe.pretty_to_string
  |> print_endline ;
  Kom_runtime.Runtime.close runtime
