module T = Demo_contracts.Todo

let schema = Kom.Message.schema ["Todo.cyrograf", Todo_schema.source]
let list_request = Kom.Message.codec ~schema ~name:"Todo.ListRequest" (module T.ListRequest)
let add_request = Kom.Message.codec ~schema ~name:"Todo.AddRequest" (module T.AddRequest)
let remove_request = Kom.Message.codec ~schema ~name:"Todo.RemoveRequest" (module T.RemoveRequest)
let task_list = Kom.Message.codec ~schema ~name:"Todo.TaskList" (module T.TaskList)
let problem code message = Kom.Types.Problem.make ~code ~message ()
let operation name input output =
  Kom.Operation.make ~name ~input ~outputs:[Kom.Message.type_ output]
let reply codec value = Kom.Message.batch [Kom.Message.encode codec value]

module InputPolicy = struct
  type state = unit
  let id = "todo.input-policy"
  let revision = "1"
  let state_version = 1
  let operations = [
    operation "PrepareAdd" add_request add_request;
    operation "PrepareRemove" remove_request remove_request
  ]
  let init _ _ = Ok ()
  let handle _ () ~operation message =
    match operation with
    | "PrepareAdd" ->
        let request = Kom.Message.decode add_request message in
        let title = String.trim request.T.AddRequest.title in
        if title = "" then Error (problem "InvalidTitle" "Wpisz treść zadania.")
        else if String.length title > 500 then
          Error (problem "InvalidTitle" "Treść zadania może mieć najwyżej 500 bajtów UTF-8.")
        else Ok ((), reply add_request (T.AddRequest.make ~title ()))
    | "PrepareRemove" ->
        let request = Kom.Message.decode remove_request message in
        if request.T.RemoveRequest.id <= 0 then
          Error (problem "InvalidId" "Identyfikator zadania musi być dodatni.")
        else Ok ((), reply remove_request request)
    | _ -> Error (problem "Operation" "Nieznana operacja InputPolicy.")
  let snapshot () = Ok "unit"
  let restore _ _ snapshot =
    if snapshot.Kom.Types.StateSnapshot.state_version = state_version && snapshot.data = "unit"
    then Kom.Cell.Restored ()
    else Kom.Cell.Unsupported (problem "State" "Nieobsługiwany stan InputPolicy.")
  let release () = ()
end

module TaskAccess = struct
  type state = T.StoreState.t
  let id = "todo.task-access"
  let revision = "1"
  let state_version = 1
  let operations = [
    operation "List" list_request task_list;
    operation "Register" add_request task_list;
    operation "Dismiss" remove_request task_list
  ]
  let init _ _ = Ok (T.StoreState.make ~next_id:1 ~tasks:[] ())
  let result state = Ok (state, reply task_list (T.TaskList.make ~tasks:state.T.StoreState.tasks ()))
  let handle _ state ~operation message =
    match operation with
    | "List" ->
        let () = Kom.Message.decode list_request message in
        result state
    | "Register" ->
        let request = Kom.Message.decode add_request message in
        let task = T.Task.make ~id:state.T.StoreState.next_id ~title:request.T.AddRequest.title () in
        result (T.StoreState.make ~next_id:(state.next_id + 1) ~tasks:(state.tasks @ [task]) ())
    | "Dismiss" ->
        let request = Kom.Message.decode remove_request message in
        if not (List.exists (fun (task : T.Task.t) -> task.id = request.T.RemoveRequest.id) state.tasks)
        then Error (problem "NotFound" "To zadanie już nie istnieje.")
        else result {state with tasks = List.filter (fun (task : T.Task.t) -> task.id <> request.id) state.tasks}
    | _ -> Error (problem "Operation" "Nieznana operacja TaskAccess.")
  let snapshot state =
    match T.StoreState.to_drut state with
    | Ok data -> Ok data
    | Error _ -> Error (problem "State" "Nie można zapisać stanu TaskAccess.")
  let restore _ _ snapshot =
    if snapshot.Kom.Types.StateSnapshot.state_version <> state_version then
      Kom.Cell.Unsupported (problem "State" "Nieobsługiwana wersja stanu TaskAccess.")
    else match T.StoreState.from_drut snapshot.data with
      | Ok state -> Kom.Cell.Restored state
      | Error _ -> Kom.Cell.Failed (problem "State" "Niepoprawny snapshot TaskAccess.")
  let release _ = ()
end

let mutation ~id ~prepare ~apply =
  Kom.Flow.define ~id (Kom.Flow.sequence [
    Kom.Flow.step ~id:"prepare" ~cell:"input-policy" ~operation:prepare ();
    Kom.Flow.step ~id:"apply" ~cell:"task-access" ~operation:apply
      ~input:(Kom.Flow.bind (Kom.Flow.output "prepare")) ()
  ])

let list = Kom.Flow.define ~id:"todo.list"
  (Kom.Flow.step ~id:"list" ~cell:"task-access" ~operation:"List" ())
let add = mutation ~id:"todo.add" ~prepare:"PrepareAdd" ~apply:"Register"
let remove = mutation ~id:"todo.remove" ~prepare:"PrepareRemove" ~apply:"Dismiss"

let definition = Kom.System.define
  ~cells:[
    Kom.Cell.spec ~id:"input-policy" (Kom.Cell.define (module InputPolicy));
    Kom.Cell.spec ~id:"task-access" (Kom.Cell.define (module TaskAccess))
  ] ~flows:[list; add; remove] ()

let call system method_ message =
  match Kom.System.call system ~flow:(Kom.Flow.named method_) message with
  | Error problems -> Error (List.hd problems.Kom.Types.Problems.items)
  | Ok (Kom.Types.Completion.Failed problem) -> Error problem
  | Ok (Kom.Types.Completion.Completed batch) ->
      match batch.items with
      | [message] -> Ok (Kom.Message.decode task_list message)
      | _ -> Error (problem "Result" "Obieg nie zwrócił jednej listy zadań.")
