let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let system =
    Kom.System.create
      ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~id:"recovery"
      ~workers:1
      ~storage:(Kom_sqlite.storage Sys.argv.(1))
      (Recovery_model.definition
         ~marker:Sys.argv.(2)
         ~transactional:(Array.length Sys.argv > 3)
         () )
  in
  ignore (Kom.System.call ~request_id:"crashed" system ~flow:"work" (`Assoc []))
