# Kom

Biblioteka OCaml 5 do stanowych komórek i deklaratywnych obiegów JSON.
Kontrakt operacji i jej implementacja znajdują się obok siebie w definicji
komórki. Stan pozostaje prywatny i ma jawny codec tekstowy.
Kom nie używa Cyrografu ani generowania źródeł.
Wspólny typ wiadomości to `Kom.msg = Kom.Json.t`; po `open Kom` wystarczy `msg`.

Publiczne API: `Cell.define`, `Flow.define` / `Flow.of_json` oraz
`System.define/create/call/catalog/close`. Moduły wykonawcze są prywatne.
`Json` i `Schema` służą do wiadomości oraz kontraktów; `Storage` umożliwia
podłączenie magazynu. SQLite jest osobnym pakietem `kom-sqlite`.

## Budowanie

Potrzebne są Dune **3.24.2**, Git, Make, Python 3 do testu HTTP, narzędzia
kompilacji C, pkg-config i nagłówki SQLite (np. `libsqlite3-dev`).
Dune odtwarza OCaml **5.4.1** i zależności z `dune.lock`.

```sh
make build
make test
make check
```

Testy obejmują kontrakty, routing, grupy, wyłączność komórek, równoległość,
rollback SQLite, ponowienia i wznowienie po `SIGKILL`. Test HTTP uruchamia
prawdziwy serwer Todo, sprawdza RPC, formularze, escapowanie i restart.
Kontrola architektury Szańcem wymaga nowego profilu dla natywnych kontraktów;
`make check` nie raportuje jej jako wykonanej.

## Todo MPA

Cała aplikacja jest w [examples](examples/).
[system.ml](examples/system.ml) składa obiegi i podłącza komórki z plików
[index_cell.ml](examples/index_cell.ml), [task_cell.ml](examples/task_cell.ml),
[task_ids_expander_cell.ml](examples/task_ids_expander_cell.ml) oraz
[tasks_collector_cell.ml](examples/tasks_collector_cell.ml).
Każdy plik jest modułem komórki. Dune automatycznie uwzględnia moduły z folderu.
Indeks jawnie przydziela ID; obieg tworzy instancję `task.{$.task_id}`.

```sh
make todo
# http://127.0.0.1:8080
make todo TODO_PORT=8081 TODO_DB=/tmp/kom-todo.sqlite
```

Lista i szczegóły zadania są renderowane na serwerze. Formularze wysyłają
JSON-RPC 2.0 do `POST /rpc`, po sukcesie następuje pełna nawigacja.
Działają też zwykłe formularze bez JavaScriptu.

Metody RPC: `add_task` (`name`), `read_task` / `remove_task` (`task_id`),
`list_tasks` i `kom.catalog`. Przykład:

```sh
curl http://127.0.0.1:8080/rpc \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"add_task","params":{"name":"Kupić mleko"}}'
```

To serwer demonstracyjny na localhost, bez autoryzacji. SQLite zachowuje
zadania między uruchomieniami. Usunięcie usuwa zadanie z indeksu i czyści
stan jego instancji; adres nie jest ponownie wykorzystywany.

## Definicja komórki i obiegu

```ocaml
open Kom

let counter = Cell.define {
  id = "counter";
  state = {
    version = 1;
    init = (fun () -> 0);
    to_string = string_of_int;
    of_string = (fun text ->
      match int_of_string_opt text with
      | Some n -> Ok n | None -> Result.Error "Invalid counter");
  };
  operations = [
    Cell.Transformer {
      op = "increment";
      input = [];
      output = ["count", Schema.Int];
      impl = (fun state msg ->
        let next = state + 1 in
        next, Json.set "count" (Json.int next) msg);
    };
  ];
}

let definition = System.define
  ~cell_kinds:[counter]
  ~init_flow:"init"
  ~flows:[
    Flow.define {id = "init"; input = []; output = [];
      body = "!reproduce counter as counter"};
    Flow.define {id = "increment"; input = []; output = ["count", Schema.Int];
      body = "increment @counter"};
  ] ()

let () =
  let system = System.create definition in
  Fun.protect
    (fun () ->
      System.call system ~flow:"increment" (Json.object_ [])
      |> Json.to_string |> print_endline)
    ~finally:(fun () -> System.close system)
```

W Dune użyj `(libraries kom)`. Dla SQLite: `(libraries kom kom-sqlite)`
i `System.create ~storage:(Kom_sqlite.storage "state.sqlite") definition`.

Transformer przetwarza jedną wiadomość. Expander tworzy listę wiadomości.
Joiner dostaje całą płaską grupę raz, również pustą. Router wybiera jeden
zadeklarowany port. Kontrakt jest sprawdzany przed wykonaniem i przed
zatwierdzeniem wyniku.

`!parallel` daje gałęziom to samo wejście. `!parallel_each` przetwarza
elementy grupy. Oba czekają na wyniki i zachowują kolejność; zagnieżdżenia
pozostają grupami do jawnego `!flatten`. `!branch` wybiera ścieżkę Routera.

`System.catalog` eksportuje kontrakty i AST jako JSON bez stanu i closure.
`Flow.of_json` przyjmuje taki AST i podlega tej samej walidacji co DSL.
To punkt wejścia dla przyszłego edytora graficznego.

## Trwałość i współbieżność

Jedna operacja atomowo zatwierdza stan komórki i checkpoint. Obsługa tej
samej instancji jest wyłączna; niezależne komórki i obiegi działają
równolegle. Handler nie trzyma blokady całego Systemu ani transakcji SQLite.
Zapis magazynu jest serializowany i używa krótkiej transakcji.

Cały obieg nie jest transakcją: błąd późniejszego kroku pozostawia wcześniej
zatwierdzone zmiany. Po awarii nieukończony obieg wznawia się z checkpointów.
Opcjonalny `request_id` w `System.call` umożliwia ponowienie zakończonego
wywołania bez powtarzania operacji. ID JSON-RPC koreluje odpowiedź;
adapter Todo nie traktuje go automatycznie jako klucza idempotencji.

Zewnętrzne efekty handlera mogą powtórzyć się po awarii przed commit.
Codec musi odtwarzać niezależny stan, a zmiana implementacji wymaga
zwiększenia `revision`. Odtworzenie wymaga zgodnego katalogu; migracje
i transakcje wielokomórkowe pozostają otwarte.

Magazyn obecnie zapisuje cały snapshot i historię wykonań. Duża historia
zwiększa koszt zapisu; kompaktowanie i zapis przyrostowy wymagają dalszej
pracy. SQLite dopuszcza jednego aktywnego właściciela danego `System.id`.

Szczegóły: [API](docs/public-api.md), [architektura](contracts/README.md),
[scenariusze](docs/stp.md), [otwarte decyzje](docs/open-questions.md).
