(*
Szkic przyszłego API, nie implementacja obecnego Kom.
Składnia rekordów, Json.*, shape, input/output i DSL są koncepcyjne.

Wiadomość jest obiektem JSON. Nazwa operacji pochodzi z katalogu;
aplikacja nie deklaruje type op.

input opisuje wymagane pola wiadomości wejściowej.
output opisuje gwarantowane pola wiadomości wyjściowej.
Transformer zachowuje pozostałe pola; Json.set zastępuje istniejący klucz.
Expander tworzy nowe wiadomości, a jego output opisuje każdy element.
Joiner otrzymuje gotową grupę, a jego input opisuje każdy element tej grupy.
Runtime sprawdza kontrakt przed obsługą i przed zatwierdzeniem stanu/wyniku.

Definicja komórki zachowuje prywatny typ stanu. Adapter wiąże init i impl
z codec stanu; zapis/odtwarzanie stanu wymaga osobnego dopięcia w API.
Katalog eksportowany do edytora zawiera kontrakty, bez funkcji impl.
Edytor i parser tekstowy budują ten sam serializowalny AST obiegu.

type msg = Json.t
type path = string

type index_state = {
  next_id : int;
  task_ids : string list;
}

type task_data = {
  task_id : string;
  name : string;
}

exception Task_not_found
exception Task_already_initialized

let task_props = [
  ("task_id", String);
  ("name", String);
]

let index = {
  id = "index";
  init = (fun () -> { next_id = 1; task_ids = [] });
  operations = [
    {
      op = "allocate";
      shape = Transformer;
      input = [];
      output = [("task_id", String)];
      impl = (fun state msg ->
        let task_id = string_of_int state.next_id in
        let state = { state with next_id = state.next_id + 1 } in
        (state, Json.set "task_id" (Json.string task_id) msg));
    };
    {
      op = "index";
      shape = Transformer;
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
    {
      op = "remove";
      shape = Transformer;
      input = [("task_id", String)];
      output = [];
      impl = (fun state msg ->
        let task_id = Json.get_string "task_id" msg in
        let task_ids = List.filter ((<>) task_id) state.task_ids in
        ({ state with task_ids }, msg));
    };
    {
      op = "list";
      shape = Transformer;
      input = [];
      output = [("task_ids", List String)];
      impl = (fun state msg ->
        let ids = Json.array (List.map Json.string state.task_ids) in
        (state, Json.set "task_ids" ids msg));
    };
  ];
}

let task = {
  id = "task";
  init = (fun () -> (None : task_data option));
  operations = [
    {
      op = "add";
      shape = Transformer;
      input = task_props;
      output = task_props;
      impl = (fun state msg ->
        match state with
        | Some _ -> raise Task_already_initialized
        | None ->
            let task_id = Json.get_string "task_id" msg in
            let name = Json.get_string "name" msg in
            (Some { task_id; name }, msg));
    };
    {
      op = "read";
      shape = Transformer;
      input = [];
      output = task_props;
      impl = (fun state msg ->
        match state with
        | None -> raise Task_not_found
        | Some task ->
            let msg =
              msg
              |> Json.set "task_id" (Json.string task.task_id)
              |> Json.set "name" (Json.string task.name)
            in
            (state, msg));
    };
    {
      op = "remove";
      shape = Transformer;
      input = [];
      output = [];
      impl = (fun _state msg -> (None, msg));
    };
  ];
}

let task_ids_expander = {
  id = "task_ids_expander";
  init = (fun () -> ());
  operations = [
    {
      op = "expand";
      shape = Expander;
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

let tasks_collector = {
  id = "tasks_collector";
  init = (fun () -> ());
  operations = [
    {
      op = "collect";
      shape = Joiner;
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

let init_cells = {|
  !sequence(
    !reproduce index as index
    !reproduce task_ids_expander as task_ids_expander
    !reproduce tasks_collector as tasks_collector
  )
|}

let add_task = {|
  !sequence(
    allocate @index
    !reproduce task as task.{$.task_id}
    add @task.{$.task_id}
    index @index
  )
|}

let read_task = {|
  read @task.{$.task_id}
|}

let list_tasks = {|
  !sequence(
    list @index
    expand @task_ids_expander
    !parallel_each(
      read @task.{$.task_id}
    )
    collect @tasks_collector
  )
|}

let remove_task = {|
  !sequence(
    remove @index
    remove @task.{$.task_id}
  )
|}

let system = Kom.System.define
  ~cell_kinds:[index; task; task_ids_expander; tasks_collector]
  ~init_flow:"init"
  ~flows:[
    ("init", init_cells);
    ("add_task", add_task);
    ("read_task", read_task);
    ("list_tasks", list_tasks);
    ("remove_task", remove_task);
  ]

let create () =
  Kom.System.create system

Adapter RPC udostępnia nazwane obiegi z kontraktami żądania/odpowiedzi:

  todo.add    -> add_task    { name: String }
                            -> { task_id: String, name: String }
  todo.read   -> read_task   { task_id: String }
                            -> { task_id: String, name: String }
  todo.list   -> list_tasks  {}
                            -> { tasks: List<{ task_id: String, name: String }> }
  todo.remove -> remove_task { task_id: String }
                            -> { task_id: String }

Adapter waliduje params i wywołuje:
  Kom.System.call instance ~flow:"add_task" params
Wyjątki i nieistniejące adresy stają się błędami RPC.
init_flow wskazuje wewnętrzny obieg wykonywany raz dla świeżego Systemu.
Odtworzenie Systemu przywraca licznik i komórki bez ponownego init.

Znaczenie DSL:
- sequence przekazuje wynik poprzedniego kroku do następnego.
- reproduce tworzy świeżą instancję wskazanego rodzaju pod jawnym adresem,
  wykonuje jej init i przepuszcza wiadomość bez zmian. Kolizja adresu to błąd.
- task.{$.task_id} buduje adres z bieżącej wiadomości i wymaga pola task_id,
  niezależnie od input samej operacji read.
- System.define zbiera z reproduce jawne powiązania rodzaju i wzorca adresu.
  Tutaj deklaracja reproduce task as task.{$.task_id} wiąże ten wzorzec
  z rodzajem task. Edytor używa tego powiązania do wyboru operacji;
  runtime sprawdza rodzaj docelowej instancji. Niejednoznaczne powiązania
  rodzajów są błędem walidacji Systemu.
- parallel_each dostaje grupę, uruchamia fragment raz na element i czeka
  na wszystkie wyniki. Zwraca je w kolejności elementów wejściowych.
- collect wykonuje się raz z pełną grupą, także dla []: zwraca { tasks: [] }.
- output = [] oznacza brak nowych gwarantowanych pól, nie brak wiadomości.

Usuwanie zeruje stan task i usuwa ID z indeksu. Instancja pozostaje;
jej read zwraca Task_not_found. Fizyczne zwalnianie instancji jest osobnym
mechanizmem i nie jest ukrytym efektem operacji remove.

Przydział ID odbywa się jawnie w index.allocate, przy serializowanym dostępie
do stanu indeksu. Po nieudanym dodaniu mogą pozostać luki w numeracji.
Sequence nie oznacza transakcji całego obiegu ani spójnego snapshotu listy.
Brak komórki/błąd odczytu w parallel_each kończy listowanie błędem;
szkic nie pomija takich zadań ani nie zwraca częściowej listy.
*)
