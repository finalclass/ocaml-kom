(** Entry point for standalone Kom programs. *)

val run :
     ?id:string
  -> ?workers:int
  -> ?storage:Kom.Storage.t
  -> Kom.System.definition
  -> (Kom.System.t -> 'a)
  -> 'a
(** [run definition f] starts an execution environment, creates a System and
    returns [f system]. It closes the System before returning or propagating an
    exception. The System is only usable within the callback.

    Options have the same defaults as {!Kom.System.create}: [id = "main"],
    [workers = 4] and in-memory storage.

    Use this at the program's entry point, outside any existing Eio event loop.
    Programs already using Eio should use {!Kom.System.create} with their own
    switch and domain manager. Blocking IO in the callback or cell handlers
    does not become asynchronous. *)
