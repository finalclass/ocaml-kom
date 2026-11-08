open Kom

module Counter = struct
  module State = struct
    type t = int [@@deriving yojson]

    let version = 1

    let init () = 0
  end

  module Add = struct
    type t = {amount: int} [@@deriving kom]
  end

  module Empty = struct
    type t = unit [@@deriving kom]
  end

  module Value = struct
    type t = {value: int} [@@deriving kom]
  end

  let add _db (state : State.t) (msg : Add.t Kom.Msg.t) : State.t * Value.t =
    let value = state + (Msg.data msg).amount in
    (value, Value.{value})
  [@@kom.transformer {output= patch}]

  let read _db (state : State.t) (_msg : Empty.t Kom.Msg.t) : State.t * Value.t
      =
    (state, Value.{value= state})
  [@@kom.transformer {output= patch}]
end
[@@kom.cell {id= "counter"}]

include Counter
