# Kom

`Kom` jest projektowaną biblioteką OCaml do kompozycji komórek i obiegów
wiadomości. Programista definiuje zachowanie komórek i deklaratywne Flow,
tworzy System i wysyła do niego wiadomości.

Repozytorium `ocaml-kom` zawiera zatwierdzoną architekturę oraz pierwszą
propozycję kontraktów usług w natywnym języku Cyrograf. Implementacja biblioteki
jest kolejnym etapem. Szczegółowe typy kontraktów wymagają przeglądu przed
rozpoczęciem implementacji.

- [Architektura, usługi i call-chain](contracts/README.md)
- [Publiczna powierzchnia Kom](docs/public-api.md)
- [Otwarte szczegóły kontraktów](docs/open-questions.md)
- [Mapa specyfikacji](docs/main.md)

Kontrakty sprawdza się z zainstalowanym programem `cyrograf`:

```sh
make check
```

Polecenie sprawdza format, składnię, referencje między modułami i kolizje nazw
dla targetów Cyrografu. Nie uruchamia jeszcze Systemu Kom.
