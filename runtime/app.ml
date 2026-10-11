type context =
  { system: Kom.System.t
  ; files: File_access.t
  ; base_path: string }

type t =
  { id: string
  ; definition: Kom.System.definition
  ; http: context -> Web.request -> Web.response option
  ; cleanup: unit -> unit }

let define ~id ~system ?(http = fun _ _ -> None) ?(cleanup = fun () -> ()) () =
  if
    id = ""
    || id = "."
    || id = ".."
    || not
         (String.for_all
            (function
              | 'a' .. 'z'
               |'A' .. 'Z'
               |'0' .. '9'
               |'_'
               |'-'
               |'.' ->
                  true
              | _ -> false )
            id )
  then
    raise
      (Kom.Error {code= "App"; message= "Invalid application ID"; path= None}) ;
  {id; definition= system; http; cleanup}
