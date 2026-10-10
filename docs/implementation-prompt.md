# Zakres bieżącej implementacji

Źródłem kontraktów są natywne definicje Cell/Flow i publiczne
[kom.mli](../lib/kom.mli), zgodnie z [API](public-api.md).

Komórki mają inline input/output/impl, cztery typy operacji oraz jawny codec
stanu. Obiegi używają DSL operation @address lub równoważnego AST JSON.
Katalog eksportuje kontrakty i AST dla edytora.

Implementacja obejmuje RAM, SQLite, checkpoint operacji, współbieżność
niezależnych komórek, odzyskiwanie i przykład Todo MPA przez JSON-RPC.
Pełne transakcje obiegu, aktualizacja aktywnego katalogu i migracje nie
należą do obecnej wersji. Nie obowiązuje wcześniejszy plan generowania
Cyrografu ani jego profil Szańca.

Weryfikację określa [STP](stp.md); make check uruchamia build/install
oraz scenariusze biblioteki i rzeczywistego HTTP.
