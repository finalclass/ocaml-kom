open Kom
open Yojson.Safe.Util

let result value message =
  `Assoc (("value", `Int value) :: List.remove_assoc "value" (to_assoc message))

let cell =
  Cell.define
    { id= "counter"
    ; state=
        { version= 1
        ; init= (fun () -> 0)
        ; to_string= string_of_int
        ; of_string=
            (fun text ->
              match int_of_string_opt text with
              | Some value -> Ok value
              | None -> Error "Invalid counter state" ) }
    ; operations=
        [ Cell.Transformer
            { op= "add"
            ; input= [("amount", Schema.Int)]
            ; output= [("value", Schema.Int)]
            ; impl=
                (fun _db state message ->
                  let value = state + (message |> member "amount" |> to_int) in
                  (value, result value message) ) }
        ; Cell.Transformer
            { op= "read"
            ; input= []
            ; output= [("value", Schema.Int)]
            ; impl= (fun _db state message -> (state, result state message)) }
        ] }
