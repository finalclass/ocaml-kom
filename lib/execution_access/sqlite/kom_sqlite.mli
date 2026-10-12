val storage : ?before_commit:(unit -> unit) -> string -> Kom.Storage.t
(** Each open System has its own connection, with one owner per database and
    System ID. Kom serializes access to that connection. Commits use SQLite
    transactions with WAL and synchronous=FULL. Blocking SQLite work runs in
    Eio system threads; before_commit runs in that same thread. *)
