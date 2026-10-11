# Runtime i pluginy

Runtime uruchamia aplikacje w jednym procesie. Osadzony program tworzy runtime,
instaluje natywną definicję aplikacji, wywołuje obieg i zamyka runtime. Host `kom`
działa do `stop` lub sygnału, obsługuje HTTP i lokalne polecenia administracyjne.
Kod aplikacji nie jest linkowany do hosta; Todo jest artefaktem `.cmxs`.

## Definicja aplikacji

`Kom_runtime.App.define` przyjmuje `id`, definicję `Kom.System`, opcjonalny
handler HTTP oraz opcjonalne `cleanup : unit -> unit`. ID jest niepustą nazwą
z liter ASCII, cyfr, `_`, `-` i `.`, inną niż `.` i `..`.
Handler otrzymuje własny System, uchwyt plików aplikacji i prefiks montowania.
Request/response to metoda, target, nagłówki i body, bez połączenia sieciowego.
Handler zwraca opcjonalną odpowiedź; None przekazuje żądanie do magazynu plików.
HTML i formularze pozostają w aplikacji; JSON-RPC i transmisja należą do hosta.
Cleanup zwalnia zasoby i czyści globalne cache starego pluginu po zakończeniu
jego pracy. Stan komórek pozostaje mały, z codec, a dokumenty w prywatnym KV.

`Kom_runtime.Plugin.register` rejestruje dokładnie jedną aplikację podczas
inicjalizacji pluginu. Loader używa `Dynlink.loadfile_private` i nowej kopii
artefaktu przy każdym ładowaniu. Plugin jest kompilowany z tym samym OCaml
oraz interfejsami bibliotek hosta. Nie zawiera własnej kopii Kom ani runtime.
Natywne pluginy są zaufanym kodem: wyjątki operacji są izolowane przez Kom,
ale segfault, exit i inne błędy procesu mogą zakończyć hosta. Kod załadowanego
pluginu nie jest odładowywany z pamięci; `kom restart` uruchamia nowy proces.

## Przełączenie

Runtime przyjmuje nowy artefakt i jego definicję przed zatrzymaniem starej
aplikacji. Wstrzymuje przyjęcia tej aplikacji, czeka na istniejące żądania oraz
przyjęte obiegi, zapisuje oczekującą wersję w rejestrze i wywołuje
`Kom.System.replace`. Nowe wywołania oczekują na wznowienie przyjęć; inne
aplikacje i HTTP pozostają aktywne. Bufor jest w RAM, nie zapewnia dostarczenia
po awarii procesu. Limit jednoczesnych połączeń HTTP ogranicza ten bufor.

Replace sprawdza codec i przebudowuje widoki w workerze Eio, aby kod
aplikacji podczas przygotowania nie blokował schedulera HTTP.
Sprawdza wszystkie zapisane stany nowymi codec przy zachowaniu
state.version. Może zmienić revision komórki, operacje i obiegi. Nie usuwa
rodzajów mających istniejące instancje i nie migruje state.version.
Nieukończone wykonania blokują zmianę katalogu; aktywna praca jest najpierw
kończona. Zakończone request_id zachowują historyczne wyniki.
Widoki używają istniejącego mechanizmu eager/version. Zatwierdzenie stanów,
katalogu i metadanych widoków jest atomowe. Błąd sprawdzenia lub zapisu
pozostawia starą definicję i wznawia jej przyjęcia.

Po commit runtime publikuje nowy handler i kończy zmianę rejestru. Dopiero
potem zwalnia stary plugin przez cleanup i usuwa nieaktywne artefakty z dysku.
Błąd cleanup jest raportowany, ale nie cofa już zatwierdzonego przełączenia.
Przy starcie wpis z oczekującą wersją jest rozstrzygany według znacznika
artefaktu zapisanego atomowo z katalogiem w backendzie: nowa wersja po commit, stara po przerwaniu przed commit.
Niedokończony wpis nie może spowodować utraty poprzedniego artefaktu.
Pierwsza instalacja przerwana przed zapisem znacznika jest usuwana z rejestru.

## Pliki

`Kom_runtime.Files` udostępnia read/write/delete/list pod względną ścieżką
wewnątrz aplikacji. Nie ujawnia root ani sposobu zapisu. Ścieżki absolutne,
puste segmenty, `.`/`..` i symlinki są odrzucane. Aplikacje mają osobne katalogi;
nie mogą przez ten uchwyt odczytywać plików innej aplikacji.
Implementacja używa lokalnego filesystemu; write zastępuje plik atomowo przez
rename, a operacje blokujące wykonuje poza schedulerem Eio.
Administracyjne zapisy plików nie są operacjami komórek i nie należą do
transakcji obiegów. Cell nie dostaje wspólnego uchwytu plików ani bazy danych.

GET pod `/apps/<id>/files/<path>` odczytuje plik. Po braku odpowiedzi handlera
GET odczytuje również statyczny zasób pod względną ścieżką (root → index.html).
MIME wynika z rozszerzenia, a odpowiedź zawiera nosniff. Żądania aplikacji są
montowane pod `/apps/<id>/`; przy jednej aplikacji dostępne są też pod `/`.
JSON-RPC jest pod `/apps/<id>/rpc`, a przy jednej aplikacji również `/rpc`.

## Polecenia

`kom start --directory DIR --port PORT` uruchamia host w tle, a
`kom start --foreground` na pierwszym planie. Konfiguracja port/workers,
rejestr pluginów, baza i pliki są w DIR. Jeden host posiada dany katalog.
Sterowanie używa lokalnego socketu Unix dostępnego tylko właścicielowi.
Publiczne HTTP nie udostępnia ładowania natywnego kodu.

- `kom add plugin FILE`: kopiuje, ładuje i instaluje/przełącza aplikację.
- `kom remove APP`: kończy przyjęcia i pracę, zwalnia aplikację i usuwa ją
  z rejestru; trwałe dane i pliki pozostają do ponownej instalacji.
- `kom apps`: pokazuje zainstalowane aplikacje i katalogi kontraktów.
- `kom call APP FLOW JSON`: zleca obieg i wypisuje wynik.
- `kom put APP PATH FILE`: umieszcza lokalny plik w storage aplikacji.
- `kom files APP`: listuje pliki; `kom delete APP PATH` usuwa plik.
- `kom stop`: czeka na pracę i kończy proces.
- `kom restart`: stop/start z zapisanym portem i pluginami, bez starych cmxs.

Opcja `--directory` wybiera host dla wszystkich poleceń. Domyślnie jest to
`./kom-data`. `make todo` buduje host i plugin, instaluje Todo, kopiuje jego
zasoby i uruchamia przykład. Osobny przykład konsolowy instaluje tę samą
aplikację bez Dynlink i kończy runtime po wywołaniu obiegu.
