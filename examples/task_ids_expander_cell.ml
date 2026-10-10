open Kom
open Kom.Cell
open Kom.Schema

let cell =
  Cell.define
    { id= "task_ids_expander"
    ; state= Cell.unit_state
    ; operations=
        [ Expander
            { op= "expand"
            ; input= [("task_ids", List String)]
            ; output= [("task_id", String)]
            ; impl=
                (fun state msg ->
                  let task_ids = Json.get_string_list "task_ids" msg in
                  let messages =
                    List.map
                      (fun task_id ->
                        `Assoc [("task_id", `String task_id)] )
                      task_ids
                  in
                  (state, messages) ) } ] }
