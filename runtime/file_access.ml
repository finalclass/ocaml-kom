type t = {root: string}

let fail message = raise (Kom.Error {code= "Files"; message; path= None})

let io f = Eio_unix.run_in_systhread f

let segments path =
  let segments = String.split_on_char '/' path in
  if
    List.exists
      (fun segment ->
        segment = ""
        || segment = "."
        || segment = ".."
        || String.contains segment '\\'
        || String.contains segment '\000' )
      segments
  then fail "Expected a relative file path without traversal" ;
  segments

let rec mkdir path =
  if Sys.file_exists path
  then (
    if (Unix.lstat path).st_kind <> Unix.S_DIR
    then fail "Expected a directory without symlinks" )
  else (
    mkdir (Filename.dirname path) ;
    try Unix.mkdir path 0o700 with
    | Unix.Unix_error (Unix.EEXIST, _, _) ->
        if (Unix.lstat path).st_kind <> Unix.S_DIR
        then fail "Expected a directory without symlinks" )

let open_ root =
  io (fun () ->
      mkdir root ;
      {root= Unix.realpath root} )

let scope t path =
  io (fun () ->
      let root =
        List.fold_left
          (fun current part ->
            let next = Filename.concat current part in
            mkdir next ;
            if (Unix.lstat next).st_kind <> Unix.S_DIR
            then fail "Expected a directory without symlinks" ;
            next )
          t.root
          (segments path)
      in
      {root} )

let resolve t path ~parents =
  let parts = segments path in
  let rec walk current = function
    | [] -> current
    | part :: rest ->
        let next = Filename.concat current part in
        ( try
            let info = Unix.lstat next in
            if info.st_kind = Unix.S_LNK then fail "Symlinks are not allowed" ;
            if rest <> [] && info.st_kind <> Unix.S_DIR
            then fail "Expected a directory" ;
            if rest = [] && info.st_kind <> Unix.S_REG
            then fail "Expected a regular file"
          with
        | Unix.Unix_error (Unix.ENOENT, _, _) ->
            if parents && rest <> [] then mkdir next ) ;
        walk next rest
  in
  walk t.root parts

let sync_directory directory =
  let fd = Unix.openfile directory [Unix.O_RDONLY] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)

let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () -> really_input_string input (in_channel_length input))

let read t path =
  io (fun () ->
      let path = resolve t path ~parents:false in
      try Some (read_file path) with
      | Sys_error _ when not (Sys.file_exists path) -> None )

let write t path contents =
  io (fun () ->
      let path = resolve t path ~parents:true in
      let directory = Filename.dirname path in
      let temporary, output =
        Filename.open_temp_file ~temp_dir:directory ".kom-write-" ".tmp"
      in
      Fun.protect
        ~finally:(fun () ->
          close_out_noerr output ;
          if Sys.file_exists temporary then Sys.remove temporary )
        (fun () ->
          output_string output contents ;
          flush output ;
          Unix.fsync (Unix.descr_of_out_channel output) ;
          close_out output ;
          Unix.rename temporary path ;
          sync_directory directory ) )

let delete t path =
  io (fun () ->
      let path = resolve t path ~parents:false in
      try
        Unix.unlink path ;
        sync_directory (Filename.dirname path)
      with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> () )

let list t =
  io (fun () ->
      let rec walk directory prefix =
        Sys.readdir directory
        |> Array.to_list
        |> List.concat_map (fun name ->
            let path = Filename.concat directory name in
            let relative = if prefix = "" then name else prefix ^ "/" ^ name in
            match (Unix.lstat path).st_kind with
            | Unix.S_DIR -> walk path relative
            | Unix.S_REG
              when not (String.starts_with ~prefix:".kom-write-" name) ->
                [relative]
            | Unix.S_LNK -> fail "Symlinks are not allowed"
            | _ -> [] )
      in
      List.sort String.compare (walk t.root "") )

let import t path source = write t path (io (fun () -> read_file source))

let copy_plugin directory source =
  io (fun () ->
      let contents = read_file source in
      mkdir directory ;
      let path, output =
        Filename.open_temp_file ~temp_dir:directory "plugin-" ".cmxs"
      in
      Fun.protect
        ~finally:(fun () -> close_out_noerr output)
        (fun () ->
          output_string output contents ;
          flush output ;
          Unix.fsync (Unix.descr_of_out_channel output) ;
          close_out output ;
          sync_directory directory ;
          path ) )

let owners = Hashtbl.create 8

let ownership_mutex = Mutex.create ()

let claim t =
  io (fun () ->
      Mutex.lock ownership_mutex ;
      Fun.protect
        ~finally:(fun () -> Mutex.unlock ownership_mutex)
        (fun () ->
          if Hashtbl.mem owners t.root
          then fail "Runtime directory already has an owner" ;
          let fd =
            Unix.openfile
              (Filename.concat t.root "runtime.lock")
              [Unix.O_CREAT; Unix.O_RDWR]
              0o600
          in
          ( try Unix.lockf fd Unix.F_TLOCK 0 with
          | exn ->
              Unix.close fd ;
              raise exn ) ;
          Hashtbl.add owners t.root () ;
          fd ) )

let release t fd =
  io (fun () ->
      Mutex.lock ownership_mutex ;
      Fun.protect
        ~finally:(fun () -> Mutex.unlock ownership_mutex)
        (fun () ->
          Unix.close fd ;
          Hashtbl.remove owners t.root ) )

let remove_tree directory =
  io (fun () ->
      let rec remove path =
        match (Unix.lstat path).st_kind with
        | Unix.S_DIR ->
            Sys.readdir path
            |> Array.iter (fun name -> remove (Filename.concat path name)) ;
            Unix.rmdir path
        | _ -> Unix.unlink path
      in
      remove directory )
