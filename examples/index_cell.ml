open Kom
open Kom.Cell
open Kom.Schema

module State = struct
  type t =
    { next_id: int
    ; task_ids: string list }
  [@@deriving yojson]
end

let state =
  { version= 1
  ; init= (fun () -> State.{next_id= 1; task_ids= []})
  ; to_string= (fun state -> Json.to_string (State.to_yojson state))
  ; of_string=
      (fun text ->
        try State.of_yojson (Json.of_string text) with
        | Json.Error message -> Result.Error message) }

let cell =
  Cell.define
    { id= "index"
    ; state
    ; operations=
        [ Transformer
            { op= "allocate"
            ; input= [("name", String)]
            ; output= Task_cell.task_props
            ; impl=
                (fun state msg ->
                  let name = String.trim (Json.get_string "name" msg) in
                  if name = ""
                  then raise (Json.Error "Task name must not be blank") ;
                  let msg = Json.set "name" (`String name) msg in
                  let task_id = string_of_int state.next_id in
                  let state = {state with next_id= state.next_id + 1} in
                  (state, Json.set "task_id" (`String task_id) msg) ) }
        ; Transformer
            { op= "index"
            ; input= [("task_id", String)]
            ; output= []
            ; impl=
                (fun state msg ->
                  let task_id = Json.get_string "task_id" msg in
                  let task_ids =
                    if List.mem task_id state.task_ids
                    then state.task_ids
                    else state.task_ids @ [task_id]
                  in
                  ({state with task_ids}, msg) ) }
        ; Transformer
            { op= "remove"
            ; input= [("task_id", String)]
            ; output= []
            ; impl=
                (fun state msg ->
                  let task_id = Json.get_string "task_id" msg in
                  let task_ids =
                    List.filter (( <> ) task_id) state.task_ids
                  in
                  ({state with task_ids}, msg) ) }
        ; Transformer
            { op= "list"
            ; input= []
            ; output= [("task_ids", List String)]
            ; impl=
                (fun state msg ->
                  let ids =
                    `List (List.map (fun task_id -> `String task_id) state.task_ids)
                  in
                  (state, Json.set "task_ids" ids msg) ) } ] }
