# Kontrola architektury Kom

Polityka `szaniec.toml` odpowiada zatwierdzonemu podziałowi z
[kontraktów](../contracts/README.md). Roots obejmują kontrakty, implementację
i wygenerowane źródła. Usługi i metody pochodzą z `.cyrograf`.
`contract_bindings` wskazują rzeczywiste moduły `Kom_contracts.*`,
a `public_contracts` — natywne fasety `Kom.*` i ich konsumentów.
Fasety obejmują również przygotowanie zasobów, odtworzenie i skanowanie pracy.
Historia Flow jest fasetą FlowAccess, a trwała projekcja należy do ExecutionAccess.

Sprawdzenie kompilatora potwierdziło istnienie zadeklarowanych modułów i wartości.
SQLite znajduje się w rodzinie ExecutionAccess, a `Sqlite3.` jest chronionym
zasobem. `approved_shared_modules` zawiera wyłącznie Scheduler, Hosting,
MessageBus, Security i MessageCodec. Natywne dane ani fasada nie zostały
dopisane jako wyjątki infrastruktury. Po przeglądzie tej polityki zapisano
approval o skrócie
`sha256:a4af166d74903bdf8b246b67a947d8cbc0d1e7e499769e8f3da96ba270e0a519`.
Target check nie uruchamia approve.

## Narzędzie i wynik

Przeczytano aktualne [README Szańca](https://github.com/finalclass/szaniec/blob/d38f1b374bed3e31551832ba760970ed821a2b33/README.md),
[format polityki](https://github.com/finalclass/szaniec/blob/d38f1b374bed3e31551832ba760970ed821a2b33/docs/contracts/policy-format.md)
i [kontrakt interpretacji](https://github.com/finalclass/szaniec/blob/d38f1b374bed3e31551832ba760970ed821a2b33/docs/contracts/interpretation-schema.md).
Wydanie v0.1.0 nie przyjmowało `contract_bindings`; użyto aktualnego źródła
**v0.1.0-20-gd38f1b3**, commit
`d38f1b374bed3e31551832ba760970ed821a2b33`. `make tools` odtwarza ten CLI
przez Dune bez checkoutu i runtime Well. Kom używa OCaml 5.4.1+relocatable,
Dune 3.24.2 i profilu `well-ocaml-core`.

Analiza z 2026-10-09:

```sh
szaniec check --project-root . --rebuild --json --no-callgraph
```

Zwróciła **incomplete**, kod 2, **18 naruszeń i 17 luk**. Przeanalizowano
27 jednostek, 4593 wywołania i 419 referencji typów. Polityka ma `approved:true`.
Adapter OCaml: 1.5.0; interpretacja Well: 3.4.0; reguły: 3.1.0.
Wynik nie stanowi pozytywnego dowodu zgodności. `make check` kończy się błędem
na tej kontroli, po udanym build, testach i sprawdzeniu kontraktów.

Ograniczenia i nierozstrzygnięte granice:

- Osiem `SPEC-UNREGISTERED-SERVICE`: profil rozpoznaje rejestrację Well;
  natywne złożenie modułów Kom nie dostarcza obsługiwanego dowodu rejestracji.
- Osiem `IMPL-ACCESS-CROSS-SERVICE`: raport obejmuje natywne wiązanie Managera
  i Clienta w fasadzie, referencje do wariantu `Kom.Storage` i konstruktorów
  `Native_contract`, a także dwa wywołania wygenerowanego runtime Drut
  przez kodeki typów pierwotnych. Szczególnie te ostatnie nie mają deklaracji
  publicznej fasety wiadomości w źródle `.cyrograf`; nie dodano wyjątku,
  który udawałby taki dowód.
- `POLICY-UNCLASSIFIED` i `SHARED-UNAPPROVED` dotyczą `Native_contract`.
  Moduł zawiera wyłącznie typy i sygnaturę modułu, co potwierdza także
  inwentaryzacja: zero funkcji. Profil nie potrafi uzasadnić natywnej granicy
  tych danych bez deklaracji infrastruktury, której architektura nie przewiduje.
- Pięć `GAP-AMBIGUOUS-PATH` i dwanaście `GAP-UNRESOLVED-CALL` obejmuje m.in.
  funkcje lokalne i rekurencyjne, callbacki magazynu, oczekiwanie na dziecko
  oraz ścieżki `try`/`with`. Są luki również w wygenerowanym runtime Drut.

Nie stwierdzono `RESOURCE-BOUNDARY`, brakujących natywnych członków ani starych
artefaktów. Nie oznacza to usunięcia powyższych naruszeń. Pełny wynik wymaga
wsparcia natywnego złożenia i granic kontraktów przez narzędzie oraz ponownej
oceny pozostałych zależności. Nie wprowadzono zależności od Well w celu analizy.

## Złożoność

Uruchomiono i przejrzano:

```sh
szaniec complexity --project-root . --sort complexity
```

Kod 0: 1263 funkcje zmierzone, zero niemierzalnych i zero luk. Najwyższa
złożoność 34 należy do wygenerowanego `Drut_runtime.exact_integer_digits`.
W kodzie biblioteki maksimum wynosi 13: `ExecutionManager.send` oraz
rekurencyjna walidacja FlowEngine. Pomiar jest lokalny i nie dowodzi poprawności
gwarancji wykonania; te sprawdzają scenariusze STP.

Raporty JSON i tekstowe powstają tymczasowo poza śledzonymi plikami. Ten dokument
zachowuje wynik i ograniczenia, nie surowe artefakty analizy.
