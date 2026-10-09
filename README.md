# Kom

Biblioteka OCaml 5 do stanowych komórek i deklaratywnych obiegów wiadomości.
Publiczne API to `Kom.Cell`, `Kom.Flow`, `Kom.System`, typowane kodeki `Message`
i kontekst wywołań potomnych `Context`. Runtime należy do Systemu.

Działają sekwencje, wiązania całych wiadomości i pól, routing Bool i wariantów,
parallel z deterministycznym scaleniem oraz wielokrotne, zagnieżdżone fragmenty
Use. Komórki mają prywatny stan; niezależne komórki mogą pracować równolegle.
Magazyn RAM jest domyślny, a SQLite jest osobnym pakietem `kom-sqlite`.
Aktualizacja wygasza aktywną pracę, buforuje nowe wejścia i atomowo aktywuje
komplet stanów. Systemy potomne współdzielą pojemność schedulera i działają
również przy jednym wykonawcy.

## Budowanie i sprawdzanie

Wymagane są Dune **3.24.2**, Deno 2, Git, Make, narzędzia kompilacji C,
pkg-config i biblioteka systemowa SQLite z nagłówkami, np. `libsqlite3-dev`
na Debianie. Dune odtwarza OCaml **5.4.1** i zależności z `dune.lock`.
Cyrograf jest przypięty do publicznego commitu; nie potrzeba checkoutu Well,
lokalnego switcha opam ani plików z `/home/sel`.

```sh
make build
make test
make check-contracts
make check
```

`make test` uruchamia scenariusze gwarancji i przykłady. Testy SQLite obejmują
rollback oraz odzyskiwanie po `SIGKILL` w osobnych procesach. `make check`
dodaje kontrolę architektury; jej niekompletny wynik jest błędem polecenia,
nie sukcesem. Aktualne ograniczenie profilu Szańca opisuje
[sprawdzenie architektury](docs/architecture-check.md).

Kod wiadomości i kodeki pochodzą z Cyrografu. `make generate` odtwarza źródła,
a `make check-contracts` sprawdza ich zgodność z kontraktami oraz formatowanie.
Nowe pomocnicze skrypty uruchamia Deno.

## Przykłady

Z katalogu repozytorium:

```sh
dune exec examples/main.exe -- stateful
dune exec examples/main.exe -- routing
dune exec examples/main.exe -- fragments
dune exec examples/main.exe -- parallel
dune exec examples/main.exe -- child
```

`make examples` uruchamia wszystkie. Fragment A → B → C korzysta z tych samych
instancji podczas dwóch użyć; przykład dziecka ma `workers:1`. Wszystkie
przykłady korzystają z publicznego API i wygenerowanych wiadomości.

## Użycie w programie

Biblioteka Dune: `(libraries kom)`. Backend SQLite: `(libraries kom kom-sqlite)`.
Wiadomości aplikacji należy wygenerować poleceniem `cyrograf build` i połączyć
z ich schematem przez `Kom.Message.codec`. Kompletny przykład modułu komórki,
kodeków i Systemu jest w [examples/model.ml](examples/model.ml).

```ocaml
let definition =
  Kom.System.define
    ~cells:[Kom.Cell.spec ~id:"counter" counter]
    ~flows:[] ()

let flow =
  Kom.Flow.inline
    (Kom.Flow.step ~id:"add" ~cell:"counter" ~operation:"Add" ())

let result =
  Kom.System.with_ definition (fun system ->
    Kom.System.call system ~flow (Kom.Message.encode amount_codec input))
```

`counter`, `amount_codec` i `input` pochodzą z aplikacji. Dla SQLite dodaj
`~storage:(Kom_sqlite.storage "execution.sqlite")`; jawne `~id` pozwala
odtworzyć przyjętą pracę po przerwaniu procesu. Program odzyskujący musi
udostępnić dokładne przypięte rewizje modułów w definicji lub katalogu
`implementations`. Magazyn odtwarza zapisane definicje, zamiast zastępować je
nowszym katalogiem. Jeden aktywny właściciel posiada dany System.id.

`with_` domyka zakres przy wyniku i wyjątku. Samodzielne `create` należy do
zakresu procesu i jest domykane przy normalnym zakończeniu programu.
Await nie anuluje pracy. Domknięcie czeka na aktywne handle.

Stan musi dać się odtworzyć ze snapshotu; zasoby procesu nie są serializowane.
Engine wykonuje handle na osobnym kandydacie, także dla mutowalnego stanu.
Udane handle przekazuje własność zasobów kandydata do zwracanego stanu;
moduł odpowiada za sprzątnięcie zasobów, których nie przekazuje dalej.

Atomowy commit nie obejmuje dowolnych efektów zewnętrznych handle.
Po awarii przed commit efekt może zajść ponownie. `Kom.Context.work_id ctx`
jest stabilnym kluczem idempotencji dla API zewnętrznego lub outboxa aplikacji.
Test z rollbackiem SQLite pokazuje dwa wywołania handle i jedno zatwierdzenie
stanu. Nie jest to gwarancja dokładnie jednokrotnego efektu zewnętrznego.

## Kontrakty

- [Architektura i właściciele procedur](contracts/README.md)
- [Natywne API i rozstrzygnięcia](docs/public-api.md)
- [Publiczna sygnatura OCaml](lib/kom.mli)
- [STP powiązany z kontraktami](docs/stp.md)
- [Granice dalszych rozszerzeń](docs/open-questions.md)

Tekstowa gramatyka Flow.parse, edytor i parametryzacja komórek Use pozostają
poza tym rozszerzeniem. Flow jest serializowalnym AST i nie zawiera predykatów
ani closure aplikacji.
