# Architektura Kom

Kom jest biblioteką kompozycji komórek i obiegów wiadomości. Komórka udostępnia
operacje i prywatny stan; Flow opisuje przekazywanie wiadomości i wyników;
System posiada instancje komórek, przyjmuje wiadomości i prowadzi ich wykonania.

Podział usług został zatwierdzony 2026-10-09. Cyrografy w tym katalogu są
pierwszą propozycją szczegółowych kontraktów tego podziału. Wybrane reprezentacje
danych i nierozstrzygnięte polityki opisuje [lista otwartych szczegółów](../docs/open-questions.md).

## Granica i Client

Kod aplikacji znajduje się poza Kom. W architekturze wewnętrznej Clientem jest
**fasada API Kom**, obsługująca publiczne `Kom.Cell`, `Kom.Flow` i `Kom.System`.
Nazwy tych modułów nie wyznaczają liczby Managerów.

Fasada dostosowuje reprezentacje i przekazuje żądania do Managerów. Czyste
konstruktory definicji produkują dane. Procedury przyjmowania wiadomości,
prowadzenia pracy i aktywacji konfiguracji należą do Managerów.

`ExecutionIngressClient` jest wewnętrznym adapterem infrastruktury: przekazuje
dostarczoną pracę i ponowne dopuszczenie bufora do ExecutionManagera. Nie jest
kolejnym publicznym API ani miejscem interpretowania Flow.

## Statyczna architektura

```static-architecture
Kom

Who
- [KomApi] [ExecutionIngressClient]

What
- [ExecutionManager] [RevisionManager]

How
- [FlowEngine] [CellEngine]

How-to-access -> Where
- [ExecutionAccess]->(ExecutionStore)
- [FlowAccess]->(FlowCatalog)
- [CellCodeAccess]->(CellImplementations)
- [SystemAccess]->(NestedSystem)

Cross-cutting
- [Scheduler] [Hosting] [MessageBus] [Security] [MessageCodec]
```

## Usługi i zmienności

| Usługa | Enkapsulowana zmienność | Cel |
|---|---|---|
| [ExecutionManager](ExecutionManager.cyrograf) | Procedura dopuszczenia, obsługi, ponowienia i zakończenia wiadomości. | Doprowadzenie wiadomości do wyniku w Systemie. |
| [RevisionManager](RevisionManager.cyrograf) | Procedura przygotowania, wygaszania, migracji, aktywacji i domknięcia konfiguracji. | Udostępnienie kompletnej rewizji i zachowanie poprzedniej przy odrzuceniu przygotowania. |
| [FlowEngine](FlowEngine.cyrograf) | Znaczenie konstrukcji Flow, wiązanie danych, walidacja i wyznaczanie dalszej pracy. | Wyznaczanie poprawnego planu jako danych. |
| [CellEngine](CellEngine.cyrograf) | Zachowanie modułu komórki, inicjalizacja, obsługa i prywatny codec stanu. | Wykonanie operacji oraz przygotowanie lub odtworzenie prywatnego stanu. |
| [ExecutionAccess](ExecutionAccess.cyrograf) | Realizacja spójnego magazynowania i dopuszczania pracy w RAM lub trwałym magazynie. | Atomowe rozliczenie obsługi oraz aktywacja konfiguracji wraz ze stanami. |
| [FlowAccess](FlowAccess.cyrograf) | Pozyskiwanie i przechowywanie niezmiennego katalogu definicji. | Dostarczenie wskazanej definicji i wersji Flow. |
| [CellCodeAccess](CellCodeAccess.cyrograf) | Pochodzenie i dostarczenie wskazanej rewizji kompletnego modułu. | Dostarczenie implementacji i deskryptora bez uruchamiania zachowania. |
| [SystemAccess](SystemAccess.cyrograf) | Lokalizacja, adresowanie i wywołanie Systemu potomnego. | Kompozycja Systemów przez kontrakt zasobu. |

[KomTypes](KomTypes.cyrograf) definiuje współdzielone dane. Nie jest usługą,
Managerem ani dodatkową warstwą architektury.

RevisionManager zachowuje nazwę przyjętą w rozmowie. Obejmuje pierwszą
aktywację, dodanie instancji, zmianę rewizji i domknięcie zakresu. Ewentualna
zmiana nazwy nie jest powodem wyłaniania dodatkowego Managera.

## Granice zasobów i spójności

`ExecutionStore` posiada przyjęte i buforowane wejścia, stany komórek,
postęp wykonań, pracę do dostarczenia, wyniki oraz aktywną rewizję Systemu.
ExecutionAccess ma dwie fasety: rozliczanie pracy i zmianę aktywnej konfiguracji.
Wspólna granica pozwala zatwierdzić nową konfigurację razem z kompletem stanów.
Nie tworzymy osobnego Accessu wyłącznie dla oddzielnej tabeli czy rodzaju rekordu.

`FlowCatalog` posiada niezmienne definicje, a `CellImplementations` — kompletne
moduły i ich deskryptory. Przygotowanie katalogu lub kodu nie aktywuje ich.
Aktywna rewizja w ExecutionStore wskazuje przygotowane zasoby. Manager oddaje
niepotrzebne referencje ich właścicielom dopiero po przełączeniu lub odrzuceniu.

Obieg Inline nie wymaga wpisu w katalogu. Jego kompletna definicja zostaje
przypięta do przyjętego wykonania. Postęp wykonania należy do ExecutionStore,
a znaczenie checkpointu `FlowProgress` — do FlowEngine.

RAM i trwały magazyn realizują ten sam kontrakt ExecutionAccess. Trwały wariant
zachowuje snapshoty zamiast referencji do prywatnych wartości procesu.
Atomowość obejmuje stan, rozliczenie wejścia i dalszą pracę; nie ustanawia
automatycznie atomowości z dowolnym zewnętrznym efektem wykonywanym przez komórkę.

## Natywne moduły i model Flow

`Cell.define` przyjmuje kompletny moduł OCaml. Moduł określa kontrakt operacji,
prywatny typ stanu, `init`, `handle`, `snapshot` i `restore`. Operacji nie
rejestruje się osobnymi wywołaniami publicznego `Cell.operation`.

`ImplementationRef` i `StateRef` opisują granicę danych w kontrakcie usług.
Natywny adapter wiąże je odpowiednio z modułem i prywatną wartością OCaml.
Cyrograf nie przesyła modułu ani closure, a `StateRef` nie zastępuje snapshotu
w trwałym magazynie. Szczegółowa sygnatura tego adaptera pozostaje do przeglądu.

Flow jest deklaratywnym AST wspólnym dla konstruktorów OCaml, przyszłego
języka tekstowego i edytora graficznego. W Cyrografie drzewo zapisujemy jako
listę węzłów z identyfikatorami dzieci; język Cyrograf nie wymaga dzięki temu
typów rekurencyjnych. FlowEngine sprawdza kompletność i brak cykli.
`sequence`, `parallel`, `branch` oraz `bind` opisują dane i zależności.
Nie zawierają wykonywalnych predykatów OCaml.

## Call-chain: utworzenie Systemu

```call-chain
Utwórz i aktywuj System

[KomApi]
  -> [RevisionManager]
    -> [CellCodeAccess]
      -> (CellImplementations)
    -> [FlowAccess]
      -> (FlowCatalog)
    -> [FlowEngine]
    -> [CellEngine]
      -> [CellCodeAccess]
        -> (CellImplementations)
    -> [ExecutionAccess]
      -> (ExecutionStore)
```

Utworzenie komórki w działającym Systemie korzysta z tych samych usług.
Procedury i odmowy należą do metod `create` oraz `instantiate` w
[RevisionManager](RevisionManager.cyrograf).

## Call-chain: przyjęcie wiadomości

```call-chain
Przyjmij wiadomość do Systemu

[KomApi]
  -> [ExecutionManager]
    -> [ExecutionAccess]
      -> (ExecutionStore)
    -> [FlowAccess]
      -> (FlowCatalog)
    -> [FlowEngine]
    -> [Scheduler]
```

FlowAccess uczestniczy przy wyborze nazwanej definicji. Inline dostarcza
definicję bezpośrednio. Kolejność dopuszczenia, walidacji i zatwierdzenia
opisuje `send` w [ExecutionManager](ExecutionManager.cyrograf).

## Call-chain: obsługa kroku

```call-chain
Obsłuż przyjętą wiadomość w komórce

[ExecutionIngressClient]
  -> [ExecutionManager]
    -> [ExecutionAccess]
      -> (ExecutionStore)
    -> [CellEngine]
      -> [CellCodeAccess]
        -> (CellImplementations)
    -> [FlowEngine]
    -> [Scheduler]
```

Manager rezerwuje konkretną komórkę, wykonuje jej zachowanie i zatwierdza
wynik. Równoległe gałęzie mogą kończyć się jednocześnie. Kontrakt checkpointu
pozwala ponownie wyznaczyć dalszą pracę po konflikcie postępu, zachowując
już wyliczony wynik komórki. Diagram procedury znajduje się nad `process`.

## Call-chain: oczekiwanie na wynik

```call-chain
Oczekuj na wynik całego wykonania

[KomApi]
  -> [ExecutionManager]
    -> [ExecutionAccess]
      -> (ExecutionStore)
```

`System.call` komponuje przyjęcie i oczekiwanie w tym samym Managerze.
Komórka zwraca wynik swojej operacji; zakończenie całego wykonania ustala
System zgodnie z planem Flow.

## Call-chain: zmiana rewizji

```call-chain
Przygotuj i aktywuj nową rewizję

[KomApi]
  -> [RevisionManager]
    -> [CellCodeAccess]
      -> (CellImplementations)
    -> [FlowAccess]
      -> (FlowCatalog)
    -> [FlowEngine]
    -> [ExecutionAccess]
      -> (ExecutionStore)
    -> [CellEngine]
      -> [CellCodeAccess]
        -> (CellImplementations)
    -> [Scheduler]
```

Buforowanie dotyczy nowych niezależnych wejść. Aktywna praca, jej odpowiedzi,
kontynuacje i potrzebne wywołania potomne muszą móc się zakończyć.
Migrację i aktywację prowadzi `update` w
[RevisionManager](RevisionManager.cyrograf). Powrót bufora do wykonania
przechodzi przez infrastrukturę i ExecutionIngressClient, bez bezpośredniego
wywołania ExecutionManagera z RevisionManagera.

## Call-chain: System potomny

```call-chain
Komórka korzysta z Systemu potomnego

[ExecutionIngressClient]
  -> [ExecutionManager]
    -> [CellEngine]
      -> [SystemAccess]
        -> (NestedSystem)
```

NestedSystem jest osobnym systemem jako zasobem. Jego publiczna fasada
prowadzi do jego własnych Managerów. CellEngine nie wywołuje Managera
własnego Systemu nadrzędnego. Oczekiwanie rodzica zachowuje wyłączność
na jego stan i oddaje pojemność wykonawcy. Tożsamość wywołania pozwala
powiązać trwałe ponowienie rodzica z już wykonanym dzieckiem.

## Call-chain: domknięcie zakresu

```call-chain
Domknij System i jego potomków

[KomApi]
  -> [RevisionManager]
    -> [ExecutionAccess]
      -> (ExecutionStore)
    -> [SystemAccess]
      -> (NestedSystem)
    -> [CellEngine]
    -> [CellCodeAccess]
      -> (CellImplementations)
    -> [FlowAccess]
      -> (FlowCatalog)
    -> [Hosting]
```

`System.with_` i zakres właściciela wyzwalają domknięcie także przy wyjątku
funkcji użytkownika. Szczegóły wygaszania są w `close` RevisionManagera;
polityki graniczne wymagające decyzji znajdują się w
[otwartych szczegółach](../docs/open-questions.md).

## Infrastruktura i reguły wywołań

| Mechanizm | Odpowiedzialność |
|---|---|
| Scheduler | Przydział pojemności wykonawców, gotowość pracy i postęp podczas oczekiwania rodzica. |
| Hosting | Zakres życia, zasoby procesu i współdzielenie ukrytego Runtime. |
| MessageBus | Dostarczenie pracy i powiadomień pomiędzy adapterami wejścia a Managerami. |
| Security | Granice zaufania, uwierzytelnianie i ochrona komunikacji pomiędzy systemami. |
| MessageCodec | Wiązanie kontraktów wiadomości z kodekami Cyrografu i formatem Drut. |

To obszary infrastruktury, a nie dodatkowe Managery. Ich konkretnych
interfejsów nie wyprowadzamy mechanicznie z przypadków użycia usług.

Manager może wywołać Engine lub Access. Engine może wywołać Access.
Access nie wywołuje innego Accessu. Engine nie wywołuje innego Engine'a.
Usługi nie wywołują swoich klientów ani Managerów wyższej warstwy.
Accessy i Engine'y nie otrzymują niezależnych kolejkowanych wywołań
ani nie publikują zdarzeń biznesowych.

Diagramy `call-chain` pokazują uczestnictwo i dozwolone zależności.
Kolejność, warunki oraz rezultaty metod znajdują się w diagramach
`use-case` bezpośrednio nad ich deklaracjami w cyrografach.

## Sprawdzenie kontraktów

Z katalogu głównego repozytorium:

```sh
make check
```

Każdy `.cyrograf` zaczyna się opisem roli, enkapsulowanej zmienności i celu.
Każda metoda ma opis oraz diagram `use-case`. KomTypes jest katalogiem typów
i nie deklaruje metod. Sprawdzenie Cyrografu obejmuje dziewięć modułów jako
jeden projekt. Nie jest jeszcze dowodem realizacji gwarancji przez runtime.
