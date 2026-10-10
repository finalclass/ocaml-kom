# Mapa Kom

Kom jest biblioteką OCaml do stanowych komórek i deklaratywnych obiegów JSON.

- [public-api.md](public-api.md) określa kontrakty komórek, obiegów, katalogu i wykonania.
- [contracts/README.md](../contracts/README.md) określa odpowiedzialności wewnętrzne.
- [stp.md](stp.md) określa scenariusze weryfikacji.
- [open-questions.md](open-questions.md) określa granice rozszerzeń.
- [lib/kom.mli](../lib/kom.mli) jest publiczną sygnaturą OCaml.
- [examples/system.ml](../examples/system.ml) składa obiegi i komórki todo z osobnych plików `examples/*_cell.ml`.

Kontrakty aplikacji są natywnymi deklaracjami OCaml z deskryptorami JSON.
Nie wymagają Cyrografu ani generowania źródeł.
