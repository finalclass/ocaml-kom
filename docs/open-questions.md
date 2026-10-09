# Granice dalszych rozszerzeń

Natywne sygnatury, checkpoint, przyjęcie, ponowienia, własność i odzyskiwanie
opisuje [publiczne API](public-api.md). Gwarancje procedur pozostają w cyrografach.

Poza tym rozszerzeniem pozostają tekstowa gramatyka Flow.parse, edytor graficzny,
parametryzacja identyfikatorów komórek Use, foreach po MessageBatch, transport
zdalnych Systemów i dynamiczny loader modułów. Implementacje statyczne muszą
być dostępne w programie odzyskującym trwały System. Nie ma gwarancji dokładnie
jednokrotnego wykonania dowolnego zewnętrznego efektu handle.
