open Yojson.Safe.Util
open Kom
open Kom.Cell
open Kom.Schema

module State = struct
  type t = {next_id: int} [@@deriving yojson]
end

let state =
  { version= 2
  ; init= (fun () -> State.{next_id= 1})
  ; to_string= (fun state -> Yojson.Safe.to_string (State.to_yojson state))
  ; of_string=
      (fun text ->
        try State.of_yojson (Yojson.Safe.from_string text) with
        | Yojson.Json_error error -> Error error ) }

(* Increment version whenever the mapping or key definition changes. *)
let all_tasks =
  Db.view
    { id= "all_tasks"
    ; version= 1
    ; key= Db.int
    ; map=
        (fun row ->
          Some (int_of_string (row |> member "task_id" |> to_string), row) ) }

let finished_tasks =
  Db.view
    { id= "finished_tasks"
    ; version= 1
    ; key= Db.int
    ; map=
        (fun row ->
          if row |> member "done" |> to_bool
          then Some (row |> member "priority" |> to_int, row)
          else None ) }

let optional decode key msg =
  match member key msg with
  | `Null -> None
  | value -> Some (decode value)

let page_props =
  [("tasks", List (Object Task_cell.task_props)); ("cursor", Optional String)]

let paging = [("limit", Optional Int); ("cursor", Optional String)]

let list db state msg view from_key to_key =
  let page =
    Db.query
      ?from_key
      ?to_key
      ?after:(optional to_string "cursor" msg)
      ?limit:(optional to_int "limit" msg)
      db
      view
      (fun (_, task) -> Some task )
  in
  let fields =
    to_assoc msg |> List.remove_assoc "tasks" |> List.remove_assoc "cursor"
  in
  let fields = ("tasks", `List page.items) :: fields in
  ( state
  , `Assoc
      ( match page.cursor with
      | None -> fields
      | Some cursor -> ("cursor", `String cursor) :: fields ) )

let cell =
  Cell.define
    ~views:[Db.View all_tasks; Db.View finished_tasks]
    { id= "index"
    ; state
    ; operations=
        [ Transformer
            { op= "allocate"
            ; input=
                [ ("name", String)
                ; ("done", Optional Bool)
                ; ("priority", Optional Int) ]
            ; output= Task_cell.task_props
            ; impl=
                (fun _db state msg ->
                  let name = String.trim (msg |> member "name" |> to_string) in
                  if name = ""
                  then
                    raise
                      (Kom.Error
                         { code= "Contract"
                         ; message= "Task name must not be blank"
                         ; path= None } ) ;
                  let task =
                    `Assoc
                      [ ("task_id", `String (string_of_int state.State.next_id))
                      ; ("name", `String name)
                      ; ( "done"
                        , `Bool
                            (Option.value
                               ~default:false
                               (optional to_bool "done" msg) ) )
                      ; ( "priority"
                        , `Int
                            (Option.value
                               ~default:0
                               (optional to_int "priority" msg) ) ) ]
                  in
                  (State.{next_id= state.next_id + 1}, Task_cell.merge task msg) )
            }
        ; Transformer
            { op= "index"
            ; input= Task_cell.task_props
            ; output= []
            ; impl=
                (fun db state msg ->
                  Db.put
                    db
                    ~id:(msg |> member "task_id" |> to_string)
                    (Task_cell.project msg) ;
                  (state, msg) ) }
        ; Transformer
            { op= "remove"
            ; input= [("task_id", String)]
            ; output= []
            ; impl=
                (fun db state msg ->
                  Db.delete db ~id:(msg |> member "task_id" |> to_string) ;
                  (state, msg) ) }
        ; Transformer
            { op= "list"
            ; input= paging
            ; output= page_props
            ; impl= (fun db state msg -> list db state msg all_tasks None None)
            }
        ; Transformer
            { op= "finished"
            ; input=
                paging
                @ [ ("min_priority", Optional Int)
                  ; ("max_priority", Optional Int) ]
            ; output= page_props
            ; impl=
                (fun db state msg ->
                  list
                    db
                    state
                    msg
                    finished_tasks
                    (optional to_int "min_priority" msg)
                    (optional to_int "max_priority" msg) ) } ] }
