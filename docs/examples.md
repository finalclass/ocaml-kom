# Przykład CLI

Główny przykład uruchamia dwa liczniki a i b jako niezależne instancje
tego samego rodzaju komórki. Każda instancja przechowuje prywatną liczbę
całkowitą, początkowo 0. Operacja add zwiększa ją o podaną wartość;
operacja read zwraca bieżącą wartość bez zmiany stanu.

Program uruchamia jeden System przez Kom_main.run i obsługuje linie
standardowego wejścia. Kom_main zarządza środowiskiem wykonawczym i zamyka
System po zakończeniu callbacku, także przy wyjątku. Przykład nie wymaga
jawnego Eio ani ręcznego System.close. Zwykłe standardowe IO wystarcza,
ponieważ CLI obsługuje polecenia kolejno:

- add a N albo add b N: dodaje liczbę całkowitą i wypisuje nową wartość.
- show a albo show b: wypisuje bieżącą wartość.
- quit albo EOF: domyka System i kończy proces kodem 0.

CLI przekazuje poprawne polecenia do zadeklarowanych obiegów przez System.call.
Nie odczytuje ani nie zmienia stanu poza operacjami komórki. Nieznane polecenie,
licznik lub błędna liczba dają komunikat na stderr bez zakończenia sesji
ani zmiany stanu. Wyniki są pojedynczymi liczbami na stdout; program nie
wypisuje promptu, więc te same wejścia działają interaktywnie i przez pipe.

Stan istnieje przez jedną sesję procesu i korzysta z RAM. Ponowne uruchomienie
zaczyna od dwóch zer. Przykład nie potrzebuje sieci, bazy danych, pluginów,
prywatnych dokumentów, widoków ani dodatkowego frameworka CLI.

examples/counter/counter_cell.ml definiuje rodzaj komórki i codec liczby całkowitej.
examples/counter/system.ml definiuje inicjalizację obu instancji oraz obiegi add/read
dla każdego licznika. examples/counter/console.ml uruchamia System, interpretuje
polecenia i wypisuje wyniki. Korzysta wyłącznie z publicznego API Kom.

make examples uruchamia CLI na pierwszym planie. Równoważne polecenie to
`dune exec examples/counter/console.exe`. Sekwencja add a 3, add a 2, show b,
show a, quit daje na stdout kolejno 3, 5, 0, 5.
