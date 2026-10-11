# Granice rozszerzeń

Transakcje obejmują jawne fragmenty obiegu i używają optymistycznej kontroli
konfliktów na poziomie instancji. Nie blokują całego Systemu podczas handlera.

Poza bieżącym zakresem pozostają: aplikacja edytora graficznego, aktualizacja
aktywnego katalogu, migracje stanu, Systemy potomne, loader kodu, zdalny
transport Systemów i atomowość efektów zewnętrznych. Katalog i AST JSON
umożliwiają odczyt oraz zapis obiegów przez przyszły edytor.

Poza zakresem pozostają reduce/rereduce, przebudowa indeksów podczas pracy
Systemu oraz polityka kompaktowania wyników request_id. Wspólny dostęp do
danych innych komórek nie należy do API Kom i nie jest planowany.
