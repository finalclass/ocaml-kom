open Yojson.Safe.Util
open Kom
open Kom.Cell
open Kom.Schema

let task_props = [("task_id", String); ("name", String)]

module State = struct
  type task =
    { task_id: string
    ; name: string }
  [@@deriving yojson]

  type t = task option [@@deriving yojson]
end

let state =
  { version= 1
  ; init= (fun () -> None)
  ; to_string= (fun state -> Yojson.Safe.to_string (State.to_yojson state))
  ; of_string=
      (fun text ->
        try State.of_yojson (Yojson.Safe.from_string text) with
        | Yojson.Json_error message -> Result.Error message) }

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
                      let task_id = (msg |> member "task_id" |> to_string) in
                      let name = (msg |> member "name" |> to_string) in
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
                      let fields =
                        to_assoc msg |> List.remove_assoc "task_id"
                        |> List.remove_assoc "name"
                      in
                      (state, `Assoc (("name", `String task.name) :: ("task_id", `String task.task_id) :: fields)) ) }
        ; Transformer
            { op= "remove"
            ; input= []
            ; output= []
            ; impl= (fun _state msg -> (None, msg)) } ] }
