open Yojson.Safe.Util
open Kom
open Kom.Cell
open Kom.Schema

let task_props =
  [("task_id", String); ("name", String); ("done", Bool); ("priority", Int)]

let project msg =
  `Assoc (List.map (fun (name, _) -> (name, member name msg)) task_props)

let merge row msg =
  `Assoc
    ( to_assoc row
    @ List.filter
        (fun (key, _) -> not (List.mem_assoc key (to_assoc row)))
        (to_assoc msg) )

let read db =
  match Db.get db ~id:"task" with
  | Some task -> task
  | None ->
      raise
        (Kom.Error {code= "NotFound"; message= "Task does not exist"; path= None}
        )

let cell =
  Cell.define
    { id= "task"
    ; state= unit_state
    ; operations=
        [ Transformer
            { op= "add"
            ; input= task_props
            ; output= task_props
            ; impl=
                (fun db () msg ->
                  Db.put db ~id:"task" (project msg) ;
                  ((), msg) ) }
        ; Transformer
            { op= "read"
            ; input= []
            ; output= task_props
            ; impl= (fun db () msg -> ((), merge (read db) msg)) }
        ; Transformer
            { op= "update"
            ; input= [("done", Bool); ("priority", Int)]
            ; output= task_props
            ; impl=
                (fun db () msg ->
                  let task = read db |> to_assoc in
                  let task =
                    `Assoc
                      ( ("done", member "done" msg)
                      :: ("priority", member "priority" msg)
                      :: List.remove_assoc
                           "priority"
                           (List.remove_assoc "done" task) )
                  in
                  Db.put db ~id:"task" task ;
                  ((), merge task msg) ) }
        ; Transformer
            { op= "remove"
            ; input= []
            ; output= []
            ; impl=
                (fun db () msg ->
                  ignore (read db) ;
                  Db.delete db ~id:"task" ;
                  ((), msg) ) } ] }
