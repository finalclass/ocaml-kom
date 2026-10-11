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
| Eio/IO | Przy workers=1 handler oczekuje na Eio.Promise, a inna komórka kończy operację. Ta sama instancja czeka; kolejność grupy nie zależy od kolejności zakończenia. |
| SQLite/IO | Zewnętrzny writer blokuje zapis jednego Systemu, a drugi System kończy obieg w tym czasie. Zapis po zwolnieniu blokady kończy się poprawnie. |
| Eio/anulowanie | Anulowanie oczekującego klienta nie przerywa przyjętego obiegu; anulowanie Switch zwalnia pulę i magazyn. Niezatwierdzony stan nie ucieka; request_id jest wznawiany. Klient w nadrzędnym Switch dostaje Closed po anulowaniu Systemu; tworzenie na wygasłym Switch nie otwiera backendu, a anulowana inicjalizacja sprząta zasoby. Call i close działają z innych domen. Reentrant jest lokalne dla fibera. Błąd gałęzi czeka na już uruchomione gałęzie. |
| Wiadomości | Równoległe gałęzie tworzą niezależne wyniki bez zmiany wejściowego JSON, także przy IO. |
| Dynamiczne instancje | Allocate jawnie tworzy ID; reproduce atomowo tworzy stan i checkpoint. Kolizje i błędne rodzaje są odrzucane. |
| SQLite | Zamknięcie i odtworzenie zachowuje stan i nie powtarza init. Zły codec, katalog lub format magazynu jest błędem. Jeden aktywny właściciel posiada System.id. |
| Rollback | Wstrzyknięty błąd SQLite po impl zachowuje poprzedni stan i wynik kroku. Mutowalny kandydat nie zmienia poprzedniego stanu. |
| Odzyskiwanie procesu | SIGKILL po zatwierdzeniu pierwszego kroku powoduje wznowienie od drugiego. Zatwierdzony krok nie pracuje ponownie. |
| Idempotencja | To samo request_id i wejście zwraca zapisany wynik bez ponownego impl. Inne dane z tym samym ID są odrzucane. |
| Cykl życia | close czeka na aktywną pracę; nowe przyjęcia są odrzucane. Runtime pracuje również z workers=1. |
| Todo/RPC | Rzeczywiste HTTP dodaje, odczytuje, listuje i usuwa zadania; niepoprawne RPC zwraca błędy. Puste/blank nazwy, brakujące lub błędne pola, powtórzone klucze żądania/parametrów oraz niefinitywne liczby nie tworzą zadania. Intlit z komentarzem lub białymi znakami jest odrzucany. |
| Todo/MPA | Formularze wysyłają JSON-RPC i nawigują do nowych dokumentów. Lista i szczegóły są SSR, treść użytkownika jest escapowana. Restart zachowuje zadania. |
| Dystrybucja | Build/test/install nie wymagają Cyrografu ani generowanych źródeł. |
| Kolekcje i izolacja | Dwie instancje tego samego rodzaju zapisują ten sam ID i mają różne prywatne dokumenty oraz widoki. Uchwyt zachowany po operacji jest nieważny. Zmiana/usunięcie dokumentu aktualizuje indeks, błąd map nie zatwierdza dokumentu ani stanu. |
| Zakresy i strony | Powtórzone klucze, ujemne int, string i klucze złożone mają stabilny porządek. Granice zakresu są inkluzywne; filtrowanie działa przed limit, a cursor nie gubi wpisów. Obcy kursor lub niezarejestrowany widok są błędami. |
| Wersje widoków | Restart z tą samą wersją nie uruchamia map ponownie. Podbicie version przebudowuje indeks eager przed pierwszym call. Błąd map podczas przebudowy pozwala ponownie otworzyć starą definicję. Katalog i AST eksportują widoki i transaction. |
| Transakcje obiegów | Błąd późniejszej komórki, walidacji, codec lub SQLite odrzuca wcześniejsze dokumenty, indeksy, mutowalny stan, instancje i checkpointy fragmentu. Odczyty widzą własne zapisy, również w parallel. Niezależna komórka działa podczas IO; konkurencyjna zmiana daje Conflict bez utraty zapisu. Zagnieżdżenie jest błędem. |
| Odzyskiwanie transakcji | SIGKILL przed commit fragmentu nie pozostawia częściowych danych; po wznowieniu fragment zatwierdza się raz. Zatwierdzony fragment i request_id nie są powtarzane. |
| Todo/widoki | Zadania mają done i priority. Obieg aktualizacji jawnie aktualizuje projekcję indeksu w tej samej transakcji. RPC odczytuje zakończone zadania według zakresu priorytetów i kontynuuje przez cursor. Restart zachowuje dokumenty, widoki i mały licznik ID. |
