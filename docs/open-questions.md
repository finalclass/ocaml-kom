# Szczegóły kontraktów do przeglądu

Architektura jest zatwierdzona. Poniższe szczegóły należą do dalszego
projektowania kontraktów; wstępne deklaracje Cyrografu są propozycją
reprezentacji, a nie zatwierdzoną sygnaturą natywnego API.

## Natywne wiązanie modułu i stanu

Cyrograf opisuje wiadomości, nie prywatne typy modułów OCaml.
`ImplementationRef` i `StateRef` są projekcją referencji adaptera.
Trzeba określić typowaną sygnaturę modułu komórki, upakowanie jego typów,
własność kandydatów stanu i zasobów oraz sposób przejścia pomiędzy referencją
rezydentną a snapshotem. Nie wolno zastąpić tym serializacji wskaźników procesu.

## Dokładny model Flow

Lista węzłów z identyfikatorami jest propozycją serializowalnej reprezentacji
AST. Do ustalenia pozostają reprezentacja heterogenicznych wyników parallel,
reguły wiązania pól i kształt wyniku całego Flow. Mapowanie wyjść Bool oraz
konstruktorów wariantu i gałąź domyślna są określone w
[kontrakcie FlowEngine](../contracts/FlowEngine.cyrograf). Otwarty pozostaje
natywny, typowany zapis selektorów. Obecne źródło Output wymaga pojedynczej
wiadomości; ewentualny jawny wybór z MessageBatch wymaga osobnego projektu.
`step` i osobne `bind` zachowują robocze nazwy. Gramatyka tekstowego języka
Flow nie została jeszcze zaprojektowana.

## Przyjęcie i buforowanie

Wstępny kontrakt rozróżnia `Admitted` i `Buffered`, zachowując ten sam uchwyt
przy późniejszym dopuszczeniu bufora. Trzeba uzgodnić publiczną reprezentację
tego uchwytu i odmowy wejścia, które po aktualizacji nie przechodzi walidacji.
Nie rozstrzygnięto pojemności bufora ani zachowania po jej wyczerpaniu.
Rewizję Flow przypina się przy dopuszczeniu, nie przy odebraniu do bufora.

## Ponowienia i domknięcie

Manager podejmuje decyzję o ponowieniu lub niepowodzeniu; Access atomowo ją
realizuje. Do ustalenia pozostają klasyfikacja błędów, liczba prób, opóźnienia
oraz zachowanie, gdy aktywna praca nigdy się nie kończy. Trzeba również
rozstrzygnąć bufor aktualizacji, jeśli właściciel zamiast wznowienia zamyka System.
Oczekiwanie wywołującego samo nie anuluje wykonania.

## Zakres rewizji i odzyskiwanie

ExecutionAccess zachowuje wspólną granicę atomowej aktywacji i rozliczania
pracy, z dwiema fasetami kontraktu. Szczegóły dotyczą zakresu wygaszania przy
tworzeniu instancji, usuwania komórek, trwałego wznowienia po przerwaniu
przygotowania oraz własności zasobów kodu i katalogu po restarcie.
Przypięte implementacje, definicje Flow i checkpointy muszą być dostępne
do odtworzenia już przyjętej pracy.

## Systemy potomne i granice efektów

Wymagane są stabilne tożsamości wywołań potomnych, postęp dziecka podczas
oczekiwania rodzica oraz domknięcie zakresu właściciela. Trzeba określić
natywny kontekst tych wywołań i granicę ich transportu. Atomowe zatwierdzenie
ExecutionStore nie obejmuje dowolnego zewnętrznego efektu w handle;
kontrakt komórki musi określić semantykę takich efektów przy ponowieniu.
