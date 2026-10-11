let registration : App.t option Atomic.t option Atomic.t = Atomic.make None

let mutex = Mutex.create ()

let register app =
  match Atomic.get registration with
  | None ->
      raise
        (Kom.Error
           { code= "Plugin"
           ; message= "Registration is only allowed while loading a plugin"
           ; path= None } )
  | Some slot ->
      if not (Atomic.compare_and_set slot None (Some app))
      then
        raise
          (Kom.Error
             { code= "Plugin"
             ; message= "A plugin must register exactly one application"
             ; path= None } )

let load path =
  let slot = Atomic.make None in
  try
    Eio_unix.run_in_systhread (fun () ->
        Mutex.lock mutex ;
        Fun.protect
          ~finally:(fun () ->
            Atomic.set registration None ;
            Mutex.unlock mutex )
          (fun () ->
            Atomic.set registration (Some slot) ;
            ( try Dynlink.loadfile_private path with
            | Dynlink.Error error ->
                raise
                  (Kom.Error
                     { code= "Plugin"
                     ; message= Dynlink.error_message error
                     ; path= Some path } ) ) ;
            match Atomic.get slot with
            | Some app -> app
            | None ->
                raise
                  (Kom.Error
                     { code= "Plugin"
                     ; message= "Plugin did not register an application"
                     ; path= Some path } ) ) )
  with
  | exn ->
      Option.iter
        (fun app ->
          try app.App.cleanup () with
          | error -> prerr_endline (Printexc.to_string error) )
        (Atomic.get slot) ;
      raise exn
