open Kom

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

let cell =
  Cell.define
    { id= "counter"
    ; state= (module State)
    ; operations=
        [ Cell.transformer
            ~id:"add"
            ~input:(module Add)
            ~output:(Output.patch (module Value))
            ~impl:(fun _db state msg ->
              let value = state + (Msg.data msg).amount in
              (value, Value.{value}) )
        ; Cell.transformer
            ~id:"read"
            ~input:(module Empty)
            ~output:(Output.patch (module Value))
            ~impl:(fun _db state _msg -> (state, Value.{value= state})) ] }
