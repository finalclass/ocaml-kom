(** A single process owns each system ID. Snapshot replacement uses a real
    SQLite transaction with WAL and synchronous=FULL. *)
val storage : ?before_commit:(unit -> unit) -> string -> Kom.Storage.t
