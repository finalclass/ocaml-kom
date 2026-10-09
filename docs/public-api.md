# Publiczna powierzchnia Kom

Ten dokument określa przeznaczenie funkcji i natywne rozstrzygnięcia.
Sygnatury OCaml są w `lib/kom.mli`. Cyrografy usług nie są publicznym API do ręcznego
wywoływania Engine'ów i Accessów przez programistę.

```text
Kom
|
|-- Cell
|   |-- define       Przyjmuje kompletny moduł implementujący komórkę.
|   `-- instantiate  Tworzy instancję komórki należącą do Systemu.
|
|-- Flow
|   |-- define       Nadaje definicji nazwę i wersję.
|   |-- step         Opisuje operację komórki jako węzeł AST.
|   |-- use          Osadza nazwany Flow jako fragment w tym samym wykonaniu.
|   |-- sequence     Buduje sekwencję kroków.
|   |-- branch       Mapuje wyjście wskazanego kroku na dalszą ścieżkę.
|   |-- case         Wiąże wzorzec wyjścia z poddrzewem Flow.
|   |-- parallel     Buduje równoległe gałęzie i scalenie wyników.
|   |-- bind         Opisuje źródła danych wejściowych.
|                    Parse jest przyszłym rozszerzeniem języka tekstowego.
|
`-- System
    |-- define       Buduje wielokrotnie używalny opis Systemu.
    |-- create       Tworzy i od razu uruchamia instancję Systemu.
    |-- with_        Udostępnia System na czas funkcji i domyka jego zakres.
    |-- send         Wysyła wiadomość i zwraca uchwyt.
    |-- call         Wysyła wiadomość i czeka na wynik.
    |-- await        Czeka na wynik wcześniej wysłanej wiadomości.
    `-- update       Przygotowuje i aktywuje nową rewizję.
```

`step` i osobne `bind` zachowują nazwy. Przyszłe `parse` obejmuje zapis Flow,
a nie parsowanie kontraktów Cyrograf. Gramatyka tego języka jest osobnym etapem.
Publiczne `Flow.call`, `Cell.operation`, `System.start` i moduł Runtime nie
są częścią przyjętej powierzchni.

| Wejście przez fasadę | Właściciel procedury |
|---|---|
| `System.create`, `Cell.instantiate`, `System.update`, domknięcie zakresu | RevisionManager |
| `System.send`, `System.call`, `System.await`, dostarczenie kolejnego kroku | ExecutionManager |
| `Cell.define`, `Flow.define`, konstruktory AST i `System.define` | Tworzenie opisu w fasadzie; nie osobny Manager. |

Wyboru Flow można dokonać przez ID w katalogu aktywnej rewizji albo przez
kompletny opis Inline. W obu przypadkach wykonanie należy do Systemu.
Uchwyt i zachowanie `send` przy buforowaniu opisują natywne rozstrzygnięcia poniżej.

## Mapowanie wyjść na ścieżki

Przykład pokazuje budowanie AST przez publiczne konstruktory:

```ocaml
let flow =
  Kom.Flow.sequence [
    Kom.Flow.step ~id:"check" ~cell:"condition" ~operation:"Evaluate" ();
    Kom.Flow.branch ~from:(Kom.Flow.output "check") [
      Kom.Flow.case ~output:(Kom.Flow.bool true)
        (Kom.Flow.step ~cell:"accepted" ~operation:"Handle" ());
      Kom.Flow.case ~output:(Kom.Flow.bool false)
        (Kom.Flow.step ~cell:"rejected" ~operation:"Handle" ())
    ]
  ]
```

`from:(Flow.output "check")` wskazuje węzeł konkretnego wywołania. `case` może prowadzić
również do `sequence` lub `parallel`. W AST `branch` ma źródło `from`, listę
`cases` i opcjonalną gałąź domyślną; `case` tworzy dane `BranchCase`.

Dla wariantu, np. `Approved`, `Rejected` i `NeedsReview`, przypadek wybiera
konstruktor z jego typem kontraktu. Payload pozostaje dostępny dla dalszego
`bind`. Typowany zapis tych selektorów w OCaml musi korzystać z deskryptorów,
a nie wykonywalnego predykatu. Zasady pokrycia wyjść, gałęzi domyślnej
i wyboru ścieżki określa [kontrakt FlowEngine](../contracts/FlowEngine.cyrograf).

Własny typ stanu komórki pozostaje prywatny. Wygenerowane przez Cyrograf
wiadomości i deskryptory służą modułowi komórki, walidacji Systemu i przyszłemu
edytorowi. Zasoby procesu, takie jak połączenia, nie należą do snapshotu stanu.

## Kompozycja nazwanych fragmentów

Flow może opisywać wielokrotnie używany przebieg przez istniejące komórki.
Przykład konstruktorów, z pominięciem szczegółów wiązań danych:

```ocaml
let prepare =
  Kom.Flow.define ~id:"prepare" (
    Kom.Flow.sequence [
      Kom.Flow.step ~cell:"validator" ~operation:"Validate" ();
      Kom.Flow.step ~cell:"calculator" ~operation:"Calculate" ();
      Kom.Flow.step ~cell:"formatter" ~operation:"Format" ()
    ]
  )

let process =
  Kom.Flow.sequence [
    Kom.Flow.use ~as_:"preparation" prepare;
    Kom.Flow.step ~cell:"sender" ~operation:"Send" ()
  ]
```

`use` tworzy `UseNode`. `as_` nadaje lokalny identyfikator węzła użycia;
`UseNode.input` wiąże wejście fragmentu, a wynik całego fragmentu jest dostępny
przez ten identyfikator dla dalszego `bind` i `branch`. Sygnatury, argument
wejścia oraz wersja `define` są w publicznym `.mli`.

Nazwany fragment musi znajdować się w katalogu rewizji Systemu. Konstruktor
`use` nie rejestruje go automatycznie. Korzeń Inline nadal może być nienazwany.
Zwykła funkcja OCaml może też budować poddrzewo bez nazwanego odwołania.

Kompozycja zachowuje istniejące instancje komórek. Każde użycie ma własny
zakres kroków, więc ten sam fragment można osadzić wielokrotnie i zagnieżdżać.
W edytorze może być prezentowany jako zwijany blok. Własne instancje i zakres
życia zapewnia System potomny. Reguły kompozycji określa
[kontrakt FlowEngine](../contracts/FlowEngine.cyrograf).

## Natywne rozstrzygnięcia

`Message.codec` łączy typ wiadomości OCaml z publicznymi `to_drut` i `from_drut`
generatora oraz schematem uzyskanym przez `Cyrograf_compiler.compile`.
Tożsamość typu obejmuje deterministyczny skrót jego transytywnego schematu.
Nie ma drugiego parsera Cyrografu. Envelope jest wygenerowanym `KomTypes.Message`.
Bool i warianty korzystają z deskryptorów; `Flow.constructor` przyjmuje codec
oraz nazwę konstruktora. Pola wybiera się po nazwach kontraktu, nie po indeksach
Drut. Pola docelowe muszą pokrywać komplet wymaganych pól; brakujące opcjonalne
pozostają nieobecne. Jawne `Flow.input_type` pozwala określić typ wejścia przy
wiązaniach pól; bez niego typ wynika z wiązań Whole(Input).

Kompletny moduł komórki deklaruje prywatny `state`, identyfikator i rewizję,
wersję schematu stanu, operacje, `init`, `handle`, `snapshot`, `restore`, `release`.
Restore zwraca `Restored`, `Unsupported` albo `Failed`. Przed handle Engine
odtwarza osobnego kandydata ze snapshotu, dzięki czemu także mutowalny stan
nie zmienia stanu zatwierdzonego. Moduł odpowiada za własność zasobów zwracanych
wartości; init/restore sprzątają częściowe przygotowanie przed zwróceniem błędu.
Zasoby procesu są odtwarzane przez moduł i nie wchodzą do snapshotu.

Flow jest wygenerowaną definicją grafu drzewa. Automatyczne ID konstruktorów
są lokalnymi nazwami danych; jawne ID Step i Use służą bind i branch.
Kwalifikowane ID pracy są kodowaniem JSON listy nazw zakresów i lokalnego ID,
więc separator w nazwie nie powoduje kolizji. Sequence zwraca wynik ostatniego
poddrzewa; pusta sekwencja zwraca wejście. Parallel łączy MessageBatch w kolejności
gałęzi. Wyniki gałęzi branch są dostępne jako wynik poddrzewa, a prywatne ID
wybranej gałęzi nie są źródłami poza branch. Input fragmentu jest jego związanym
wejściem. Parse pozostaje przyszłym rozszerzeniem i nie ma pozornej funkcji.

Send zwraca `Admitted receipt`, `Buffered receipt` albo `Rejected problems`.
Receipt jest serializowalny; await zwraca Completion lub UnknownReceipt.
Bufor nie ma arbitralnego limitu; ogranicza go dostępna pamięć lub magazyn.
Po otwarciu bramki jego pierwotne wejścia przechodzą walidację aktywnej rewizji.
Zamknięcie rozstrzyga bufor błędem Closed. Nie ma automatycznego przerywania
niekończącego się handle: domknięcie czeka na aktywną pracę.

Domyślnie błąd nie powtarza pracy. Konfiguracja `max_attempts` pozwala ponawiać
błędy wykonania oraz zapisu; błędy kontraktu są końcowe. Próby zachowują stabilne
ID pracy. Atomowość obejmuje stan, checkpoint, rozliczenie i dalszą pracę.
Efekt zewnętrzny w handle może zajść ponownie po awarii przed commit; aplikacja
używa stabilnego `context.work_id` jako klucza idempotencji lub własnego outboxa.
Await nie anuluje wykonania.

System.define jest opisem wielokrotnego użytku, a System.create od razu uruchamia
pracę. Cell.instantiate dodaje instancję przez procedurę rewizji. With_ domyka
zakres także przy wyjątku. Context pozwala tworzyć i wywoływać dziecko o stabilnej
nazwie w zakresie komórki. Wywołanie dziecka ma jawny `call_id`, kwalifikowany
ID rodzica i pracy; zmiana danych ponowionego call_id jest błędem. Oczekiwanie
oddaje permit wspólnego schedulera bez oddania rezerwacji komórki.
Definicję Inline wywołania potomnego buduje się raz albo nadaje jej krokom jawne,
stabilne ID. Ponowne konstruowanie AST z automatycznymi ID tworzy inne dane.

SQLite jest opcjonalną biblioteką `kom-sqlite`; RAM i SQLite otrzymują ten sam
snapshot kontraktu ExecutionAccess. Snapshot przechowuje stany, aktywną definicję
i konfigurację, historię niezmiennych par ID/wersja Flow, przypięte definicje,
kontrakty operacji i checkpointy. Rezerwacje są rezydentne;
po restarcie nierozliczona praca otrzymuje nowe tokeny. Magazyn wymaga pojedynczego
właściciela procesu dla danego System.id. Utworzenie z istniejącym ID odtwarza
zapisany System, a nie nowszy katalog z opisu. Aplikacja dostarcza moduły dokładnych
rewizji przez definicję i dodatkowy katalog `implementations`; brak kodu lub
nieobsługiwany snapshot odrzuca wznowienie. Zamknięty System nie jest reaktywowany.
Przerwane przygotowanie aktualizacji pozostawia aktywną starą rewizję.
