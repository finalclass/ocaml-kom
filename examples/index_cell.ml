open Yojson.Safe.Util
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
  ; to_string= (fun state -> Yojson.Safe.to_string (State.to_yojson state))
  ; of_string=
      (fun text ->
        try State.of_yojson (Yojson.Safe.from_string text) with
        | Yojson.Json_error message -> Result.Error message) }

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
                  let name = String.trim (msg |> member "name" |> to_string) in
                  if name = ""
                  then
                    raise
                      (Kom.Error
                         { code= "Contract"
                         ; message= "Task name must not be blank"
                         ; path= None }) ;
                  let task_id = string_of_int state.next_id in
                  let state = {state with next_id= state.next_id + 1} in
                  let fields =
                    to_assoc msg |> List.remove_assoc "name"
                    |> List.remove_assoc "task_id"
                  in
                  (state, `Assoc (("task_id", `String task_id) :: ("name", `String name) :: fields)) ) }
        ; Transformer
            { op= "index"
            ; input= [("task_id", String)]
            ; output= []
            ; impl=
                (fun state msg ->
                  let task_id = (msg |> member "task_id" |> to_string) in
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
                  let task_id = (msg |> member "task_id" |> to_string) in
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
                  (state, `Assoc (("task_ids", ids) :: List.remove_assoc "task_ids" (to_assoc msg))) ) } ] }
