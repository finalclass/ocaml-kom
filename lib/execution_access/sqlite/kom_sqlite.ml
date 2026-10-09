let owners=Hashtbl.create 16
let ownership_mutex=Mutex.create ()
let claim key =
  Mutex.lock ownership_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock ownership_mutex) (fun () ->
    if Hashtbl.mem owners key then failwith "SQLite System.id already has a live owner";
    Hashtbl.add owners key ())
let unclaim key = Mutex.lock ownership_mutex;Hashtbl.remove owners key;Mutex.unlock ownership_mutex
let storage ?(before_commit=fun () -> ()) path =
  Kom.Storage.Backend (path,fun id ->
    let path=if Sys.file_exists path then Unix.realpath path else Filename.concat (Unix.realpath (Filename.dirname path)) (Filename.basename path) in
    let key=Yojson.Safe.to_string (`List [`String path;`String id]) in
    claim key;
    let lock_path=path ^ "." ^ Digest.to_hex (Digest.string id) ^ ".lock" in
    let fd=try Unix.openfile lock_path [Unix.O_CREAT;Unix.O_RDWR] 0o600 with exn -> unclaim key;raise exn in
    (try Unix.lockf fd Unix.F_TLOCK 0 with exn -> Unix.close fd;unclaim key;raise exn);
    let db=try Sqlite3.db_open path with exn -> Unix.close fd;unclaim key;raise exn in
    let closed=ref false in
    let close () = if not !closed then (
      closed := true;ignore (Sqlite3.db_close db);Unix.close fd;unclaim key) in
    let exec sql = match Sqlite3.exec db sql with
      | Sqlite3.Rc.OK -> () | rc -> failwith (Sqlite3.Rc.to_string rc ^ ": " ^ Sqlite3.errmsg db) in
    let statement sql bindings f =
      let stmt=Sqlite3.prepare db sql in
      Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
        List.iteri (fun i v -> Sqlite3.Rc.check (Sqlite3.bind stmt (i+1) v)) bindings;
        f stmt) in
    try
      Sqlite3.busy_timeout db 5000;
      exec "PRAGMA journal_mode=WAL";exec "PRAGMA synchronous=FULL";
      exec "CREATE TABLE IF NOT EXISTS kom_systems (id TEXT PRIMARY KEY, snapshot TEXT NOT NULL)";
      let load () = statement "SELECT snapshot FROM kom_systems WHERE id=?" [Sqlite3.Data.TEXT id] (fun stmt ->
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW -> Some (Sqlite3.column_text stmt 0)
        | DONE -> None | rc -> Sqlite3.Rc.check rc;None) in
      let save snapshot =
        exec "BEGIN IMMEDIATE";
        try
          statement "INSERT INTO kom_systems(id,snapshot) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET snapshot=excluded.snapshot"
            [Sqlite3.Data.TEXT id;TEXT snapshot] (fun stmt -> match Sqlite3.step stmt with
              | Sqlite3.Rc.DONE -> () | rc -> Sqlite3.Rc.check rc);
          before_commit ();exec "COMMIT"
        with exn -> (try exec "ROLLBACK" with _ -> ());raise exn in
      Kom.Storage.{load;save;close}
    with exn -> close ();raise exn)
