(* A whole compilation unit as a cell: the floating attribute replaces the
   module wrapper, and the file name is the default cell ID. *)
[@@@kom.cell]

module State = struct
  type t = int [@@deriving yojson]

  let version = 1

  let init () = 0
end

module Empty = struct
  type t = unit [@@deriving kom]
end

module Count = struct
  type t = {count: int} [@@deriving kom]
end

let bump _db (state : State.t) (_msg : Empty.t Kom.Msg.t) : State.t * Count.t =
  (state + 1, {count= state + 1})
[@@kom.transformer {output= patch}]
