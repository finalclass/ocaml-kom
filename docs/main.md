# Mapa Kom

Kom jest biblioteką OCaml do stanowych komórek i deklaratywnych obiegów JSON.

- [public-api.md](public-api.md) określa kontrakty komórek, obiegów, katalogu i wykonania.
- [contracts/README.md](../contracts/README.md) określa odpowiedzialności wewnętrzne.
- [examples.md](examples.md) określa minimalny przykład CLI.
- [stp.md](stp.md) określa scenariusze weryfikacji.
- [open-questions.md](open-questions.md) określa granice rozszerzeń.
- [lib/kom.mli](../lib/kom.mli) jest publiczną sygnaturą OCaml.
- [examples/counter/system.ml](../examples/counter/system.ml) składa obiegi i dwie instancje licznika.

Kontrakty aplikacji są natywnymi deklaracjami OCaml z deskryptorami JSON.
Nie wymagają Cyrografu ani generowania źródeł.
