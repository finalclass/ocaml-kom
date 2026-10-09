# Prompt dla agenta implementującego Kom

Poniższy tekst można przekazać agentowi jako polecenie implementacji.
Źródłem wymagań pozostają artefakty wskazane w [mapie specyfikacji](main.md).

```text
Zaimplementuj bibliotekę Kom w OCaml 5.

Repozytorium: https://github.com/finalclass/ocaml-kom
Publiczna przestrzeń nazw: Kom.

Pracuj jednym agentem w tym repozytorium. Well jest osobnym projektem
i pozostaje poza zakresem tego zadania.

1. Źródła prawdy i zakres upoważnienia

Przeczytaj w kolejności:
- docs/main.md;
- contracts/README.md;
- wszystkie contracts/*.cyrograf, wraz z komentarzami i diagramami;
- docs/public-api.md;
- docs/open-questions.md;
- repozytoryjne instrukcje dla wykonawcy, jeśli są dostępne.

Architektura usług została zatwierdzona. Szczegółowe reprezentacje
kontraktów i natywne sygnatury OCaml wymagają jeszcze dopracowania.

To polecenie obejmuje zarówno domknięcie zwykłych szczegółów kontraktów,
jak i implementację. Najpierw utrwal wybrane rozwiązania w odpowiednich
artefaktach specyfikacji, potem zaimplementuj je w tym samym zadaniu.
Nie kończ na planie, propozycji ani przygotowaniu samego baseline'u axe.

Możesz samodzielnie rozstrzygać szczegóły pozostawione otwarte,
zachowując zatwierdzone granice i gwarancje. Rzeczywistą sprzeczność
wymagającą zmiany architektury zgłoś konkretnie i kontynuuj prace,
które od tej decyzji nie zależą.

2. Architektura

Zachowaj:
- Client: publiczna fasada Kom oraz wewnętrzny ExecutionIngressClient;
- Managers: ExecutionManager, RevisionManager;
- Engines: FlowEngine, CellEngine;
- Accesses: ExecutionAccess, FlowAccess, CellCodeAccess, SystemAccess;
- Utilities: Scheduler, Hosting, MessageBus, Security, MessageCodec.

Manager posiada procedurę przypadku użycia. Engine posiada znaczenie
operacji i reguły. Access enkapsuluje dostęp do zasobu.

FlowEngine produkuje plan jako dane i nie wykonuje zachowania komórek.
CellCodeAccess dostarcza implementację i deskryptor, ale jej nie uruchamia.
ExecutionAccess zachowuje wspólną granicę atomowości stanu, pracy,
postępu oraz aktywacji rewizji.

SystemAccess komunikuje się z Systemem potomnym przez jego fasadę.
Nie twórz wywołania z Engine'a do Managera własnego Systemu.

Nie przenoś reguł Flow do fasady, parsera, schedulera ani Accessów.
Nie wyłaniaj dodatkowych usług z nazw publicznych modułów.

3. Publiczne API

Zaprojektuj i zaimplementuj spójne, typowane API OCaml:

Cell:
- define przyjmuje kompletny moduł komórki;
- moduł posiada kontrakt operacji, prywatny stan oraz mechanizmy
  init, handle, snapshot i restore;
- instantiate tworzy rzeczywistą instancję należącą do Systemu.

Flow:
- define, step, use, sequence, branch, case, parallel i bind tworzą AST;
- AST jest serializowalny i wspólny dla konstruktorów OCaml,
  przyszłego języka tekstowego i edytora graficznego;
- nie zawiera wykonywalnych predykatów ani closure OCaml.

System:
- define tworzy wielokrotnie używalny opis;
- create tworzy i od razu uruchamia System;
- with_ zarządza zakresem życia, także przy wyjątku;
- send wysyła wiadomość i zwraca uchwyt;
- call komponuje wysłanie z oczekiwaniem;
- await czeka na wynik wcześniej przyjętego wykonania;
- update przygotowuje i aktywuje rewizję.

Runtime pozostaje ukryty. Wykonanie Flow zawsze należy do Systemu.
Dopuszczaj zarówno nazwany Flow, jak i definicję korzenia Inline.

Publiczne Flow.parse jest przewidziane dla przyszłego języka.
Projektowanie gramatyki i edytor graficzny są osobnym etapem.
Opisz ten zakres w dokumentacji; nie wystawiaj pozornej implementacji.

4. Mapowanie wyjść w Flow

Zrealizuj model zapisany w KomTypes i FlowEngine:
- BranchNode zawiera from, cases i opcjonalny default_node_id;
- BranchCase mapuje OutputPattern na korzeń poddrzewa;
- OutputPattern obsługuje BoolValue oraz Constructor;
- wzorzec konstruktora identyfikuje typ, schema_hash i tag.

Doprecyzuj typowane selektory Bool i konstruktorów wariantów,
korzystając z deskryptorów. Przykład ergonomii znajduje się
w docs/public-api.md; nie jest wiążącą sygnaturą OCaml.

from wskazuje konkretne wystąpienie Step albo Use. Przypadek może
prowadzić do step, use, sequence lub parallel. Dopasowanie konstruktora
zachowuje oryginalną wiadomość i payload dla dalszego bind.

Walidacja musi sprawdzać dostępność źródła, zgodność typów i schematów,
istnienie konstruktorów, poprawność dzieci AST oraz pokrycie wyjść.
Odrzucaj przypadki powtórzone, nakładające się i niemożliwe.
Wymagaj pełnego pokrycia albo jawnej gałęzi domyślnej.

Wykonanie wybiera dokładnie jedno poddrzewo. Kolejność przypadków
nie ustanawia priorytetu. Default obsługuje poprawne wartości bez
dopasowania i nie maskuje naruszenia kontraktu komórki.

Obecne Output wymaga pojedynczej wiadomości w kontekście wykonania.
Nie wybieraj niejawnie pierwszego elementu MessageBatch i nie dodawaj
semantyki foreach. Przestrzegaj reguł start i advance z kontraktu.

5. Kompozycja nazwanych fragmentów Flow

Zaimplementuj Flow.use i NodeBody.Use(UseNode) jako deklaratywną
kompozycję w tym samym Systemie i wykonaniu. Nie twórz aktora grupy,
Systemu potomnego ani dodatkowej skrzynki dla użycia fragmentu.

UseNode.flow_id wskazuje nazwę w katalogu rewizji, a input wiąże
wejście fragmentu. Nazwę konkretnego użycia reprezentuje FlowNode.id;
roboczo publiczny argument as_. Nazwany fragment musi istnieć
w katalogu; korzeń Inline nie wymaga rejestracji.

FlowEngine.validate rozpoznaje transytywne zależności przez istniejące
FlowAccess.resolve. Odrzuca nieznane fragmenty, cykle zależności
i niezgodne wiązania. Zapisuje kompletny zestaw definicji i wersji
w ValidatedFlow.dependencies. System przypina go przy dopuszczeniu;
start, advance i odzyskiwanie nie rozpoznają go ponownie w bieżącym katalogu.

Każde użycie otrzymuje osobny zakres kroków, również przy zagnieżdżeniu
i parallel. Kwalifikowane identyfikatory pracy są deterministyczne
i nie kolidują. Identyfikatory komórek pozostają bez zmian, więc użycia
korzystają z tych samych istniejących instancji i ich stanów.

Input wewnątrz fragmentu oznacza jego związane wejście. Odwołania
do kroków są lokalne. Otoczenie widzi wynik całego Use, dostępny dla
bind i branch dopiero po ukończeniu wszystkich jego gałęzi i zagnieżdżeń.

Use uczestniczy w zwykłym checkpointcie, ponowieniach i rozliczaniu
pracy. Każdy rzeczywisty krok zatwierdza się osobno; nie wprowadzaj
transakcji ani wyłączności obejmującej całą grupę komórek.

Zachowaj możliwość budowania poddrzewa przez zwykłą funkcję OCaml.
Parametryzowanie identyfikatorów komórek oraz edytor graficzny nie
należą do tego rozszerzenia. Dokładne reguły posiada FlowEngine.

6. Cyrograf i samodzielność biblioteki

Natywne .cyrograf pozostają źródłem kontraktów. Zachowaj opisy usług
oraz diagramy use-case nad metodami; aktualizuj je przy doprecyzowaniu.

Generuj wiadomości i kodeki narzędziami Cyrografu. Nie implementuj
drugiego parsera języka ani ręcznego odpowiednika wygenerowanych typów.

Natywne adaptery wiążą referencje implementacji z modułami OCaml
i prywatnymi wartościami stanu. Nie serializuj modułów, closure,
wskaźników ani uchwytów zasobów procesu.

Projekt musi budować się po świeżym checkoutcie. Zależności mają być
odtwarzalne i dostępne poza lokalnymi katalogami autora.
Nie uzależniaj biblioteki od checkoutu Well.

Zaimplementuj domyślny magazyn RAM oraz opcjonalny backend SQLite,
realizujące ten sam kontrakt ExecutionAccess.

7. Gwarancje wykonania

Zrealizuj gwarancje zapisane w kontraktach, w szczególności:

- Obsługa jednej komórki jest wyłączna; niezależne komórki mogą
  pracować równolegle.

- Zatwierdzenie obejmuje razem stan komórki, rozliczenie wejścia,
  checkpoint Flow i dalszą pracę. Dalsza praca nie jest dostarczana
  przed zatwierdzeniem.

- Konflikt wersji checkpointu przy parallel powoduje ponowne
  wyznaczenie postępu na aktualnym checkpointcie. Zachowaj rezerwację
  i wyliczony wynik komórki; nie wywołuj ponownie handle.

- Scalenie parallel zachowuje kolejność gałęzi z definicji.
  Zakończenie jednej gałęzi nie kończy całego wykonania.

- Definicję i rewizję Flow wraz ze wszystkimi fragmentami przypinaj
  przy dopuszczeniu wiadomości, nie przy odebraniu jej do bufora.

- Aktualizacja buforuje nowe niezależne wejścia. Aktywna praca,
  kontynuacje, odpowiedzi i potrzebne wywołania potomne nadal
  muszą móc doprowadzić wykonywane obiegi do końca.

- Oczekiwanie na System potomny zachowuje wyłączność stanu rodzica,
  ale oddaje pojemność wykonawcy. Dziecko musi móc postępować także
  przy jednym wykonawcy.

- Stabilna tożsamość wywołania potomnego pozwala ponowieniu rodzica
  skorzystać z istniejącego dziecka lub wyniku bez duplikowania pracy.

- Trwały magazyn odtwarza przyjętą pracę, postęp, przypięte definicje
  oraz potrzebne implementacje zgodnie z kontraktem.

- Await samo nie anuluje wykonania.

- Domknięcie zakresu obejmuje Systemy potomne i zasoby procesu.

Atomowość magazynu nie zapewnia automatycznie dokładnie jednokrotnego
wykonania dowolnych efektów zewnętrznych w handle. Określ tę granicę
w dokumentacji i przykładach.

8. Aktualizacja rewizji

Najpierw przygotuj kod i Flow, potem zamknij dopuszczanie nowych
niezależnych wejść i pozwól aktywnej pracy się zakończyć.

Przygotuj snapshoty i kandydatów nowego stanu bez modyfikowania starego.
Aktywuj konfigurację i komplet stanów atomowo.

Migrację przez restore nowej implementacji próbuj również przy Force.
Force inicjalizuje od nowa tylko migracje oznaczone Unsupported.
Zachowuje udane migracje; Failed lub wyjątek odrzuca aktualizację.
Force nie omija zgodności kontraktów wiadomości.

Wersja schematu stanu jest niezależna od rewizji kodu.
Odrzucone przygotowanie pozostawia poprzednią rewizję używalną.

9. Weryfikacja

Przed pisaniem testów utwórz STP powiązany z kontraktami.
Testy mają sprawdzać obserwowalne gwarancje, a nie kopiować implementację.

Uwzględnij:
- sekwencję, wiązania, parallel i deterministyczne scalenie;
- routing true/false, konstruktorów z payloadem oraz default;
- odrzucenie brakującego pokrycia, błędnych i powtórzonych przypadków;
- dwukrotne użycie tej samej komórki z różnymi identyfikatorami kroków;
- zachowanie payloadu i niewykonanie niewybranej gałęzi;
- błędny wynik komórki, którego default nie może ukryć;
- wielokrotne i zagnieżdżone Use, również w parallel, bez kolizji
  wyników i checkpointów oraz bez tworzenia nowych instancji komórek;
- wiązanie wejścia Use, dostępność jego wyniku po ukończeniu całości
  oraz branch i bind korzystające z tego wyniku;
- odrzucenie nieznanego fragmentu, cyklu zależności i niezgodnych typów;
- przypięcie transytywnych zależności i odtworzenie wykonania
  bez użycia nowszego katalogu;
- serializację jednej komórki i równoległość niezależnych;
- konflikty checkpointu bez ponownego handle;
- atomowość, ponowienia i odzyskiwanie na rzeczywistym SQLite;
- buforowanie podczas aktualizacji, migrację i warianty Force;
- System potomny przy jednym wykonawcy, ponowienia i domknięcie.

Stosuj kontrolowaną synchronizację i fault injection zamiast testów
opartych na przypadkowych opóźnieniach.

Dodaj uruchamialne przykłady: komórka stanowa, routing wyjść,
fragment A -> B -> C użyty wielokrotnie, parallel i System potomny.
Przykłady mają używać publicznego API.

10. Szaniec

Dodaj kontrolę architektury przez Szaniec:
https://github.com/finalclass/szaniec

Przeczytaj aktualną dokumentację narzędzia. Obecny profil
well-ocaml-core analizuje artefakty OCaml 5.4.x; dobierz zgodny
toolchain i sprawdź obsługę samodzielnej biblioteki Kom.

Utwórz szaniec.toml w formacie szaniec-config/1. Roots mają obejmować
contracts oraz rzeczywiste katalogi implementacji i generowanych źródeł.
Usługi i metody wynikają z .cyrograf; nie utrzymuj równoległej listy.

KomTypes i wygenerowane wiadomości są kontraktami danych.
Stosuj contract_bindings i public_contracts tam, gdzie wymagają tego
rzeczywiste ścieżki modułów i natywne fasety. Deklaracje muszą mieć
pokrycie w dowodach kompilatora.

Approved_shared_modules służy wyłącznie zatwierdzonej infrastrukturze.
Chroń dostęp do SQLite przez politykę zasobów. Nie dodawaj wyjątków
tylko po to, aby usunąć naruszenia lub luki analizy.

Po sprawdzeniu zgodności polityki z zatwierdzoną architekturą zapisz
jej approval. Nie uruchamiaj approve automatycznie przy każdym check.

Dodaj make check-architecture do make check, uruchamiając:
szaniec check --project-root . --rebuild --json --no-callgraph

Wynik poprawny wymaga braku naruszeń i luk. Raporty przechowuj
tymczasowo poza śledzonymi plikami. Przejrzyj również:
szaniec complexity --project-root . --sort complexity

Nie traktuj braku obsługi standalone ani nierozwiązanych wywołań
jako sukcesu. Zgłoś konkretne ograniczenie narzędzia; nie dodawaj
zależności od runtime Well w celu obejścia analizy.

11. Dostarczenie

Dodaj Dune, publiczne .mli, metadane pakietu i instrukcję użycia.
Zapewnij make build, make check i make test, zachowując dotychczasowe
sprawdzenie formatowania i kontraktów Cyrografu.

Kod, identyfikatory i commity pisz po angielsku; specyfikację po polsku.
Wiedzę architektoniczną umieszczaj w kontraktach i dokumentacji.
Nowe skrypty automatyzacji pisz w TypeScript uruchamianym przez Deno.

Pracuj na istniejącej gałęzi Kom zgodnie z instrukcjami repozytorium.
Przed zakończeniem wykonaj wymagane sprawdzenia, commit i push,
pozostawiając czyste repozytorium.

W końcowej odpowiedzi podaj:
- co działa i jak uruchomić przykłady;
- rozstrzygnięte szczegóły API i kontraktów;
- wykonane sprawdzenia i ich wyniki;
- wersję Szańca, wynik analizy oraz rzeczywiste ograniczenia;
- commit i stan repozytorium.

Doprowadź zadanie do działającej biblioteki. Nie kończ na samym
szkielecie, dokumentacji ani atrapach gwarancji wykonania.
```
