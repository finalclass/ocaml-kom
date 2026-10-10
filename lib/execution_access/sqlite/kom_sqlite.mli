(** A single process owns each system ID. Snapshot replacement uses a real
    SQLite transaction with WAL and synchronous=FULL. Blocking SQLite work
    runs in Eio system threads; before_commit runs in that same thread. *)
val storage : ?before_commit:(unit -> unit) -> string -> Kom.Storage.t
