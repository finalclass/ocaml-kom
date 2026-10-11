let owners = Hashtbl.create 16

let ownership_mutex = Mutex.create ()

let claim key =
  Mutex.lock ownership_mutex ;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock ownership_mutex)
    (fun () ->
      if Hashtbl.mem owners key
      then failwith "SQLite System.id already has a live owner" ;
      Hashtbl.add owners key () )

let unclaim key =
  Mutex.lock ownership_mutex ;
  Hashtbl.remove owners key ;
  Mutex.unlock ownership_mutex

let storage ?(before_commit = fun () -> ()) path =
  Kom.Storage.backend (fun id ->
      Eio.Cancel.protect (fun () ->
          Eio_unix.run_in_systhread (fun () ->
              let path =
                if Sys.file_exists path
                then Unix.realpath path
                else
                  Filename.concat
                    (Unix.realpath (Filename.dirname path))
                    (Filename.basename path)
              in
              let key =
                Yojson.Safe.to_string (`List [`String path; `String id])
              in
              claim key ;
              let lock_path =
                path ^ "." ^ Digest.to_hex (Digest.string id) ^ ".lock"
              in
              let fd =
                try
                  Unix.openfile lock_path [Unix.O_CREAT; Unix.O_RDWR] 0o600
                with
                | exn ->
                    unclaim key ;
                    raise exn
              in
              ( try Unix.lockf fd Unix.F_TLOCK 0 with
              | exn ->
                  Unix.close fd ;
                  unclaim key ;
                  raise exn ) ;
              let db =
                try Sqlite3.db_open path with
                | exn ->
                    Unix.close fd ;
                    unclaim key ;
                    raise exn
              in
              let closed = ref false in
              let close () =
                if not !closed
                then (
                  closed := true ;
                  ignore (Sqlite3.db_close db) ;
                  Unix.close fd ;
                  unclaim key )
              in
              let exec sql =
                match Sqlite3.exec db sql with
                | Sqlite3.Rc.OK -> ()
                | rc ->
                    failwith (Sqlite3.Rc.to_string rc ^ ": " ^ Sqlite3.errmsg db)
              in
              let statement sql bindings f =
                let stmt = Sqlite3.prepare db sql in
                Fun.protect
                  ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
                  (fun () ->
                    List.iteri
                      (fun i v -> Sqlite3.Rc.check (Sqlite3.bind stmt (i + 1) v))
                      bindings ;
                    f stmt )
              in
              try
                Sqlite3.busy_timeout db 5000 ;
                exec "PRAGMA journal_mode=WAL" ;
                exec "PRAGMA synchronous=FULL" ;
                let text s = Sqlite3.Data.TEXT s in
                let legacy =
                  statement
                    "SELECT name FROM sqlite_master WHERE type='table' AND \
                     name='kom_systems'"
                    []
                    (fun stmt -> Sqlite3.step stmt = Sqlite3.Rc.ROW )
                in
                ( if legacy
                  then
                    let exists =
                      statement
                        "SELECT 1 FROM kom_systems WHERE id=?"
                        [text id]
                        (fun stmt -> Sqlite3.step stmt = Sqlite3.Rc.ROW)
                    in
                    if exists
                    then
                      failwith
                        "Unsupported legacy Kom snapshot store; use a new \
                         database" ) ;
                exec
                  "CREATE TABLE IF NOT EXISTS kom_kv (system TEXT NOT NULL, \
                   key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY \
                   KEY(system,key)) WITHOUT ROWID" ;
                let get key =
                  statement
                    "SELECT value FROM kom_kv WHERE system=? AND key=?"
                    [text id; text key]
                    (fun stmt ->
                      match Sqlite3.step stmt with
                      | ROW -> Some (Sqlite3.column_text stmt 0)
                      | DONE -> None
                      | rc ->
                          Sqlite3.Rc.check rc ;
                          None )
                in
                let scan (range : Kom.Storage.range) =
                  let clauses = ref ["system=?"; "key>=?"; "key<?"] in
                  let bindings =
                    ref [text id; text range.prefix; text (range.prefix ^ "~")]
                  in
                  let bound clause value =
                    Option.iter
                      (fun value ->
                        clauses := !clauses @ [clause] ;
                        bindings := !bindings @ [text value] )
                      value
                  in
                  bound "key>=?" range.first ;
                  bound "key<=?" range.last ;
                  bound "key>?" range.after ;
                  statement
                    ( "SELECT key,value FROM kom_kv WHERE "
                    ^ String.concat " AND " !clauses
                    ^ " ORDER BY key LIMIT ?" )
                    (!bindings @ [Sqlite3.Data.INT (Int64.of_int range.limit)])
                    (fun stmt ->
                      let rec rows acc =
                        match Sqlite3.step stmt with
                        | ROW ->
                            rows
                              ( ( Sqlite3.column_text stmt 0
                                , Sqlite3.column_text stmt 1 )
                              :: acc )
                        | DONE -> List.rev acc
                        | rc ->
                            Sqlite3.Rc.check rc ;
                            assert false
                      in
                      rows [] )
                in
                let commit writes =
                  exec "BEGIN IMMEDIATE" ;
                  try
                    List.iter
                      (fun (key, value) ->
                        match value with
                        | None ->
                            statement
                              "DELETE FROM kom_kv WHERE system=? AND key=?"
                              [text id; text key]
                              (fun stmt -> Sqlite3.Rc.check (Sqlite3.step stmt))
                        | Some value ->
                            statement
                              "INSERT INTO kom_kv(system,key,value) \
                               VALUES(?,?,?) ON CONFLICT(system,key) DO UPDATE \
                               SET value=excluded.value"
                              [text id; text key; text value]
                              (fun stmt -> Sqlite3.Rc.check (Sqlite3.step stmt)) )
                      writes ;
                    before_commit () ;
                    exec "COMMIT"
                  with
                  | exn ->
                      ( try exec "ROLLBACK" with
                      | _ -> () ) ;
                      raise exn
                in
                Kom.Storage.
                  { get=
                      (fun key -> Eio_unix.run_in_systhread (fun () -> get key))
                  ; scan=
                      (fun range ->
                        Eio_unix.run_in_systhread (fun () -> scan range) )
                  ; commit=
                      (fun writes ->
                        Eio_unix.run_in_systhread (fun () -> commit writes) )
                  ; close= (fun () -> Eio_unix.run_in_systhread close) }
              with
              | exn ->
                  close () ;
                  raise exn ) ) )
