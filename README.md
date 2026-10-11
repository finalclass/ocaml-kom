# Kom

Biblioteka OCaml 5 do stanowych komórek i deklaratywnych obiegów JSON.
Kontrakt operacji i jej implementacja znajdują się obok siebie w definicji
komórki. Stan pozostaje prywatny i ma jawny codec tekstowy.
Kom nie używa Cyrografu ani generowania źródeł.
Wspólny typ wiadomości to `Kom.msg = Yojson.Safe.t`; po `open Kom` wystarczy `msg`.

Publiczne API: `Cell.define`, `Flow.define` / `Flow.of_json` oraz
`System.define/create/call/replace/catalog/close` oraz prywatny dla komórki `Db`. Moduły wykonawcze są prywatne.
Wiadomości używają Yojson, a `Schema.t` opisuje ich kontrakty. `Storage` umożliwia
podłączenie magazynu. SQLite jest osobnym pakietem `kom-sqlite`. Host HTTP, pluginy i pliki
są w pakiecie `kom-runtime`.

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
[index_cell.ml](examples/index_cell.ml) oraz [task_cell.ml](examples/task_cell.ml).
Każdy plik jest modułem komórki. Dune automatycznie uwzględnia moduły z folderu.
Konwersje stanu generuje `ppx_deriving_yojson` przez `[@@deriving yojson]`.
Indeks jawnie przydziela ID; obieg tworzy instancję `task.{$.task_id}`.

```sh
make todo
# http://127.0.0.1:8080
make todo TODO_PORT=8081 TODO_DIR=/tmp/kom-todo
```

Lista i szczegóły zadania są renderowane na serwerze przez Mustache.
HTTP używa Eio.Net; szablony i skrypt pochodzą z lokalnego storage aplikacji.
Host ładuje [todo_plugin.ml](examples/todo_plugin.ml) jako `examples/todo.cmxs`
i nie jest statycznie linkowany z kodem Todo.
Formularze wysyłają JSON-RPC 2.0 do `POST /rpc`, po sukcesie następuje pełna nawigacja.
Działają też zwykłe formularze bez JavaScriptu.

Metody RPC: `add_task` (`name`, opcjonalnie `done`, `priority`),
`read_task` / `remove_task` (`task_id`), `update_task` (`task_id`, `done`, `priority`),
`list_tasks`, `list_finished_tasks` i `kom.catalog`.
Listy przyjmują opcjonalne `limit` i `cursor`; ukończone zadania dodatkowo
`min_priority` / `max_priority`. Przykład:

```sh
curl http://127.0.0.1:8080/rpc \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"add_task","params":{"name":"Kupić mleko"}}'
```

To serwer demonstracyjny na localhost, bez autoryzacji. SQLite zachowuje
zadania między uruchomieniami. Usunięcie usuwa zadanie z indeksu i czyści
prywatny dokument jego instancji; adres nie jest ponownie wykorzystywany.

## Runtime i pluginy

Host słucha na loopback. Polecenia administracyjne korzystają z lokalnego
socketu Unix. Rejestr pluginów, prywatna baza i pliki są w wybranym katalogu.

```sh
dune exec kom -- start --directory ./kom-data --port 8080
dune exec kom -- add plugin _build/default/examples/todo.cmxs
# Dla innego katalogu dodaj --directory DIR do każdego polecenia.
dune exec kom -- put todo index.html examples/index.html
dune exec kom -- put todo task.html examples/task.html
dune exec kom -- put todo app.js examples/app.js
dune exec kom -- call todo add_task '{"name":"Pierwsze zadanie"}'
dune exec kom -- apps
dune exec kom -- files todo
# Ponowne add przełącza działającą aplikację na nowy artefakt:
dune exec kom -- add plugin _build/default/examples/todo.cmxs
dune exec kom -- restart
dune exec kom -- stop
```

Aplikacja działa pod `/apps/todo/`, a gdy jest jedyna — również pod `/`.
Podczas przeładowania nowe wywołania czekają w RAM; aktywne kończą się na
starej wersji. Stan i dokumenty pozostają w miejscu, a nowa wersja widoków
jest przebudowywana przed wznowieniem. Niezgodny codec albo błąd zapisu
pozostawia aktywną poprzednią wersję. Sposób przełączenia i kontrakty opisuje
[docs/runtime.md](docs/runtime.md).

Plugin wywołuje `Kom_runtime.Plugin.register (App.define ...)` dokładnie raz.
Musi być skompilowany tym samym kompilatorem i z tymi samymi interfejsami co
host. Host linkuje biblioteki dostępne pluginom z `-linkall`; plugin zawiera
własne moduły aplikacji, bez kopii Kom i runtime. Reguła Dune w examples
buduje kompletny artefakt Todo. Natywny kod jest zaufany i nie może zostać
odładowany: `App.cleanup` zwalnia jego zasoby, a `restart` uruchamia nowy proces
bez starych generacji. Segfault pluginu może zakończyć cały host.

Tryb osadzony, bez HTTP i Dynlink:

```sh
dune exec examples/console.exe
```

[console.ml](examples/console.ml) tworzy runtime w pamięci, instaluje tę samą
aplikację, wykonuje obiegi i zamyka runtime. Pliki są izolowane per aplikacja;
administracyjne write/delete nie należą do transakcji obiegów.

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
      impl = (fun _db state msg ->
        let next = state + 1 in
        next, `Assoc (("count", `Int next) ::
          List.remove_assoc "count" (Yojson.Safe.Util.to_assoc msg)));
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

let () = Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let system = System.create ~sw ~domain_mgr definition in
  Fun.protect
    (fun () ->
      System.call system ~flow:"increment" (`Assoc [])
      |> Yojson.Safe.to_string |> print_endline)
    ~finally:(fun () -> System.close system)
```

W Dune użyj `(libraries kom yojson eio_main)`. Dla SQLite: `(libraries kom kom-sqlite yojson eio_main)`
i `System.create ~sw ~domain_mgr ~storage:(Kom_sqlite.storage "state.sqlite") definition`.

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

`!transaction(fragment)` zatwierdza stany, dokumenty, indeksy, utworzone
komórki i checkpointy fragmentu razem. Komórki widzą własne zapisy.
Konkurencyjna zmiana odczytanej komórki daje `Conflict`; framework nie
powtarza automatycznie handlerów. Poza transakcją wcześniejsze kroki
pozostają zatwierdzone. Po awarii fragment transakcyjny zaczyna od początku,
a pozostały obieg wznawia się z checkpointów.
Opcjonalny `request_id` umożliwia ponowienie zakończonego wywołania bez
powtarzania operacji. ID JSON-RPC koreluje odpowiedź; adapter Todo nie
traktuje go automatycznie jako klucza idempotencji.

Handler otrzymuje `Db.t` ograniczone do swojej instancji i ważne wyłącznie
podczas operacji. `Db.get/put/delete` obsługują dokumenty JSON. `Db.view`
łączy filtr i mapowanie do indeksowanego klucza oraz wartości:

```ocaml
let finished_tasks = Db.view {
  id = "finished_tasks";
  version = 1; (* podbij ręcznie po zmianie map lub typu klucza *)
  key = Db.int;
  map = (fun row ->
    let open Yojson.Safe.Util in
    if row |> member "done" |> to_bool then
      Some (row |> member "priority" |> to_int, row)
    else None);
}
(* Cell.define ~views:[Db.View finished_tasks] {...} *)
(* w handlerze: *)
(* Db.query ~from_key:3 ~limit:20 db finished_tasks
     (fun (_, row) -> Some row) *)
```

Widok aktualizuje się wraz z dokumentem. `Db.query` czyta indeks partiami,
z zakresem i kursorem; jego funkcja filtruje wyniki przed zastosowaniem limitu.
Nowa `version` przebudowuje widok przed udostępnieniem Systemu. Nie ma
wspólnego dostępu do dokumentów różnych komórek. Index Todo dostaje jawnie
projekcje zadań przez obieg; przechowuje dokumenty i dwa widoki, a mały stan
zawiera tylko licznik ID. Zmiany Todo są objęte transakcjami.

Zewnętrzne efekty handlera nie podlegają rollbackowi. Codec musi odtwarzać
niezależny stan. Zmiana implementacji operacji wymaga zwiększenia `revision`;
migracje takich katalogów pozostają poza zakresem. Same zmiany widoków
są obsługiwane przez ich wersje.

SQLite zapisuje osobne rekordy KV i tylko zmienione dane. Dokumenty ani
całe indeksy nie są ładowane do RAM. Stany komórek i historia wykonań nadal
są trzymane w RAM; kompaktowanie historii wymaga dalszej pracy.
Adapter dopuszcza jednego aktywnego właściciela danego `System.id`.
**Format magazynu zmienił się:** stare snapshoty są odrzucane; przykład
uruchom z nową bazą, np. `make todo TODO_DIR=/tmp/kom-todo-documents`.

Szczegóły: [API](docs/public-api.md), [architektura](contracts/README.md),
[scenariusze](docs/stp.md), [otwarte decyzje](docs/open-questions.md).
