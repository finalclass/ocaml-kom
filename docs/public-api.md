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
|   |-- sequence     Buduje sekwencję kroków.
|   |-- branch       Buduje wybór ścieżki.
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

Własny typ stanu komórki pozostaje prywatny. Wygenerowane przez Cyrograf
wiadomości i deskryptory służą modułowi komórki, walidacji Systemu i przyszłemu
edytorowi. Zasoby procesu, takie jak połączenia, nie należą do snapshotu stanu.
