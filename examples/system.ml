open Kom
open Kom.Cell
open Kom.Schema

type msg = Json.t

type index_data = {
  next_id : int;
  task_ids : string list;
}

type task_data = {
  task_id : string;
  name : string;
}

let decode_state decode text =
  try Ok (decode (Json.of_string text))
  with Json.Error message -> Error message

let index_state = {
  version = 1;
  init = (fun () -> { next_id = 1; task_ids = [] });
  to_string = (fun state ->
    Json.object_ [
      ("next_id", Json.int state.next_id);
      ("task_ids", Json.array (List.map Json.string state.task_ids));
    ]
    |> Json.to_string);
  of_string = decode_state (fun json ->
    {
      next_id = Json.get_int "next_id" json;
      task_ids = Json.get_string_list "task_ids" json;
    });
}

let task_state = {
  version = 1;
  init = (fun () -> (None : task_data option));
  to_string = (fun state ->
    (match state with
     | None -> Json.null
     | Some task ->
         Json.object_ [
           ("task_id", Json.string task.task_id);
           ("name", Json.string task.name);
         ])
    |> Json.to_string);
  of_string = decode_state (fun json ->
    if Json.is_null json then None
    else Some {
      task_id = Json.get_string "task_id" json;
      name = Json.get_string "name" json;
    });
}

let unit_state = {
  version = 1;
  init = (fun () -> ());
  to_string = (fun () -> Json.to_string Json.null);
  of_string = decode_state (fun json ->
    if Json.is_null json then ()
    else raise (Json.Error "Expected null for unit state"));
}

let task_props = [
  ("task_id", String);
  ("name", String);
]

let index = Cell.define {
  id = "index";
  state = index_state;
  operations = [
    Transformer {
      op = "allocate";
      input = [("name", String)];
      output = task_props;
      impl = (fun state msg ->
        let name = String.trim (Json.get_string "name" msg) in
        if name = "" then raise (Json.Error "Task name must not be blank");
        let msg = Json.set "name" (Json.string name) msg in
        let task_id = string_of_int state.next_id in
        let state = { state with next_id = state.next_id + 1 } in
        (state, Json.set "task_id" (Json.string task_id) msg));
    };
    Transformer {
      op = "index";
      input = [("task_id", String)];
      output = [];
      impl = (fun state msg ->
        let task_id = Json.get_string "task_id" msg in
        let task_ids =
          if List.mem task_id state.task_ids then state.task_ids
          else state.task_ids @ [task_id]
        in
        ({ state with task_ids }, msg));
    };
    Transformer {
      op = "remove";
      input = [("task_id", String)];
      output = [];
      impl = (fun state msg ->
        let task_id = Json.get_string "task_id" msg in
        let task_ids = List.filter ((<>) task_id) state.task_ids in
        ({ state with task_ids }, msg));
    };
    Transformer {
      op = "list";
      input = [];
      output = [("task_ids", List String)];
      impl = (fun state msg ->
        let ids = Json.array (List.map Json.string state.task_ids) in
        (state, Json.set "task_ids" ids msg));
    };
  ];
}

let task = Cell.define {
  id = "task";
  state = task_state;
  operations = [
    Transformer {
      op = "add";
      input = task_props;
      output = task_props;
      impl = (fun state msg ->
        match state with
        | Some _ -> raise (Kom.Error {code = "State"; message = "Task already initialized"; path = None})
        | None ->
            let task_id = Json.get_string "task_id" msg in
            let name = Json.get_string "name" msg in
            (Some { task_id; name }, msg));
    };
    Transformer {
      op = "read";
      input = [];
      output = task_props;
      impl = (fun state msg ->
        match state with
        | None -> raise (Kom.Error {code = "NotFound"; message = "Task does not exist"; path = None})
        | Some task ->
            let msg =
              msg
              |> Json.set "task_id" (Json.string task.task_id)
              |> Json.set "name" (Json.string task.name)
            in
            (state, msg));
    };
    Transformer {
      op = "remove";
      input = [];
      output = [];
      impl = (fun _state msg -> (None, msg));
    };
  ];
}

let task_ids_expander = Cell.define {
  id = "task_ids_expander";
  state = unit_state;
  operations = [
    Expander {
      op = "expand";
      input = [("task_ids", List String)];
      output = [("task_id", String)];
      impl = (fun state msg ->
        let task_ids = Json.get_string_list "task_ids" msg in
        let messages = List.map (fun task_id ->
          Json.object_ [("task_id", Json.string task_id)]
        ) task_ids in
        (state, messages));
    };
  ];
}

let tasks_collector = Cell.define {
  id = "tasks_collector";
  state = unit_state;
  operations = [
    Joiner {
      op = "collect";
      input = task_props;
      output = [("tasks", List (Object task_props))];
      impl = (fun state messages ->
        let tasks = List.map (fun msg ->
          Json.object_ [
            ("task_id", Json.string (Json.get_string "task_id" msg));
            ("name", Json.string (Json.get_string "name" msg));
          ]
        ) messages in
        (state, Json.object_ [("tasks", Json.array tasks)]));
    };
  ];
}

let init_cells = Flow.define {
  id = "init";
  input = [];
  output = [];
  body = {|
    !sequence(
      !reproduce index as index
      !reproduce task_ids_expander as task_ids_expander
      !reproduce tasks_collector as tasks_collector
    )
  |};
}

let add_task = Flow.define {
  id = "add_task";
  input = [("name", String)];
  output = task_props;
  body = {|
    !sequence(
      allocate @index
      !reproduce task as task.{$.task_id}
      add @task.{$.task_id}
      index @index
    )
  |};
}

let read_task = Flow.define {
  id = "read_task";
  input = [("task_id", String)];
  output = task_props;
  body = {|
    read @task.{$.task_id}
  |};
}

let list_tasks = Flow.define {
  id = "list_tasks";
  input = [];
  output = [("tasks", List (Object task_props))];
  body = {|
    !sequence(
      list @index
      expand @task_ids_expander
      !parallel_each(
        read @task.{$.task_id}
      )
      collect @tasks_collector
    )
  |};
}

let remove_task = Flow.define {
  id = "remove_task";
  input = [("task_id", String)];
  output = [("task_id", String)];
  body = {|
    !sequence(
      remove @index
      remove @task.{$.task_id}
    )
  |};
}

let definition = System.define
  ~cell_kinds:[index; task; task_ids_expander; tasks_collector]
  ~init_flow:"init"
  ~flows:[init_cells; add_task; read_task; list_tasks; remove_task] ()

let create ?(database = "todo.sqlite") () =
  System.create
    ~id:"todo"
    ~storage:(Kom_sqlite.storage database)
    definition
