# Mapa specyfikacji Kom

Architektura została zatwierdzona 2026-10-09. Repozytorium biblioteki nazywa
się `ocaml-kom`, a publiczna przestrzeń nazw — `Kom`. Biblioteka jest osobna
od Well; integracja Well nie należy do tego zestawu kontraktów.

## Źródła prawdy

- [contracts/README.md](../contracts/README.md) — granica systemu, statyczna
  architektura, odpowiedzialności, zasoby, infrastruktura i call-chain.
- [contracts/*.cyrograf](../contracts/) — autorskie deklaracje wiadomości
  oraz operacji. Komentarz na początku pliku opisuje usługę; komentarze nad
  metodami określają ich zachowanie i diagramy `use-case`.
- [public-api.md](public-api.md) — powierzchnia fasady widoczna dla programisty
  oraz jej powiązanie z usługami wewnętrznymi.
- [open-questions.md](open-questions.md) — granice dalszych rozszerzeń.
- [stp.md](stp.md) — scenariusze sprawdzania obserwowalnych gwarancji.
- [architecture-check.md](architecture-check.md) — polityka Szańca i granice analizy.

Nie ma równoległego, autorskiego kontraktu TOML. Wyniki generowania Cyrografu
są pochodne i nie są źródłem wymagań. Kod realizuje kontrakty;
testy wynikają z STP. Natywne sygnatury określa publiczne `.mli`.

[Prompt implementacyjny](implementation-prompt.md) zachowuje zakres dostarczonego
rozszerzenia. Sposób uruchamiania biblioteki i przykładów opisuje [README](../README.md).
