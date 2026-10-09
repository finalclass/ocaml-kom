# STP Kom

Plan powiązany z natywnymi kontraktami jest źródłem scenariuszy testowych.
Synchronizacja używa bramek, warunków i wstrzykiwanych błędów; czas nie jest
oracle poprawności. Testy integracyjne korzystają również z rzeczywistego SQLite.

| Scenariusz | Kontrakt | Bodziec i obserwowalna gwarancja |
|---|---|---|
| Sekwencja i bind | FlowEngine.validate/start/advance | Dwa kroki tej samej komórki mają różne ID, przekazują wynik, a stan narasta. Fields tworzy wiadomość zgodną z deskryptorem. |
| Routing | FlowEngine.validate/advance, CellEngine.handle | Bool true/false, konstruktor z payloadem i default wybierają jedną gałąź. Payload pozostaje w dalszym bind. Niepełne pokrycie, nieznany lub powtórzony przypadek i błędny wynik są odrzucane, także z default. |
| Use | FlowEngine.validate/start/advance | A → B → C użyte wielokrotnie, zagnieżdżone i równolegle zachowuje instancje, izoluje ID, wiąże wejście i udostępnia wynik dopiero po całości. Branch i bind czytają wynik Use. |
| Zależności | FlowEngine.validate | Nieznany fragment, cykl, nieosiągalny węzeł, błędny typ i niedostępne Output zostają odrzucone. Odtworzenie używa przypiętych transytywnych definicji mimo nowszego katalogu. |
| Parallel | FlowEngine.advance, ExecutionManager.process | Bramki kończą gałęzie w odwrotnej kolejności; wynik ma kolejność definicji. Jedna gałąź nie kończy wykonania. Konflikt checkpointu nie powtarza handle. |
| Wyłączność | ExecutionAccess.reserve | Zablokowana komórka nie rozpoczyna drugiego handle; niezależna komórka pracuje równolegle i nie czeka na zajętą. |
| Atomowość | ExecutionAccess.admit/commit/release | Błąd przed trwałym commit zachowuje stary stan i nie dostarcza następnego kroku. Ponowienie nie dubluje zatwierdzonej pracy. Ten sam token daje AlreadyCommitted. |
| Odzyskiwanie | ExecutionAccess, CellCodeAccess, CellEngine.restore, FlowAccess.stage | Nowy proces odtwarza aktywną definicję, przypięty Flow, snapshot, nierozliczoną pracę i wynik. Brak dokładnej implementacji odrzuca wznowienie. Historia wcześniejszych wersji nadal odrzuca zmianę treści tej samej pary ID/wersja po aktualizacji i restarcie. SQLite odzyskuje pracę po przerwaniu procesu i rollbacku. |
| Aktualizacja | RevisionManager.update, ExecutionAccess.quiesce/activate/resume | Nowe wejście trafia do bufora i otrzymuje wynik po walidacji nowej rewizji. Aktywne gałęzie i dzieci kończą pracę. Failed i wyjątek zachowują poprzednią rewizję. Force zachowuje udaną migrację, resetuje tylko Unsupported i nie omija kontraktów. |
| Dziecko i zakres | SystemAccess, RevisionManager.close | Rodzic przy jednym wykonawcy czeka na dziecko, zachowując wyłączność. Ponowienie ze stabilnym call_id nie wykonuje dziecka ponownie. With_ domyka dziecko i zasoby także przy wyjątku. Await nie anuluje pracy. |
| Dystrybucja | docs/public-api.md | Przykłady używają wyłącznie publicznego API; świeży checkout buduje się z przypiętymi publicznymi zależnościami. |
| Architektura | contracts/README.md | Szaniec analizuje rzeczywiste źródła i artefakty 5.4.x; poprawny wynik wymaga zera naruszeń i luk. Ograniczenie standalone jest jawnym wynikiem negatywnym, bez zależności od Well. |

## Wynik weryfikacji 2026-10-09

`make build test check-contracts` zakończyło się kodem 0: 20 scenariuszy,
pięć przykładów publicznego API, formatowanie i walidacja 9 kontraktów Kom
oraz kontraktu przykładów, zgodność generowanych źródeł i deskryptorów.
Powtórzono ten zestaw na czystym eksporcie drzewa Git w osobnym katalogu,
bez kopiowania `_build`, lokalnych narzędzi ani zależności projektu.
Dune odtworzyło OCaml 5.4.1+relocatable i pakiety z publicznego lockfile.
`deno check` zaakceptowało oba skrypty automatyzacji.

`make check` zakończyło się kodem 2 na kontroli architektury. Szczegółowy wynik
i ograniczenia Szańca znajdują się w [architecture-check.md](architecture-check.md).
Pomiar złożoności zakończył się kodem 0 i bez luk.
