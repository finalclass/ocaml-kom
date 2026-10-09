let serve system =
  try while true do
    let line = read_line () in
    let response = Todo_app.Rpc.handle system line in
    let json = Option.value ~default:`Null response in
    print_endline (Yojson.Safe.to_string json)
  done with End_of_file -> ()

let () =
  match Kom.System.with_ ~id:"todo-example" ~workers:2 Todo_app.Model.definition serve with
  | Ok () -> ()
  | Error problems ->
      List.iter (fun (problem : Kom.Types.Problem.t) ->
        Printf.eprintf "%s: %s\n" problem.code problem.message) problems.items;
      exit 1
