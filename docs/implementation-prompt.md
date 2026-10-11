# Zakres bieżącej implementacji

Źródłem kontraktów są natywne definicje Cell/Flow i publiczne
[kom.mli](../lib/kom.mli), zgodnie z [API](public-api.md).

Komórki mają inline input/output/impl, cztery typy operacji oraz jawny codec
stanu. Obiegi używają DSL operation @address lub równoważnego AST JSON.
Katalog eksportuje kontrakty i AST dla edytora.

Implementacja obejmuje RAM, SQLite, checkpoint operacji, współbieżność
niezależnych komórek, odzyskiwanie i przykład Todo MPA przez JSON-RPC.
Jawne transakcje fragmentów obiegu i prywatne dokumenty z wersjonowanymi
widokami należą do implementacji. Runtime, pluginy natywne, przełączanie katalogu i lokalny storage plików
opisuje [runtime.md](runtime.md). Migracje state.version nie należą do obecnej wersji. Nie obowiązuje wcześniejszy plan generowania
Cyrografu ani jego profil Szańca.

Weryfikację określa [STP](stp.md); make check uruchamia build/install
oraz scenariusze biblioteki i rzeczywistego HTTP.
