type slot =
  { mutable app: App.t
  ; system: Kom.System.t
  ; files: File_access.t
  ; mutable artifact: string option
  ; gate: Eio.Mutex.t
  ; changed: Eio.Condition.t
  ; mutable paused: bool
  ; mutable removed: bool
  ; mutable active: int }

type t =
  { root: File_access.t
  ; lease: Unix.file_descr
  ; ephemeral: bool
  ; make_system:
      string -> string option -> bool -> Kom.System.definition -> Kom.System.t
  ; generations: (string, string option ref) Hashtbl.t
  ; mutex: Eio.Mutex.t
  ; changes: Eio.Mutex.t
  ; slots: (string, slot) Hashtbl.t
  ; mutable entries: Registry_access.entry list
  ; mutable closing: bool }

let fail code message = raise (Kom.Error {code; message; path= None})

let warn exn =
  prerr_endline ("Kom runtime maintenance: " ^ Printexc.to_string exn)

let cleanup app =
  try app.App.cleanup () with
  | exn -> warn exn

let persist t entries =
  Registry_access.save t.root entries ;
  t.entries <- entries

let put_entry t entry =
  persist
    t
    ( entry
    :: List.filter
         (fun old -> old.Registry_access.id <> entry.Registry_access.id)
         t.entries )

let entry t id =
  List.find_opt (fun entry -> entry.Registry_access.id = id) t.entries

let artifact_path t file =
  if Filename.basename file <> file
  then fail "Registry" "Invalid plugin artifact name" ;
  File_access.resolve t.root ("plugins/" ^ file) ~parents:false

let discard t file =
  try File_access.delete t.root ("plugins/" ^ file) with
  | exn -> warn exn

let unpause slot =
  Eio.Mutex.use_ro slot.gate (fun () ->
      slot.paused <- false ;
      Eio.Condition.broadcast slot.changed )

let pause slot =
  Eio.Mutex.use_ro slot.gate (fun () ->
      slot.paused <- true ;
      while slot.active > 0 do
        Eio.Condition.await slot.changed slot.gate
      done )

let lookup t id =
  Eio.Mutex.use_ro t.mutex (fun () ->
      if t.closing then fail "Closed" "Runtime is closing" ;
      match Hashtbl.find_opt t.slots id with
      | Some slot -> slot
      | None -> fail "App" ("Application not installed: " ^ id) )

let with_slot t id f =
  let slot = lookup t id in
  Eio.Mutex.use_ro slot.gate (fun () ->
      while slot.paused && not slot.removed do
        Eio.Condition.await slot.changed slot.gate
      done ;
      if slot.removed then fail "Closed" "Application is closed" ;
      slot.active <- slot.active + 1 ) ;
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () ->
          Eio.Mutex.use_ro slot.gate (fun () ->
              slot.active <- slot.active - 1 ;
              Eio.Condition.broadcast slot.changed ) ) )
    (fun () -> f slot)

let new_slot ?(restore = false) t app artifact =
  let files = File_access.scope t.root ("apps/" ^ app.App.id ^ "/files") in
  let system = t.make_system app.id artifact restore app.definition in
  { app
  ; system
  ; files
  ; artifact
  ; gate= Eio.Mutex.create ()
  ; changed= Eio.Condition.create ()
  ; paused= false
  ; removed= false
  ; active= 0 }

let add_slot t slot =
  Eio.Mutex.use_ro t.mutex (fun () -> Hashtbl.add t.slots slot.app.id slot)

let replace t slot app artifact =
  pause slot ;
  Fun.protect
    ~finally:(fun () -> unpause slot)
    (fun () ->
      let previous_app = slot.app and previous_artifact = slot.artifact in
      let journal =
        Registry_access.
          {id= app.App.id; current= previous_artifact; pending= artifact}
      in
      Option.iter (fun _ -> put_entry t journal) artifact ;
      let generation = Hashtbl.find t.generations app.id in
      generation := artifact ;
      ( try
          Fun.protect
            ~finally:(fun () -> generation := None)
            (fun () -> Kom.System.replace slot.system app.definition)
        with
      | exn ->
          ( try
              match previous_artifact with
              | Some path ->
                  put_entry t {journal with current= Some path; pending= None}
              | None ->
                  persist
                    t
                    (List.filter
                       (fun e -> e.Registry_access.id <> app.id)
                       t.entries )
            with
          | error -> warn error ) ;
          raise exn ) ;
      slot.app <- app ;
      slot.artifact <- artifact ;
      Option.iter
        (fun path ->
          try put_entry t {journal with current= Some path; pending= None} with
          | exn -> warn exn )
        artifact ;
      cleanup previous_app ;
      Option.iter
        (fun path ->
          if
            previous_artifact <> artifact
            && not
                 (List.exists
                    (fun e ->
                      e.Registry_access.current = Some path
                      || e.pending = Some path )
                    t.entries )
          then discard t path )
        previous_artifact )

let install_internal t app artifact =
  if t.closing then fail "Closed" "Runtime is closing" ;
  match
    Eio.Mutex.use_ro t.mutex (fun () -> Hashtbl.find_opt t.slots app.App.id)
  with
  | Some slot ->
      if artifact = None && slot.artifact <> None
      then fail "Plugin" "Persistent applications must be replaced by a plugin" ;
      replace t slot app artifact
  | None ->
      let previous = entry t app.id in
      let journal =
        Registry_access.
          { id= app.id
          ; current= Option.bind previous (fun entry -> entry.current)
          ; pending= artifact }
      in
      Option.iter (fun _ -> put_entry t journal) artifact ;
      let slot =
        try new_slot t app artifact with
        | exn ->
            ( try
                match previous with
                | Some entry -> put_entry t entry
                | None ->
                    persist
                      t
                      (List.filter
                         (fun entry -> entry.Registry_access.id <> app.id)
                         t.entries )
              with
            | error -> warn error ) ;
            raise exn
      in
      add_slot t slot ;
      Option.iter
        (fun path ->
          try put_entry t {journal with current= Some path; pending= None} with
          | exn -> warn exn )
        artifact

let install t app =
  Eio.Cancel.protect (fun () ->
      Eio.Mutex.use_ro t.changes (fun () ->
          try install_internal t app None with
          | exn ->
              cleanup app ;
              raise exn ) )

let load t source =
  Eio.Cancel.protect (fun () ->
      Eio.Mutex.use_ro t.changes (fun () ->
          if t.closing then fail "Closed" "Runtime is closing" ;
          let path =
            File_access.copy_plugin
              (Filename.concat t.root.root "plugins")
              source
          in
          let file = Filename.basename path in
          let app =
            try Plugin_access.load path with
            | exn ->
                discard t file ;
                raise exn
          in
          try
            install_internal t app (Some file) ;
            app.App.id
          with
          | exn ->
              cleanup app ;
              if
                not
                  (List.exists
                     (fun e ->
                       e.Registry_access.current = Some file
                       || e.pending = Some file )
                     t.entries )
              then discard t file ;
              raise exn ) )

let remove t id =
  Eio.Cancel.protect (fun () ->
      Eio.Mutex.use_ro t.changes (fun () ->
          let slot = lookup t id in
          pause slot ;
          Fun.protect
            ~finally:(fun () -> unpause slot)
            (fun () ->
              persist
                t
                (List.filter
                   (fun entry -> entry.Registry_access.id <> id)
                   t.entries ) ;
              Fun.protect
                ~finally:(fun () ->
                  cleanup slot.app ;
                  Eio.Mutex.use_ro slot.gate (fun () ->
                      slot.removed <- true ;
                      Eio.Condition.broadcast slot.changed ) ;
                  Eio.Mutex.use_ro t.mutex (fun () -> Hashtbl.remove t.slots id) ;
                  Hashtbl.remove t.generations id ;
                  Option.iter (discard t) slot.artifact )
                (fun () -> Kom.System.close slot.system) ) ) )

let call ?request_id t ~app ~flow msg =
  with_slot t app (fun slot ->
      Kom.System.call ?request_id slot.system ~flow msg )

let files t ~app = with_slot t app (fun slot -> slot.files)

let apps t =
  Eio.Mutex.use_ro t.mutex (fun () ->
      Hashtbl.to_seq_values t.slots
      |> List.of_seq
      |> List.sort (fun a b -> String.compare a.app.id b.app.id)
      |> List.map (fun slot ->
          `Assoc
            [ ("id", `String slot.app.id)
            ; ("catalog", Kom.System.catalog slot.system)
            ; ("paused", `Bool slot.paused)
            ; ( "plugin"
              , Option.fold ~none:`Null ~some:(fun f -> `String f) slot.artifact
              ) ] )
      |> fun apps -> `List apps )

let close t =
  Eio.Cancel.protect (fun () ->
      Eio.Mutex.use_ro t.changes (fun () ->
          if not t.closing
          then (
            t.closing <- true ;
            let slots =
              Eio.Mutex.use_ro t.mutex (fun () ->
                  Hashtbl.to_seq_values t.slots |> List.of_seq )
            in
            Fun.protect
              ~finally:(fun () ->
                File_access.release t.root t.lease ;
                if t.ephemeral then File_access.remove_tree t.root.root )
              (fun () ->
                let failure = ref None in
                List.iter
                  (fun slot ->
                    try
                      pause slot ;
                      Fun.protect
                        ~finally:(fun () ->
                          cleanup slot.app ;
                          Eio.Mutex.use_ro slot.gate (fun () ->
                              slot.removed <- true ;
                              slot.paused <- false ;
                              Eio.Condition.broadcast slot.changed ) )
                        (fun () -> Kom.System.close slot.system)
                    with
                    | exn -> if !failure = None then failure := Some exn )
                  slots ;
                Hashtbl.clear t.slots ;
                Hashtbl.clear t.generations ;
                Option.iter raise !failure ) ) ) )

let restore t entry =
  let open Registry_access in
  let open_artifact file =
    let app = Plugin_access.load (artifact_path t file) in
    if app.App.id <> entry.id
    then (
      cleanup app ;
      fail "Registry" "Plugin application ID differs from registry" ) ;
    try new_slot ~restore:true t app (Some file) with
    | exn ->
        cleanup app ;
        raise exn
  in
  let selected_slot =
    match (entry.pending, entry.current) with
    | Some pending, current -> (
      try Some (pending, open_artifact pending) with
      | error -> (
        match current with
        | Some current ->
            warn error ;
            Some (current, open_artifact current)
        | None -> (
          match error with
          | Kom.Error {code= "Generation"; _} ->
              persist t (List.filter (fun e -> e.id <> entry.id) t.entries) ;
              discard t pending ;
              None
          | _ -> raise error ) ) )
    | None, Some current -> Some (current, open_artifact current)
    | None, None -> fail "Registry" "Registry entry has no artifact"
  in
  Option.iter
    (fun (selected, slot) ->
      add_slot t slot ;
      put_entry t {entry with current= Some selected; pending= None} ;
      List.iter
        (fun file -> if file <> selected then discard t file)
        (List.filter_map Fun.id [entry.current; entry.pending]) )
    selected_slot

let create ~sw ~domain_mgr ?directory ?(workers = 4) ?storage () =
  Eio.Switch.check sw ;
  let ephemeral = directory = None in
  let directory =
    match directory with
    | Some path -> path
    | None ->
        let path = Filename.temp_file "kom-runtime-" "" in
        Sys.remove path ;
        path
  in
  let root = File_access.open_ directory in
  let t =
    Eio.Cancel.protect (fun () ->
        let lease = File_access.claim root in
        let storage =
          Option.value
            ~default:
              ( if ephemeral
                then Kom.Storage.memory
                else
                  Kom_sqlite.storage (Filename.concat root.root "data.sqlite")
              )
            storage
        in
        let generations = Hashtbl.create 8 in
        let make_system id artifact restore definition =
          let generation = ref artifact in
          let storage =
            Kom.Storage.wrap
              (fun ~id:_ backend ->
                ( if restore
                  then
                    match
                      (backend.Kom.Storage.get "runtime/plugin", artifact)
                    with
                    | Some stored, Some expected when stored <> expected ->
                        fail "Generation" "Plugin generation was not committed"
                    | None, Some _ ->
                        fail
                          "Generation"
                          "Plugin installation was not committed"
                    | _ -> () ) ;
                Hashtbl.replace generations id generation ;
                { backend with
                  commit=
                    (fun writes ->
                      let writes =
                        match !generation with
                        | Some artifact when List.mem_assoc "system" writes ->
                            ("runtime/plugin", Some artifact) :: writes
                        | _ -> writes
                      in
                      backend.commit writes ) } )
              storage
          in
          Fun.protect
            ~finally:(fun () -> generation := None)
            (fun () ->
              Kom.System.create ~sw ~domain_mgr ~workers ~id ~storage definition )
        in
        let t =
          { root
          ; lease
          ; ephemeral
          ; make_system
          ; generations
          ; mutex= Eio.Mutex.create ()
          ; changes= Eio.Mutex.create ()
          ; slots= Hashtbl.create 8
          ; entries= []
          ; closing= false }
        in
        ( try Eio.Switch.on_release sw (fun () -> close t) with
        | exn ->
            close t ;
            raise exn ) ;
        t )
  in
  try
    t.entries <- Registry_access.load root ;
    let ids = List.map (fun entry -> entry.Registry_access.id) t.entries in
    if List.length ids <> List.length (List.sort_uniq String.compare ids)
    then fail "Registry" "Duplicate application ID" ;
    List.iter (restore t) t.entries ;
    t
  with
  | exn ->
      close t ;
      raise exn

let mime path =
  match String.lowercase_ascii (Filename.extension path) with
  | ".html" -> "text/html; charset=utf-8"
  | ".js" -> "application/javascript; charset=utf-8"
  | ".css" -> "text/css; charset=utf-8"
  | ".json" -> "application/json"
  | ".png" -> "image/png"
  | ".jpg"
   |".jpeg" ->
      "image/jpeg"
  | ".svg" -> "image/svg+xml"
  | _ -> "application/octet-stream"

let handle t ~app ?(base_path = "") request =
  with_slot t app (fun slot ->
      let path = Web.path request.Web.target in
      if request.method_ = "POST" && path = "/rpc"
      then
        let content_type =
          Option.value
            ~default:""
            (List.assoc_opt "content-type" request.headers)
          |> String.split_on_char ';'
          |> List.hd
          |> String.trim
          |> String.lowercase_ascii
        in
        if content_type <> "application/json"
        then Web.response ~status:415 "Expected application/json"
        else
          match Rpc.rpc slot.system request.body with
          | None -> Web.response ~status:204 ""
          | Some msg ->
              Web.response
                ~content_type:"application/json"
                (Yojson.Safe.to_string msg)
      else if request.method_ = "GET" && path = "/catalog"
      then
        Web.response
          ~content_type:"application/json"
          (Yojson.Safe.to_string (Kom.System.catalog slot.system))
      else
        let static path =
          if request.method_ <> "GET"
          then Web.response ~status:404 "Not found"
          else
            let path =
              if path = "/"
              then "index.html"
              else Web.decode (String.sub path 1 (String.length path - 1))
            in
            match File_access.read slot.files path with
            | None -> Web.response ~status:404 "Not found"
            | Some body ->
                Web.response
                  ~content_type:(mime path)
                  ~headers:[("X-Content-Type-Options", "nosniff")]
                  body
        in
        if String.starts_with ~prefix:"/files/" path
        then static (String.sub path 6 (String.length path - 6))
        else
          match
            slot.app.http
              App.{system= slot.system; files= slot.files; base_path}
              request
          with
          | Some response -> response
          | None -> static path )
