open Yojson.Safe.Util

type entry =
  { id: string
  ; current: string option
  ; pending: string option }

let json entries =
  `List
    (List.map
       (fun entry ->
         `Assoc
           [ ("id", `String entry.id)
           ; ( "current"
             , Option.fold
                 ~none:`Null
                 ~some:(fun path -> `String path)
                 entry.current )
           ; ( "pending"
             , Option.fold
                 ~none:`Null
                 ~some:(fun path -> `String path)
                 entry.pending ) ] )
       entries )

let option = function
  | `Null -> None
  | value -> Some (to_string value)

let load files =
  match File_access.read files "plugins.json" with
  | None -> []
  | Some text ->
      Yojson.Safe.from_string text
      |> to_list
      |> List.map (fun row ->
          { id= row |> member "id" |> to_string
          ; current= option (member "current" row)
          ; pending= option (member "pending" row) } )

let save files entries =
  File_access.write files "plugins.json" (Yojson.Safe.to_string (json entries))
