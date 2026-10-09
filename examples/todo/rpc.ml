module T = Model.T

exception Rpc_error of int * string * Yojson.Safe.t option
let reject code message = raise (Rpc_error (code, message, None))
let error id code message data =
  let fields = ["code", `Int code; "message", `String message] in
  `Assoc ["jsonrpc", `String "2.0"; "id", id;
    "error", `Assoc (fields @ (match data with None -> [] | Some data -> ["data", data]))]
let member name fields = Option.value ~default:`Null (List.assoc_opt name fields)

let parameters fields expected =
  match List.assoc_opt "params" fields with
  | None when expected = [] -> []
  | Some (`Assoc params) when List.sort compare (List.map fst params) = List.sort compare expected -> params
  | _ -> reject (-32602) "Niepoprawne parametry metody."

let invoke system method_ fields =
  let message = match method_ with
    | "todo.list" ->
        let _ = parameters fields [] in
        Kom.Message.encode Model.list_request (T.ListRequest.make ())
    | "todo.add" ->
        let params = parameters fields ["title"] in
        let title = match member "title" params with
          | `String title -> title
          | _ -> reject (-32602) "Parametr title musi być tekstem." in
        Kom.Message.encode Model.add_request (T.AddRequest.make ~title ())
    | "todo.remove" ->
        let params = parameters fields ["id"] in
        let id = match member "id" params with
          | `Int id -> id
          | _ -> reject (-32602) "Parametr id musi być liczbą całkowitą." in
        Kom.Message.encode Model.remove_request (T.RemoveRequest.make ~id ())
    | _ -> reject (-32601) "Nieznana metoda." in
  match Model.call system method_ message with
  | Error problem ->
      raise (Rpc_error (-32000, problem.message, Some (`Assoc ["code", `String problem.code])))
  | Ok tasks ->
      `Assoc ["tasks", `List (List.map (fun (task : T.Task.t) ->
        `Assoc ["id", `Int task.id; "title", `String task.title]) tasks.T.TaskList.tasks)]

let request system = function
  | `Assoc fields ->
      let id = member "id" fields in
      let valid_id = match id with
        | `Null | `String _ | `Int _ | `Intlit _ -> true
        | `Float value -> Float.is_finite value
        | _ -> false in
      begin match member "jsonrpc" fields, member "method" fields with
      | `String "2.0", `String method_ when valid_id ->
          let response = try
            `Assoc ["jsonrpc", `String "2.0"; "id", id; "result", invoke system method_ fields]
          with
          | Rpc_error (code, message, data) -> error id code message data
          | exn ->
              Printf.eprintf "RPC failure: %s\n%!" (Printexc.to_string exn);
              error id (-32603) "Wewnętrzny błąd serwera." None in
          if List.mem_assoc "id" fields then Some response else None
      | _ -> Some (error `Null (-32600) "Niepoprawne żądanie JSON-RPC 2.0." None)
      end
  | _ -> Some (error `Null (-32600) "Niepoprawne żądanie JSON-RPC 2.0." None)

let dispatch system = function
  | `List [] -> Some (error `Null (-32600) "Batch nie może być pusty." None)
  | `List requests ->
      begin match List.filter_map (request system) requests with
      | [] -> None
      | responses -> Some (`List responses)
      end
  | value -> request system value

let handle system text =
  try dispatch system (Yojson.Safe.from_string text)
  with Yojson.Json_error _ -> Some (error `Null (-32700) "Niepoprawny JSON." None)
