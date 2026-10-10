open Yojson.Safe.Util
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
                        `Assoc
                          [ ( "task_id"
                            , `String (msg |> member "task_id" |> to_string) )
                          ; ("name", `String (msg |> member "name" |> to_string))
                          ] )
                      messages
                  in
                  (state, `Assoc [("tasks", `List tasks)]) ) } ] }
