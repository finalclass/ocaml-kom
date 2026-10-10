open Kom
open Kom.Cell
open Kom.Schema

let task_props = [("task_id", String); ("name", String)]

module State = struct
  type task =
    { task_id: string
    ; name: string }

  type t = task option

  let to_string (state : t) =
    ( match state with
      | None -> Json.null
      | Some task ->
          Json.object_
            [ ("task_id", Json.string task.task_id)
            ; ("name", Json.string task.name) ] )
    |> Json.to_string

  let of_string text : (t, string) result =
    try
      let json = Json.of_string text in
      Ok
        ( if Json.is_null json
          then None
          else
            Some
              { task_id= Json.get_string "task_id" json
              ; name= Json.get_string "name" json } )
    with
    | Json.Error message -> Result.Error message
end

let state =
  { version= 1
  ; init= (fun () -> None)
  ; to_string= State.to_string
  ; of_string= State.of_string }

let cell =
  Cell.define
    { id= "task"
    ; state
    ; operations=
        [ Transformer
            { op= "add"
            ; input= task_props
            ; output= task_props
            ; impl=
                (fun state msg ->
                  match state with
                  | Some _ ->
                      raise
                        (Kom.Error
                           { code= "State"
                           ; message= "Task already initialized"
                           ; path= None } )
                  | None ->
                      let task_id = Json.get_string "task_id" msg in
                      let name = Json.get_string "name" msg in
                      (Some State.{task_id; name}, msg) ) }
        ; Transformer
            { op= "read"
            ; input= []
            ; output= task_props
            ; impl=
                (fun state msg ->
                  match state with
                  | None ->
                      raise
                        (Kom.Error
                           { code= "NotFound"
                           ; message= "Task does not exist"
                           ; path= None } )
                  | Some task ->
                      let msg =
                        msg
                        |> Json.set "task_id" (Json.string task.task_id)
                        |> Json.set "name" (Json.string task.name)
                      in
                      (state, msg) ) }
        ; Transformer
            { op= "remove"
            ; input= []
            ; output= []
            ; impl= (fun _state msg -> (None, msg)) } ] }
