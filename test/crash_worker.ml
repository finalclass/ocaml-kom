let () =
  let system = Kom.System.create ~id:"recovery" ~workers:1
    ~storage:(Kom_sqlite.storage Sys.argv.(1))
    (Recovery_model.definition ~marker:Sys.argv.(2) ()) in
  ignore (Kom.System.call ~request_id:"crashed" system ~flow:"work" (`Assoc []))
