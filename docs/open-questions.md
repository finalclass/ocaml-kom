# Granice rozszerzeń

Transakcje obejmujące wiele komórek wymagają osobnej decyzji o zakresie,
izolacji i konfliktach. Obecna gwarancja obejmuje operację i checkpoint;
nie ma blokady Systemu przez cały obieg.

Poza bieżącym zakresem pozostają: aplikacja edytora graficznego, aktualizacja
aktywnego katalogu, migracje stanu, Systemy potomne, loader kodu, zdalny
transport Systemów i atomowość efektów zewnętrznych. Katalog i AST JSON
umożliwiają odczyt oraz zapis obiegów przez przyszły edytor.

Magazyn SQLite zapisuje obecnie cały snapshot. Przy długiej historii
potrzebne będą zapis przyrostowy oraz jawna polityka kompaktowania wyników
request_id, z zachowaniem gwarancji ponowień i wznowienia.
