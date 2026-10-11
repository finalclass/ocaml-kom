# Architektura Kom

Fasada Kom udostępnia małe API komórek, obiegów i Systemu.
Kontrakty są natywnymi typami OCaml i serializowalnymi deskryptorami JSON.

| Właściciel | Odpowiedzialność |
|---|---|
| RevisionManager | Przygotowanie definicji, odtworzenie Systemu i inicjalizacja. |
| ExecutionManager | Przyjęcie, prowadzenie, odzyskanie i zakończenie obiegu. |
| FlowEngine | Walidacja, interpretacja AST, grupowanie i routing. |
| CellEngine | Wykonanie operacji na kandydacie stanu oraz walidacja wyniku. |
| ExecutionAccess | Atomowy zapis stanów, instancji, checkpointów i zakończeń; wyłączność instancji. |
| Db | Prywatny uchwyt dokumentów, mapowanie widoków, zakresy, kursory i przebudowa wersji. |
| FlowAccess | Odczyt DSL/AST, definicje obiegów i katalog JSON dla edytora. |
| CellCodeAccess | Rodzaje komórek i ich kontrakty operacji. |
| Eio | Standardowa pula domen, fibery, obietnice i synchronizacja; bez własnego schedulera. |
| Schema | Prywatna kontrola wartości Yojson i kontrakty Schema.t. |
| NativeContract | Współdzielone typy natywne. |

SQLite jest adapterem ExecutionAccess. Zapytania SQL nie należą do
Managerów, Engine'ów ani kodu aplikacji.
ExecutionManager komponuje FlowEngine/CellEngine/Accessy, a nie odwrotnie.
Fasada nie implementuje wykonania obiegu.
Flow nie zawiera closure ani predykatów aplikacji; implementacje pozostają
w katalogu kodu backendu. Transport HTTP/JSON-RPC należy do kom-runtime, a HTML do aplikacji.

Pakiet kom-runtime izoluje cykl życia aplikacji (RuntimeManager), natywne
artefakty (PluginAccess), rejestr i zapis plików (FileAccess), oraz transport
HTTP/Unix i CLI. Aplikacja dostarcza prezentację przez kontrakt App/Web.
RuntimeManager komponuje te komponenty i System; nie zawiera SQL ani reguł
Todo. Core Kom nie zależy od kom-runtime.
