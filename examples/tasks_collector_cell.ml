open Kom
open Kom.Cell
open Kom.Schema

let cell =
  Cell.define
    { id= "tasks_collector"
    ; state= Cell.unit_state
    ; operations=
        [ Joiner
            { op= "collect"
            ; input= Task_cell.task_props
            ; output= [("tasks", List (Object Task_cell.task_props))]
            ; impl=
                (fun state messages ->
                  let tasks =
                    List.map
                      (fun msg ->
                        Json.object_
                          [ ( "task_id"
                            , Json.string (Json.get_string "task_id" msg) )
                          ; ("name", Json.string (Json.get_string "name" msg))
                          ] )
                      messages
                  in
                  (state, Json.object_ [("tasks", Json.array tasks)]) ) } ] }
