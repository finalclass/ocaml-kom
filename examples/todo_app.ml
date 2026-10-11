open Yojson.Safe.Util
open Kom_runtime

let http (context : App.context) (request : Web.request) =
  let system = context.system and base = context.base_path in
  let render name page =
    let template =
      match Files.read context.files name with
      | Some source -> Mustache.of_string source
      | None -> failwith ("Missing template: " ^ name)
    in
    let page = `Assoc (("base", `String base) :: to_assoc page) in
    Web.response
      (Mustache.render
         ~strict:true
         template
         (Ezjsonm.from_string (Yojson.Safe.to_string page)) )
  in
  match (request.method_, Web.path request.target) with
  | "GET", "/" ->
      let query =
        match String.split_on_char '?' request.target with
        | [_; query] -> Web.query query
        | _ -> []
      in
      let finished = List.assoc_opt "finished" query = Some "1" in
      let params =
        List.filter_map
          (function
            | (("min_priority" | "max_priority" | "limit") as name), value
              when value <> "" ->
                Some (name, `Int (int_of_string value))
            | "cursor", value when value <> "" -> Some ("cursor", `String value)
            | _ -> None )
          query
      in
      let params =
        if List.mem_assoc "limit" params
        then params
        else ("limit", `Int 20) :: params
      in
      let result =
        Kom.System.call
          system
          ~flow:(if finished then "list_finished_tasks" else "list_tasks")
          (`Assoc params)
      in
      let next_url =
        match member "cursor" result with
        | `String cursor ->
            `String
              ( base
              ^ "/?"
              ^ String.concat
                  "&"
                  (List.map
                     (fun (name, value) ->
                       Web.encode name ^ "=" ^ Web.encode value )
                     (("cursor", cursor) :: List.remove_assoc "cursor" query) )
              )
        | _ -> `Null
      in
      Some
        (render
           "index.html"
           (`Assoc
              ( ("next_url", next_url)
              :: ("finished", `Bool finished)
              :: to_assoc result ) ) )
  | "GET", path when String.starts_with ~prefix:"/tasks/" path ->
      let task_id = Web.decode (String.sub path 7 (String.length path - 7)) in
      Some
        (render
           "task.html"
           (Kom.System.call
              system
              ~flow:"read_task"
              (`Assoc [("task_id", `String task_id)]) ) )
  | "POST", (("/add_task" | "/remove_task" | "/update_task") as path) ->
      let params =
        Web.query request.body
        |> List.map (fun (name, value) ->
            ( name
            , match name with
              | "priority" -> `Int (int_of_string value)
              | "done" -> `Bool (value = "true" || value = "on")
              | _ -> `String value ) )
      in
      let flow = String.sub path 1 (String.length path - 1) in
      let params =
        if flow = "update_task" && not (List.mem_assoc "done" params)
        then ("done", `Bool false) :: params
        else params
      in
      ignore (Kom.System.call system ~flow (`Assoc params)) ;
      Some (Web.redirect (base ^ "/"))
  | _ -> None

let app = App.define ~id:"todo" ~system:System.definition ~http ()
