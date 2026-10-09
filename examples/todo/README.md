# Todo: MPA + RPC + aktorzy Kom

Uruchom z katalogu głównego repozytorium:

```sh
make todo
```

Otwórz <http://127.0.0.1:8080>. Dune buduje backend OCaml; Deno serwuje
HTML, pliki statyczne i endpoint JSON-RPC 2.0 `POST /rpc`. Nie ma zależności
JavaScript ani bundlera. Zmiana portu: `make todo TODO_PORT=8081`.

`GET /` renderuje listę, wywołując `todo.list` po stronie serwera.
`GET /new` renderuje osobną stronę dodawania. Mały skrypt formularzy
wywołuje RPC i po sukcesie przechodzi na `/`; stan strony pochodzi z nowego
pełnego dokumentu HTML. Błędy pozostawiają formularz i wpisany tekst.

## Aktorzy i obiegi

`InputPolicy` enkapsuluje zasady wejścia: usuwa białe znaki z początku i
końca tytułu, wymaga niepustego tytułu do 500 bajtów UTF-8 i dodatniego ID.
Jest komórką bez stanu. `TaskAccess` posiada prywatny stan: zadania oraz
monotoniczny licznik ID. Dodanie dopisuje zadanie na końcu listy; usunięcie
nieistniejącego ID zgłasza `NotFound`. Identyfikatory nie są używane ponownie.
Nie ma osobnego aktora dla każdej operacji ani każdego zadania.

Nazwane, deklaratywne obiegi w `model.ml` są właścicielami kolejności kroków:

| Obieg | Krok 1 | Krok 2 | Wynik |
|---|---|---|---|
| `todo.list` | `TaskAccess.List(ListRequest)` | — | `TaskList` |
| `todo.add` | `InputPolicy.PrepareAdd(AddRequest)` | `TaskAccess.Register(AddRequest)` związany z wynikiem kroku 1 | `TaskList` |
| `todo.remove` | `InputPolicy.PrepareRemove(RemoveRequest)` | `TaskAccess.Dismiss(RemoveRequest)` związany z wynikiem kroku 1 | `TaskList` |

Błąd pierwszego kroku kończy obieg przed zmianą stanu. Każda mutacja
zwraca listę z tego samego handle, który zmienił stan. Backend ma jeden
System na cały czas życia procesu, dwie instancje komórek i dwóch workerów.
Wyłączność obsługi oraz snapshoty stanu zapewnia Kom. Aktorzy nie wołają
się bezpośrednio; dane przekazuje Flow.

Wiadomości i stan snapshotu są zdefiniowane w
[`Todo.cyrograf`](../contracts/Todo.cyrograf), a kodeki pochodzą z Cyrografu.
JSON obiektu RPC jest adaptowany do typowanych wiadomości Kom; Drut i
wewnętrzny AST obiegu nie trafiają do przeglądarki.

## RPC

| Metoda | `params` | `result` |
|---|---|---|
| `todo.list` | `{}` | `{"tasks":[{"id":1,"title":"Kupić mleko"}]}` |
| `todo.add` | `{"title":"Kupić mleko"}` | aktualny `TaskList` |
| `todo.remove` | `{"id":1}` | aktualny `TaskList` |

```sh
curl http://127.0.0.1:8080/rpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"todo.add","params":{"title":"Kupić mleko"}}'
```

Odpowiedź zachowuje ID: `{"jsonrpc":"2.0","id":1,"result":{"tasks":[...]}}`.
Niepoprawny JSON daje `-32700`, niepoprawne żądanie `-32600`, nieznana
metoda `-32601`, niepoprawne parametry `-32602`, a odrzucenie przez aktora
`-32000` z kodem problemu w `error.data.code`. Obsługiwane są także batche
i powiadomienia bez ID (HTTP 204, bez odpowiedzi RPC).

`server.ts` jest adapterem HTTP/HTML. Uruchamia jeden backend OCaml i
przekazuje mu żądania JSON-RPC przez stdin/stdout, po jednym JSON na linię.
Kolejka adaptera łączy odpowiedź z właściwym wywołaniem. Całe RPC, stan i
wybór obiegów realizuje OCaml. Zamknięcie stdin kończy zakres `System.with_`.

## Zakres przykładu i weryfikacja

Jest to lokalny przykład dla jednego użytkownika, ze stanem w RAM.
Restart usuwa zadania. Serwer domyślnie słucha tylko na `127.0.0.1`.

```sh
make build
make check-contracts
make test-todo
```

Test integracyjny uruchamia prawdziwy backend i HTTP na wolnym porcie.
Sprawdza puste i osobne strony MPA, dodawanie i kolejność, normalizację,
unikalne ID po usunięciu, odrzucenie pustych/długich tytułów i błędnych
parametrów bez zmiany listy, usunięcie i NotFound, escapowanie HTML,
standardowe błędy JSON-RPC, batche, powiadomienia i równoległe żądania.
Akceptacja w przeglądarce obejmuje dodanie przez `/new`, pełną nawigację
do listy, zachowanie tekstu przy błędzie i usunięcie przez formularz.
