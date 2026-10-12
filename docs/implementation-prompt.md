# Zakres bieżącej implementacji

Źródłem kontraktów są natywne definicje Cell/Flow i publiczne
[kom.mli](../lib/kom.mli), zgodnie z [API](public-api.md).

Komórki mają inline input/output/impl, cztery typy operacji oraz jawny codec
stanu. Obiegi używają DSL operation @address lub równoważnego AST JSON.
Katalog eksportuje kontrakty i AST dla edytora.

Implementacja obejmuje RAM, SQLite, checkpoint operacji, współbieżność
niezależnych komórek i odzyskiwanie. Jawne transakcje fragmentów obiegu,
prywatne dokumenty z wersjonowanymi widokami oraz System.replace należą
do biblioteki. Migracje state.version nie należą do obecnej wersji.
Nie obowiązuje wcześniejszy plan generowania Cyrografu ani jego profil Szańca.

Granice dystrybucji określa [architektura](../contracts/README.md),
a główny przykład [examples.md](examples.md). Pakiety to kom i kom-sqlite.
Build/install nie dostarcza kom-runtime ani programu hosta kom.

Testy biblioteki są niezależne od examples. Model Todo używany do sprawdzania
transakcji, dokumentów, widoków i odzyskiwania jest prywatną fixturą testów.
Testy System.replace i błędów magazynu należą do testów biblioteki.
Weryfikację określa [STP](stp.md); make check uruchamia build/install,
scenariusze biblioteki oraz scenariusz CLI. Nie wymaga serwera HTTP ani Pythona.

Kod, identyfikatory, komentarze i komunikaty są po angielsku. Dotyczy to
całego lib/, kontraktów oraz plików README.md dystrybucji. Opis implementacji
i STP mogą pozostać po polsku.
