(** Application hosting is separate from the embedded Kom execution engine.
    Native plugins are trusted code; their code is reclaimed on process restart. *)
module Files : sig
  type t

  val read : t -> string -> string option

  val write : t -> string -> string -> unit

  val delete : t -> string -> unit

  val list : t -> string list
end

module Web : sig
  type request =
    { method_: string
    ; target: string
    ; headers: (string * string) list
    ; body: string }

  type response =
    { status: int
    ; headers: (string * string) list
    ; body: string }

  val response :
       ?status:int
    -> ?content_type:string
    -> ?headers:(string * string) list
    -> string
    -> response

  val redirect : string -> response

  val query : string -> (string * string) list

  val encode : string -> string

  val decode : string -> string

  val path : string -> string
end

module App : sig
  type context =
    { system: Kom.System.t
    ; files: Files.t
    ; base_path: string }

  type t

  val define :
       id:string
    -> system:Kom.System.definition
    -> ?http:(context -> Web.request -> Web.response option)
    -> ?cleanup:(unit -> unit)
    -> unit
    -> t
end

module Plugin : sig
  val register : App.t -> unit
  (** Call exactly once from a plugin's initialization. *)
end

module Runtime : sig
  type t

  val create :
       sw:Eio.Switch.t
    -> domain_mgr:_ Eio.Domain_manager.t
    -> ?directory:string
    -> ?workers:int
    -> ?storage:Kom.Storage.t
    -> unit
    -> t

  val install : t -> App.t -> unit

  val load : t -> string -> string

  val remove : t -> string -> unit

  val call :
    ?request_id:string -> t -> app:string -> flow:string -> Kom.msg -> Kom.msg

  val files : t -> app:string -> Files.t

  val apps : t -> Yojson.Safe.t

  val handle :
    t -> app:string -> ?base_path:string -> Web.request -> Web.response

  val close : t -> unit

  val serve :
       sw:Eio.Switch.t
    -> net:_ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> port:int
    -> t
    -> unit
  (** Listen on loopback HTTP and an owner-only Unix control socket. SIGTERM,
      SIGINT and the control command [stop] drain accepted requests. *)
end
