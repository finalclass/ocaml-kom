# STP Kom

Weryfikacja używa kontraktu publicznego, rzeczywistego SQLite i bramek
synchronizacyjnych. Czas nie jest oracle poprawności współbieżności.

| Scenariusz | Bodziec i obserwowalna gwarancja |
|---|---|
| Sekwencja | Wynik pierwszego kroku jest wejściem drugiego; prywatny stan narasta. |
| Kontrakty | Błędne wejście, wyjście, usunięcie zachowanego pola, duplikaty kluczy, nieznane rodzaje/operacje i brakujące pola adresowania są odrzucane. Nieudana operacja nie zmienia stanu. |
| Typy JSON | Any akceptuje zagnieżdżone JSON, Null wymaga obecnego null, Int/Number obsługują Intlit, List przyjmuje mieszane elementy przez Any_of, Dict sprawdza wartości dowolnych kluczy. Optional dopuszcza brak pola, ale nie null bez jawnego typu. Puste nazwy pól są poprawne. Puste Any_of i Optional poza opisem pola są odrzucane. |
| Połączenia typów | Każda alternatywa wyjścia musi pasować do wejścia. Any nie gwarantuje String; Int pasuje do Number. Object z dowolnymi dodatkowymi polami nie gwarantuje Dict String. Scalanie ścieżek zachowuje alternatywy typów i opcjonalność; roundtrip katalogu zachowuje wszystkie nowe deskryptory. Błędy odczytu Yojson.Util są Contract i nie zatwierdzają stanu. |
| Parser/edytor | DSL i eksportowane AST przechodzą przez ten sam walidator. Roundtrip Flow.of_json zachowuje wykonanie. Katalog jest JSON i nie zawiera impl ani stanu. |
| Routing | Router wybiera jeden port. Pozostała ścieżka nie pracuje. Nieznany port, niepełne lub powtórzone pokrycie są błędami. |
| Grupy | Odwrotna kolejność zakończenia gałęzi zachowuje kolejność wejścia. Zagnieżdżenia i puste podgrupy pozostają do !flatten. Joiner pracuje raz i obsługuje []. |
| Wyłączność | Dwa wywołania tej samej instancji nie wykonują impl jednocześnie. Zablokowany handler nie blokuje innej komórki ani innego obiegu. |
| Dynamiczne instancje | Allocate jawnie tworzy ID; reproduce atomowo tworzy stan i checkpoint. Kolizje i błędne rodzaje są odrzucane. |
| SQLite | Zamknięcie i odtworzenie zachowuje stan i nie powtarza init. Zły codec, katalog lub format magazynu jest błędem. Jeden aktywny właściciel posiada System.id. |
| Rollback | Wstrzyknięty błąd SQLite po impl zachowuje poprzedni stan i wynik kroku. Mutowalny kandydat nie zmienia poprzedniego stanu. |
| Odzyskiwanie procesu | SIGKILL po zatwierdzeniu pierwszego kroku powoduje wznowienie od drugiego. Zatwierdzony krok nie pracuje ponownie. |
| Idempotencja | To samo request_id i wejście zwraca zapisany wynik bez ponownego impl. Inne dane z tym samym ID są odrzucane. |
| Cykl życia | close czeka na aktywną pracę; nowe przyjęcia są odrzucane. Runtime pracuje również z workers=1. |
| Todo/RPC | Rzeczywiste HTTP dodaje, odczytuje, listuje i usuwa zadania; niepoprawne RPC zwraca błędy. Puste/blank nazwy, brakujące lub błędne pola, powtórzone klucze żądania/parametrów oraz niefinitywne liczby nie tworzą zadania. |
| Todo/MPA | Formularze wysyłają JSON-RPC i nawigują do nowych dokumentów. Lista i szczegóły są SSR, treść użytkownika jest escapowana. Restart zachowuje zadania. |
| Dystrybucja | Build/test/install nie wymagają Cyrografu ani generowanych źródeł. |
