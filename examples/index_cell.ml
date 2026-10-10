open Kom
open Kom.Cell
open Kom.Schema

module State = struct
  type t =
    { next_id: int
    ; task_ids: string list }
  (* tutaj jakiś ppx by się przydał *)

  let to_string state =
    Json.object_
      [ ("next_id", Json.int state.next_id)
      ; ("task_ids", Json.array (List.map Json.string state.task_ids)) ]
    |> Json.to_string

  let of_string text =
    try
      let json = Json.of_string text in
      Ok
        { next_id= Json.get_int "next_id" json
        ; task_ids= Json.get_string_list "task_ids" json }
    with
    | Json.Error message -> Result.Error message
end

let state =
  { version= 1
  ; init= (fun () -> State.{next_id= 1; task_ids= []})
  ; to_string= State.to_string
  ; of_string= State.of_string }

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
                  let msg = Json.set "name" (Json.string name) msg in
                  let task_id = string_of_int state.next_id in
                  let state = {state with next_id= state.next_id + 1} in
                  (state, Json.set "task_id" (Json.string task_id) msg) ) }
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
                    Json.array (List.map Json.string state.task_ids)
                  in
                  (state, Json.set "task_ids" ids msg) ) } ] }
