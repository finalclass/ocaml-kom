let () =
  match Sys.argv.(1) with
  | "init-flow" ->
      Kom.(
        run
          (System.define ~cell_kinds:[] ~init_flow:"init" ~flows:[] ())
          (fun _sys -> print_endline "RUN!" ) )
  | "no-path" ->
      raise
        (Kom.Error {code= "Contract"; message= "Expected an integer"; path= None}
        )
  | "path" ->
      raise
        (Kom.Error
           { code= "Contract"
           ; message= "Expected an integer"
           ; path= Some "orders/0/amount" } )
  | "other" -> failwith "ordinary failure"
  | _ -> invalid_arg "Unknown error scenario"
