# Publiczne API Kom

Wiadomość jest obiektem JSON. Schema opisuje String, Int, Float, Bool, List,
Object i Optional. Wymagane pola muszą istnieć i mieć zadeklarowane typy.
Optional pozwala na brak pola lub null. Nadmiarowe pola są dopuszczalne.
Powtórzone klucze JSON i deskryptorów są błędem.

Cell.define opakowuje prywatny typ stanu. Specyfikacja zawiera id, state
i operations. State zawiera version, init, to_string i of_string.
of_string zwraca result i odtwarza niezależną wartość; zasoby procesu
nie należą do stanu. Błędny codec lub wersja zatrzymuje odtworzenie.
Opcjonalna revision komórki identyfikuje implementację; zmiana zachowania
wymaga nowej revision. System przy odtwarzaniu wymaga zgodnego katalogu.

Operacje mają nazwę string, input, output i impl przy kontrakcie:
- Transformer: state -> Json.t -> state * Json.t.
- Expander: state -> Json.t -> state * Json.t list.
- Joiner: state -> Json.t list -> state * Json.t.
- Router: state -> Json.t -> state * (string * Json.t).

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

System.create uruchamia System z RAM lub Storage.backend, także SQLite.
init_flow jest wewnętrzny i wykonuje się raz dla świeżego Systemu.
System.call przyjmuje nazwę Flow i JSON, waliduje input i zwraca JSON
zgodny z output. Opcjonalny request_id umożliwia ponowienie tego samego
wykonania; jego ponowne użycie z innym Flow lub input jest błędem.
System.close zatrzymuje nowe przyjęcia, czeka na aktywną pracę i zwalnia
magazyn oraz wykonawców. Zamknięty magazyn można ponownie otworzyć.
Właściciel Systemu jawnie wywołuje close, np. w Fun.protect.

Atomowość obejmuje pojedynczą operację: stan komórki, wynik kroku
i checkpoint zatwierdzane są razem. Tworzenie instancji z checkpointem
jest również atomowe. Handler działa na stanie odtworzonym z tekstu;
błąd walidacji, serializacji lub zapisu zachowuje poprzedni stan.
Operacje tej samej instancji są serializowane; niezależne instancje
i różne obiegi mogą pracować równolegle. SQLite utrzymuje transakcję
tylko przez krótki zapis, nigdy podczas impl.

Obieg nie ma atomowości wielokomórkowej. Zatwierdzone kroki pozostają
po błędzie późniejszego kroku. Po awarii nieukończony obieg odtwarza
się z checkpointów bez powtarzania zatwierdzonych operacji.
Zapisany wynik zakończonego request_id nie jest wykonywany ponownie.
Zewnętrzne efekty impl nie należą do transakcji i mogą się powtórzyć
po awarii przed commit. Reentrant System.call z impl jest odrzucane.

Error zawiera code, message i opcjonalny path. Błędy RPC należą
do adaptera transportowego aplikacji, poza Kom.
