# Publiczne API Kom

Kom.msg jest wspólnym typem wiadomości, aliasem Yojson.Safe.t. Po open Kom
jest dostępny jako msg; aplikacja nie deklaruje własnego aliasu.
Wiadomości mają semantykę wartości i są niezmienne: handler tworzy nową
wiadomość zamiast zmieniać wejście. Struktury Yojson można współdzielić
między komórkami i gałęziami; fizyczna kopia JSON przy przekazaniu nie jest
wymagana. Prywatny stan komórki jest osobno odtwarzany przez codec.
Kom nie udostępnia modułu Json. Aplikacja używa konstruktorów Yojson,
Yojson.Safe.from_string/to_string i Yojson.Safe.Util do odczytu wartości.
Wiadomość jest obiektem JSON. Schema.t opisuje Any, Null, String, Int,
Number, Bool, List, Object, Dict, Any_of i Optional.
Any przyjmuje każdą poprawną wartość JSON. Int obejmuje również duże liczby
całkowite Intlit; Number obejmuje Int, Intlit i skończone Float.
List opisuje typ każdego elementu, Dict typ każdej wartości dowolnego klucza,
a Any_of niepustą alternatywę typów. Object opisuje wymagane/gwarantowane pola.
Wymagane pola muszą istnieć i mieć zadeklarowane typy.
Optional jest dozwolone wyłącznie jako zewnętrzny opis pola i pozwala
na jego brak. Obecne pole podlega walidacji wewnętrznego typu; null wymaga
Null, Any lub odpowiedniej alternatywy Any_of. Nadmiarowe pola są dopuszczalne.
Nazwą pola może być pusty string. Duplikaty nazw są błędem.
Powtórzone klucze JSON i deskryptorów są błędem.
Kom prywatnie kontroluje duplikaty kluczy i poprawność liczb oraz normalizuje
błędy Yojson na Contract. Te kontrole nie należą do publicznego API JSON.
Sprawdzanie połączeń obiegu wymaga, aby każdy wariant wyjścia był akceptowany
przez wejście następnego kroku. Any nie gwarantuje konkretnego typu.
Scalanie informacji o ścieżkach tworzy Any_of dla różnych typów tego samego
pola. Pole niegwarantowane w którejś ścieżce nie staje się wymaganym polem.

Cell.define opakowuje prywatny typ stanu. Specyfikacja zawiera id, state
i operations. State zawiera version, init, to_string i of_string.
of_string zwraca result i odtwarza niezależną wartość; zasoby procesu
nie należą do stanu. Błędny codec lub wersja zatrzymuje odtworzenie.
W przykładzie Todo konwersje typów State do/z JSON generuje
ppx_deriving_yojson przez [@@deriving yojson]. Kodek tekstowy łączy
wygenerowane konwersje z odczytem/zapisem JSON.
Opcjonalna revision komórki identyfikuje implementację; zmiana zachowania
operacji wymaga nowej revision. Same zmiany widoków identyfikuje version widoku. System przy odtwarzaniu wymaga zgodnego katalogu.

Operacje mają nazwę string, input, output i impl przy kontrakcie:
- Transformer: Db.t -> state -> msg -> state * msg.
- Expander: Db.t -> state -> msg -> state * msg list.
- Joiner: Db.t -> state -> msg list -> state * msg.
- Router: Db.t -> state -> msg -> state * (string * msg).

Db.t jest uchwytem ważnym tylko podczas operacji. Runtime przypisuje go do
konkretnej instancji i kontekstowi jej handlera. Przekazanie uchwytu do innego
handlera jest odrzucane, także gdy właściciel nadal pracuje. Nie udostępnia owner, połączenia SQL ani dostępu do
danych innej instancji. Komórka może posiadać dowolną kolekcję dokumentów
w postaci obiektów JSON, adresowanych stringiem przez Db.get/put/delete. Dane nie są ładowane
w całości do RAM. Pusta kolekcja nie wymaga osobnego pliku ani tabeli.

Db.view przyjmuje id, version, key i map. Map zwraca None lub Some (key,
JSON value), jest deterministyczne i nie wykonuje IO ani operacji Db.
Klucze mają jawny porządek: Db.int, Db.string i Db.pair. Widoki rejestruje
Cell.define przez opcjonalne views z Db.View. Runtime aktualizuje je eager
razem z dokumentem; zmiana i usunięcie dokumentu usuwają jego stare wpisy.
Każdy widok należy do prywatnej kolekcji konkretnej instancji.

Db.query zwraca page z items i cursor. Opcjonalne from_key/to_key są
inkluzywne, limit ogranicza liczbę wyników po funkcji filtrującej, a after
jest kursorem kontynuacji. Funkcja odczytu None/Some nie tworzy indeksu.
Runtime czyta wpisy partiami; nie analizuje ani nie optymalizuje closure.
Kolejność to klucz widoku, następnie ID dokumentu. Kursor jest związany z
instancją, widokiem, wersją i zakresem. Paginacja jest żywa: zmiany między
stronami mogą zmienić wyniki; nie jest snapshotem wielu wywołań.
Programista ręcznie podbija version po zmianie map. Nowa wersja jest
przebudowywana przed udostępnieniem Systemu. Niezmieniona wersja nie
powoduje przebudowy; zmiana typu klucza wymaga nowej wersji. Błąd przebudowy
nie publikuje nowego katalogu. Inne zmiany niezgodnego katalogu są odrzucane.

input/ output operacji opisują wymagane/gwarantowane pola. Transformer
zachowuje wartości pól wejścia poza deklarowanym output. Router zachowuje
je poza output wybranego portu. Expander tworzy nowe wiadomości; output
dotyczy każdego elementu. Joiner przyjmuje płaską grupę; input dotyczy
każdego elementu, a output pojedynczego wyniku. Router deklaruje porty
z ich output i wybiera dokładnie jeden. Nieznany port jest błędem.

Flow.define przyjmuje id, input, output i body z tekstowym DSL.
Flow.of_json odczytuje tę samą definicję z AST JSON, bez closure.
Opcjonalna version identyfikuje niezmienny obieg.
System.define waliduje całość przed uruchomieniem. System.catalog eksportuje
JSON kontraktów, AST i jawnych wzorców adresów dla edytora, bez stanu i impl.

DSL:
- operation @address wywołuje operację komórki.
- !sequence(...) przekazuje cały wynik fragmentu do następnego.
- !transaction(fragment) zatwierdza fragment jako jedną transakcję.
- !reproduce kind as address tworzy instancję i przepuszcza wejście.
- !parallel(...) wykonuje fragmenty na tym samym wejściu.
- !parallel_each(fragment) wykonuje fragment na każdym elemencie płaskiej grupy.
- !flatten jawnie spłaszcza zagnieżdżone grupy.
- !branch(source Port(fragment) ...) wybiera fragment według portu Routera.

Adres może zawierać {$ .field} bez spacji: np. task.{$.task_id}.
Wymaga to pojedynczej wiadomości z wymaganym polem String.
Powiązania wzorców adresu z rodzajem pochodzą z reproduce.
Powtórzone powiązanie tego samego wzorca z innym rodzajem jest błędem.
Runtime sprawdza również rodzaj faktycznej instancji i kolizje adresów.

Parallel i parallel_each czekają na uruchomione gałęzie i zachowują
kolejność deklaracji/elementów wejścia. Wynik gałęzi będący grupą pozostaje
podgrupą, również pustą. Brak automatycznego spłaszczania lub mapowania.
Joiner dostaje całą płaską grupę raz, również [].
Niewybrane porty nie są uruchamiane i nie blokują scalenia.
Błąd zatrzymuje planowanie kolejnych elementów; uruchomione gałęzie
kończą się przed zgłoszeniem zakończenia wykonania.

System.create ~sw ~domain_mgr uruchamia System w zakresie Eio.Switch,
z RAM lub Storage.backend, także SQLite. Aplikacja uruchamia Eio_main.run
i przekazuje Switch oraz Eio.Stdenv.domain_mgr. workers określa liczbę
domen puli Eio.Executor_pool; oczekiwanie na IO zwalnia wykonawcę dla
innych komórek nawet przy workers=1. Operacje używają przechwyconych
możliwości Eio (np. clock, net); blokujące Unix/Thread nie stają się
automatycznie asynchroniczne.
init_flow jest wewnętrzny i wykonuje się raz dla świeżego Systemu.
System.call przyjmuje nazwę Flow i JSON, waliduje input i zwraca JSON
zgodny z output. Opcjonalny request_id umożliwia ponowienie tego samego
wykonania; jego ponowne użycie z innym Flow lub input jest błędem.
System.close zatrzymuje nowe przyjęcia, czeka na aktywną pracę i zwalnia
magazyn oraz wykonawców. Zamknięty magazyn można ponownie otworzyć.
Właściciel może wywołać close, np. w Fun.protect; zakończenie Switch
również zwalnia System. System.call i close mogą być używane z innych
domen; standardowy Eio.Stream przekazuje przyjęte wykonania do zakresu właściciela.
Anulowanie klienta oczekującego w System.call przerywa oczekiwanie,
a przyjęty obieg kontynuuje w zakresie Systemu. Anulowanie zakresu Systemu
przerywa pracę i pozostawia nieukończone checkpointy do wznowienia.
Eio.Cancel.Cancelled nie jest zapisywane jako zakończony błąd obiegu.
Znacznik callback jest lokalny dla fibera, także po zawieszeniu na IO.

Atomowość obejmuje pojedynczą operację: stan komórki, dokumenty, wpisy
widoków, wynik kroku i checkpoint zatwierdzane są razem. Tworzenie instancji z checkpointem
jest również atomowe. Handler działa na stanie odtworzonym z tekstu;
błąd walidacji, serializacji lub zapisu zachowuje poprzedni stan.
Operacje tej samej instancji są serializowane; niezależne instancje
i różne obiegi mogą pracować równolegle. SQLite utrzymuje transakcję
tylko przez krótki zapis, nigdy podczas impl. Adapter SQLite wykonuje
blokujące wywołania w standardowej puli Eio_unix.run_in_systhread. Oczekiwanie na zewnętrzną
blokadę SQLite nie zatrzymuje innych Systemów ani fiberów HTTP.

W !transaction stany, dokumenty, indeksy, nowe instancje i checkpointy
pozostają kandydatami aż do jednego commit. Błąd lub anulowanie je odrzuca,
również dla mutowalnego stanu w RAM. Kolejne operacje widzą własne zapisy.
Niezależne komórki nie są blokowane przez czas działania fragmentu.
Konflikt współbieżnej zmiany którejkolwiek odczytanej komórki odrzuca
transakcję jako Conflict, bez automatycznego powtarzania handlerów.
Transakcje zagnieżdżone są odrzucane przy definiowaniu Systemu.
SQLite trzyma transakcję wyłącznie podczas krótkiego commit, nie podczas IO.
Po awarii niezakończony fragment transakcyjny wykonuje się od początku;
zatwierdzony fragment nie powtarza operacji. Poza !transaction kroki
pozostają zatwierdzone po błędzie późniejszego kroku. Nieukończony obieg odtwarza
się z checkpointów bez powtarzania zatwierdzonych operacji.
Zapisany wynik zakończonego request_id nie jest wykonywany ponownie.
Zewnętrzne efekty impl nie należą do transakcji i mogą się powtórzyć
po awarii przed commit. Reentrant System.call z impl jest odrzucane.

Storage.backend jest adapterem uporządkowanego KV: get, scan(range),
commit(list of puts/deletes), close. Commit jest atomowy i trwały;
scan respektuje prefix, inkluzywne first/last, ekskluzywne after i limit.
Runtime zapisuje osobne rekordy metadanych, stanów, wykonań i dokumentów.
Nie serializuje całej bazy podczas operacji. Format magazynu jest jawny;
niezgodny wcześniejszy magazyn jest odrzucany, nie czyszczony.

Error zawiera code, message i opcjonalny path. Błędy RPC należą
do adaptera transportowego aplikacji, poza Kom.
