# Publiczna powierzchnia Kom

Ten dokument utrwala uzgodnione przeznaczenie funkcji. Nie definiuje jeszcze
ostatecznych sygnatur OCaml. Cyrografy usług nie są publicznym API do ręcznego
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
|   `-- parse        Tworzy AST z przyszłego języka tekstowego.
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

`step` i osobne `bind` zachowują robocze nazwy. `parse` obejmuje zapis Flow,
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
Publiczny uchwyt i zachowanie `send` przy buforowaniu wymagają dopracowania
zgodnie z [otwartymi szczegółami](open-questions.md).

## Mapowanie wyjść na ścieżki

Przykład pokazuje zamierzony sposób budowania AST. Sygnatury i typowane
selektory wyjść w OCaml pozostają do ustalenia:

```ocaml
let flow =
  Kom.Flow.sequence [
    Kom.Flow.step ~id:"check" ~cell:"condition" ~operation:"Evaluate";
    Kom.Flow.branch ~from:"check" [
      Kom.Flow.case ~output:true
        (Kom.Flow.step ~cell:"accepted" ~operation:"Handle");
      Kom.Flow.case ~output:false
        (Kom.Flow.step ~cell:"rejected" ~operation:"Handle")
    ]
  ]
```

`from:"check"` wskazuje węzeł konkretnego wywołania. `case` może prowadzić
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
Roboczy zapis konstruktorów, z pominięciem szczegółów wiązań danych:

```ocaml
let prepare =
  Kom.Flow.define ~id:"prepare" (
    Kom.Flow.sequence [
      Kom.Flow.step ~cell:"validator" ~operation:"Validate";
      Kom.Flow.step ~cell:"calculator" ~operation:"Calculate";
      Kom.Flow.step ~cell:"formatter" ~operation:"Format"
    ]
  )

let process =
  Kom.Flow.sequence [
    Kom.Flow.use ~as_:"preparation" prepare;
    Kom.Flow.step ~cell:"sender" ~operation:"Send"
  ]
```

`use` tworzy `UseNode`. `as_` nadaje lokalny identyfikator węzła użycia;
`UseNode.input` wiąże wejście fragmentu, a wynik całego fragmentu jest dostępny
przez ten identyfikator dla dalszego `bind` i `branch`. Dokładne sygnatury,
w tym argument wejścia i wersja `define`, pozostają do dopracowania.

Nazwany fragment musi znajdować się w katalogu rewizji Systemu. Konstruktor
`use` nie rejestruje go automatycznie. Korzeń Inline nadal może być nienazwany.
Zwykła funkcja OCaml może też budować poddrzewo bez nazwanego odwołania.

Kompozycja zachowuje istniejące instancje komórek. Każde użycie ma własny
zakres kroków, więc ten sam fragment można osadzić wielokrotnie i zagnieżdżać.
W edytorze może być prezentowany jako zwijany blok. Własne instancje i zakres
życia zapewnia System potomny. Reguły kompozycji określa
[kontrakt FlowEngine](../contracts/FlowEngine.cyrograf).
