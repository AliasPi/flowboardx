# Flowboard X

Flowboard X ist eine offline-first Flutter-Smartboard-App für große interaktive
Displays. Der Android-Pfad ist produktionsnah integriert; dieselben Domain-,
Canvas-, Persistenz- und Exportmodule bleiben für Desktop-Plattformen nutzbar.

## Plattformstatus

| Plattform | Status | Plattformspezifische Integration |
| --- | --- | --- |
| Android 7.0+ (API 24+) | Primärziel | Offline-ML-Kit, Systemwidget, SAF-PDF-Speicherung und Quick Share/Systemfreigabe |
| Windows 10/11 | Unterstütztes Entwicklungs- und Desktopziel | Windows Ink mit lokalem OCR-Fallback sowie Google Bilder über WebView2 |
| Web | Buildziel, noch keine produktive Freigabe | PDFium-WASM bleibt erforderlich; Dateisystem-, LAN-Server- und Handschriftfunktionen sind nativ ausgelegt |
| iOS, macOS, Linux | Vorbereitete Flutter-Runner | Gemeinsame Domain-, Rendering- und UI-Schichten sind vorhanden; native Feature-Parität und Release-Qualifizierung stehen aus |

Android und Windows sind die derzeit praktisch getesteten Laufzeitpfade. Ein
erfolgreicher Build einer weiteren Plattform bedeutet nicht automatisch, dass
deren native Datei-, Share-, Widget- oder Handschriftintegration vollständig
ist.

## Enthaltene Funktionen

- latenzarmer, drucksensitiver Multi-Pointer-Ink-Pfad für mehrere gleichzeitige
  Stifte, Marker, gestrichelte Tinte und exakte Geraden; der Dash-Renderer ist
  fortschrittsgarantiert, arbeitsbegrenzt und schützt den nativen Rasterizer
  auch vor beschädigten Wiederherstellungsdaten
- robuste Trennung von Stylus, Finger-Navigation, Palm-Rejection und
  breitflächiger Stroke-Radiergeste
- begrenzte 3×3-Whiteboard-Fläche mit natürlichem Pan und Zwei-Finger-Zoom;
  außerhalb des beschreibbaren Bereichs wird die Fläche abgedunkelt und beim
  Zoomen erscheint ein verschiebbarer, automatisch ausblendender Navigator mit
  rotem Sichtfenster und direkter Navigation
- dreistufiges, verschiebbares Radialmenü nach `mockup.jpg`, inklusive
  animiertem Zentrum, abgerundeten Segmenten, kompakten parent-zentrierten
  Subring-Fächern, gebündelten Farb-/Stifttypfeldern, einem großen Regler mit
  realer 1–32-px-Dickenvisualisierung, kreisförmigem Hue-/Sättigungs-Farbwähler
  und eindeutigen Aktivfarben; nicht verfügbare Undo-/Redo-Aktionen sind
  sichtbar deaktiviert und nicht bedienbar
- bis zu 100 Seiten, Undo/Redo, Rechteck-/Lassoauswahl, semantische
  Buchstaben-/Wort-/Zeilen-/Skizzenauswahl, „Alles auswählen“, Verschieben,
  Skalieren, dauerhaftes Gruppieren bis zum expliziten Entgruppieren,
  Duplizieren, Kopieren, Ausschneiden und Einfügen
- eine gemeinsame Z-Reihenfolge für Tinte und Objekte mit „Eine Ebene nach
  vorn/hinten“ sowie „Ganz nach vorn/hinten“
- Formen, Bilder, schlüssellose Google-Bildersuche mit SafeSearch und robuster
  Stift-/Touch-Auswahl ganzer Trefferkarten; importierte Bilder behalten ihr
  intrinsisches Seitenverhältnis, werden vor Persistenz und Rendering anhand
  ihrer Header geprüft und sind auf 16.384 px je Achse beziehungsweise 32
  MiPixel begrenzt; freie Stiftfarbe mit zehn
  persistenten zuletzt verwendeten Farben; Tabellen werden in einem direkten
  Zeilen-/Spalten-Dialog konfiguriert, PDFs über echte Seitenvorschauen als
  ganzes Dokument, einzelne oder frei gewählte Seiten importiert und
  Reveal-Abdeckungen an allen vier Kanten direkt skaliert
- objektlokale Ink-Layer für Bild-, PDF- und Tabellenannotationen; beim
  Verschieben und Skalieren folgt die Tinte dem Objekt, während Eingabe,
  Vorschau und Commit auch auf nicht-quadratischen Tabellen rund und
  maßstäblich bleiben
- vier direkt nutzbare Vorlagen: überlappende Kreise, Mindmap,
  Grundschullinien und Venn-Diagramm; eigene Seiten lassen sich zusätzlich als
  geräteweite Nutzervorlagen speichern und über eine Vorschau-Bibliothek öffnen
- atomisches Auto-Save mit maximal zwei Sekunden Checkpoint-Latenz, Journal,
  Backup, Schema-Migration, Crash-Recovery und rotiertem Fehlerprotokoll
- seitenweise, speicherbegrenzte PDF-Erzeugung sowie lokaler, tokenisierter
  HTTP-Download per WLAN/Ethernet und QR-Code; auf Android zusätzlich Teilen
  über Quick Share beziehungsweise das System-Share-Sheet
- lokale Handschrifterkennung ohne Laufzeit-Download: unter Android mit dem im
  APK gebündelten lateinischen ML-Kit-Modell, unter Windows primär mit Windows
  Ink und bei nicht installiertem Handschrift-Feature mit lokaler Windows OCR
- erkannter Text erhält automatisch seine gemessene Inhaltsgröße, skaliert
  Schrift und Rahmen gemeinsam und lässt sich anschließend direkt auf der
  Fläche mit dem Stift korrigieren: über ein Wort schreiben ersetzt es,
  waagerechtes Durchstreichen löscht es und Schreiben rechts vom letzten Wort
  hängt neuen erkannten Text an
- Android-Systemwidget mit „Neues Whiteboard“, größenabhängiger Liste und
  Öffnen zuletzt verwendeter Dokumente
- responsive Dokumentbibliothek mit echten Inhaltsvorschauen, Recovery-Status,
  Mehrfachauswahl, Batch-Löschen und Umbenennen; persistente Ordner lassen sich
  öffnen, umbenennen und sicher entfernen. Dokumente lassen sich mit Maus oder
  Stift direkt und per Touch-Long-Press in Ordner ziehen; eine angeheftete,
  horizontal scrollbare Zielleiste bleibt auch in langen Listen erreichbar.
  Einzelne Dokumente, Auswahlen oder ganze Ordner können als vollständiges ZIP
  inklusive Assets lokal gespeichert, über die Systemfreigabe versendet oder
  per WLAN/QR heruntergeladen werden

## Voraussetzungen

- Flutter 3.38.7 oder kompatibel, Dart 3.10.7+
- Android SDK 36 und JDK 17 (Android Studio JBR ist geeignet)
- Android-Gerät ab API 24
- für Windows-Builds: Visual Studio 2022 mit „Desktopentwicklung mit C++“ und
  dem Windows SDK
- Für die schlüssellose Google-Bildersuche unter Windows: Microsoft Edge
  WebView2 Runtime (unter aktuellen Windows-10-/11-Installationen üblicherweise
  bereits vorhanden)

## Schnellstart

```powershell
git clone https://github.com/AliasPi/flowboardx.git
Set-Location flowboardx
flutter pub get
flutter doctor -v
flutter devices
flutter run -d <android-device-id>
```

Für Windows kann die letzte Zeile durch `flutter run -d windows` ersetzt
werden. `flutter run` verwendet einen Debug-Build; für ein Smartboard sollte
die Eingabelatenz zusätzlich mit einem Release- oder Profile-Build auf dem
Zielgerät beurteilt werden.

Ein schlanker Android-Arm64-Debug-Build:

```powershell
flutter build apk --debug --target-platform android-arm64
```

Das erzeugte APK liegt unter
`build/app/outputs/flutter-apk/app-debug.apk`.

## Android-Release und getrennte APKs

Der direkte Flutter-Aufruf erzeugt je Android-ABI eine eigene, kleinere APK:

```powershell
flutter build apk --split-per-abi
```

Für auszuliefernde native Builds ist der Repository-Wrapper vorzuziehen. Er
führt denselben Release-Build aus, entfernt davor aber die ausschließlich für
Web benötigten PDFium-WASM-Dateien kontrolliert und stellt sie danach wieder
her:

```powershell
dart run tool/build_native_release.dart apk --split-per-abi
```

Die Ergebnisse liegen unter `build/app/outputs/flutter-apk/`:

```text
app-armeabi-v7a-release.apk
app-arm64-v8a-release.apk
app-x86_64-release.apk
```

Für aktuelle 64-Bit-Android-Smartboards ist üblicherweise
`app-arm64-v8a-release.apk` passend. Die ABI des Zielgeräts sollte vor der
Verteilung geprüft werden, zum Beispiel mit
`adb shell getprop ro.product.cpu.abilist`. Ohne Release-Key sind diese
Artefakte nicht für eine Store-Veröffentlichung signiert.

## Release-Signierung

Debug-Keys werden ausdrücklich nicht für Release verwendet. Für einen
signierten Store-Build wird eine nicht eingecheckte `android/key.properties`
angelegt:

```properties
storeFile=C:/secure/flowboard-upload.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

Anschließend:

```powershell
dart run tool/build_native_release.dart appbundle
```

Der Release-Wrapper führt die offizielle pdfrx-Bereinigung aus, entfernt den
nur für Web benötigten PDFium-WASM-Block (rund 4 MB) aus dem nativen Build und
stellt ihn in einem `finally`-Schritt wieder her. Dadurch bleiben anschließende
Web- und Debug-Builds funktionsfähig. Er invalidiert außerdem Flutters
inkrementellen Assetcache, entfernt exakt bekannte alte pdfrx-Webmodule aus
Staging und Zielausgabe und bricht ab, falls ein natives Ergebnis dennoch ein
solches Modul enthält. Beispiele:

```powershell
dart run tool/build_native_release.dart apk --target-platform android-arm64
dart run tool/build_native_release.dart apk --split-per-abi
dart run tool/build_native_release.dart appbundle
dart run tool/build_native_release.dart windows
```

Web-Releases werden weiterhin regulär mit `flutter build web --release`
gebaut, weil sie das PDFium-WASM-Modul zur PDF-Darstellung benötigen.

Die `applicationId` lautet derzeit `de.flowboardx.flowboard_x` und muss nach
der ersten Store-Veröffentlichung stabil bleiben. Schlüssel und Passwörter
gehören in einen Secret Store beziehungsweise in CI-Secrets.

## Schlüssellose Web-Bildsuche

Gerätebilder und die Google-Bilder-Live-Suche funktionieren ohne
Konfiguration oder API-Key. Auf Android und Windows zeigt ein eingebetteter,
JavaScript-fähiger System-WebView die echte Google-Bilder-Seite mit aktivem
SafeSearch. Der Nutzer tippt dort ein Ergebnis an und bestätigt es anschließend
explizit in Flowboard X. Damit bleibt die Suche auch nutzbar, wenn Google einem
reinen HTTP-Client nur eine JavaScript-Seite ausliefert. Ein gekapselter
HTML-Parser bleibt als defensiver Fallback und für Regressionstests erhalten;
Consent- und Verifikationsseiten werden ausdrücklich erkannt. Google stellt
keine stabile, offiziell unterstützte schlüssellose JSON-Bildersuche bereit.
Gemeldete WebView-URLs werden wie untrusted input behandelt. Downloads sind auf
öffentliche HTTPS-Adressen und 25 MB beschränkt, folgen höchstens fünf geprüften
Weiterleitungen und werden anhand ihrer Dateisignatur validiert. Die Lizenz des
gewählten Bildes muss auf der Quellseite geprüft und beim Export eingehalten
werden.

Im Browser fehlen APIs für DNS-Prüfung und IP-Pinning. Der Web-Build zeigt
deshalb einen HTML-Fallback, lehnt aber nicht sicher verifizierbare
Cross-Origin-Bilddownloads bewusst ab. Android, Windows, iOS, macOS und der
Linux-HTML-Fallback verwenden dagegen den abgesicherten nativen Downloadpfad.

## Bedienung auf dem Smartboard

- Stylus: schreiben; invertierter Stylus: radieren
- breite Hand-/Faustkante: kompletter getroffener Stroke wird entfernt
- ein Finger auf leerem Board: Fläche verschieben
- zwei Finger ohne aktive Auswahl: pan und zoomen; dabei erscheint kurz der
  verschiebbare Navigator, dessen roter Rahmen auch direkt gezogen werden kann
- Auswahlmodus: tippen wechselt nachvollziehbar zwischen Stroke, Buchstabe,
  Wort, Zeile und Skizze; ziehen erzeugt Rechteck oder Lasso, „Alles auswählen“
  erfasst den vollständigen Seiteninhalt
- Auswahl verschieben oder skalieren: Inhalt und objektgebundene Annotationen
  folgen der Geste live; der Undo-Schritt wird erst beim Loslassen erzeugt
- Auswahl anordnen: eine Ebene oder vollständig nach vorn beziehungsweise
  hinten; Tinte und Objekte teilen dabei dieselbe stabile Reihenfolge
- Geometrie aufziehen: Rechteck, Kreis, Ellipse oder Dreieck werden bereits
  während der Geste in ihren tatsächlichen Proportionen dargestellt
- Reveal-Abdeckung: die blaue Freilegungsgrenze direkt ziehen; vier getrennte,
  mittig platzierte Kantengriffe ändern die Größe ohne doppelte Seitengriffe.
  Beides funktioniert ohne Slider und ist gegen Mehrfachgesten geschützt
- Long-Press auf leerer Fläche: alles leeren, Handschrift leeren, einfügen und
  – nach Kopieren/Ausschneiden – Zwischenablage einsetzen
- Zentrum des Radialmenüs: öffnen/schließen; Drag im Zentrum: frei verschieben;
  „Menüposition zurücksetzen“ in der Kopfleiste zentriert es im Sichtfeld
- bereits aktive Hauptfunktion erneut wählen: deren Außenringe einklappen
- Stift: Farben bilden Ring 2; der große Dickenbogen und die kompakt gebündelten
  Typen Normal, Marker, Gestrichelt und Gerade Linie bilden Ring 3
- Vorlagen: Ring 2 enthält die vier eingebauten Vorlagen und „Eigene Vorlagen“;
  der Eintrag öffnet eine Bibliothek mit Vorschau, Auswahl und Löschen
- das Vorlagensymbol in der Kopfleiste speichert die aktuelle Seite als eigene
  Vorlage
- vorherige/nächste/neue Seite: führt die Aktion aus und öffnet das zyklische
  Miniatur-Drehrad; Kreisbewegung oder eine Fünf-Finger-Kreisgeste wechselt
  weiter, einschließlich des Übergangs letzte ↔ erste Seite
- Seitensymbol in der Kopfleiste: breites Seitenfach mit echten Miniaturen;
  horizontal wischen oder scrollen, um weitere Seiten direkt anzuwählen
- Pfeil am rechten Ende der Kopfleiste: Leiste auf Zurück, Logo und
  Ausklapppfeil reduzieren beziehungsweise wieder vollständig anzeigen
- Info-Symbol in der Kopfleiste: kompakte Hilfe zu Stift, Navigation,
  Radialmenü, Auswahl, Text, Ebenen, Speicherung und Teilen
- Textobjekt auswählen und „Text mit Stift korrigieren“ wählen: direkt über ein
  Wort schreiben ersetzt es nach lokaler Erkennung; eine absichtliche
  waagerechte Durchstreichgeste löscht das getroffene Wort; Schreiben rechts
  hinter dem letzten Wort hängt erkannten Text an

Die Palm-Logik nutzt Druck nie allein, weil viele Android-Touchcontroller für
normale Finger dauerhaft `pressure=1` melden. Die Eraser-Nachprüfung erfolgt
gegen die tatsächlichen Liniensegmente, nicht nur gegen große Bounding-Boxen.

## Persistenz und Recovery

Das App-Datenverzeichnis enthält pro Dokument:

```text
documents/<document-id>/
  document.flowboard.json
  document.flowboard.backup.json
  document.flowboard.journal.json
  assets/
```

Die optionale Bibliotheksorganisation liegt getrennt in
`library.organization.json` mit atomarem Backup. Deshalb erfordern Ordner-
Umbenennungen kein Verschieben der eigentlichen Dokumentdateien. Bestehende
Installationen ohne diesen Index bleiben kompatibel; ihre Dokumente erscheinen
unter „Nicht abgelegt“. Beim Entfernen eines Ordners werden seine Dokumente
nicht gelöscht, sondern dorthin zurückgelegt.

Das aktuelle Format ist Schema 4. Es speichert Seiten, Viewports, Ink,
Gruppierungen, Objekte, Objektannotationen, Templates, PDF-Seitenzustände,
Assets, Presets, Auswahlzustände, Metadaten und Menüposition. Assets werden mit
SHA-256 und relativen, gegen Path Traversal geprüften Pfaden geführt. Saves
werden außerhalb des Rendering-Pfads serialisiert, zunächst in eine temporäre
Datei geschrieben, verifiziert und atomar befördert. Beim Start werden Primary,
Journal und Backup validiert und die höchste konsistente Revision gewählt.
Gleichlautende Dokument-, Vorlagen-, Export- und Quelldateinamen sind erlaubt:
interne UUIDs beziehungsweise eindeutige Exportnamen verhindern Kollisionen.
Nicht abgefangene Flutter- und Isolate-Fehler werden in
`FlowboardX/flowboard_crash.log` protokolliert; ab 2 MB wird die vorherige Datei
rotiert, ohne Auto-Save oder den Startpfad zu blockieren.

Nutzervorlagen liegen anwendungsweit in einem atomar geschriebenen, geprüften
Format mit Backup. Bilder und PDFs werden beim Speichern per Dateistream in ein
eigenes Vorlagen-Assetverzeichnis kopiert und mit Länge sowie SHA-256 erfasst;
große Dateien landen weder als Base64 in JSON noch im UI-Speicher. Beim
Einfügen entstehen kollisionsfreie Dokument-Assets und neue Referenzen, sodass
auch objektgebundene Annotationen auf Bildern und PDFs erhalten bleiben.
Gelöschte oder nach einem Abbruch verwaiste Vorlagen-Assets werden erst
bereinigt, wenn weder Hauptdatei noch Recovery-Backup darauf verweisen.

## PDF-Export und lokale Freigabe

Der Export rastert immer nur eine Seite und deren Assets, komprimiert RGB-Daten
in einem Helper-Isolate und schreibt das PDF inkrementell. Auf Android wird die
fertige temporäre Datei über `ACTION_CREATE_DOCUMENT` und den
`ContentResolver` in den vom Benutzer gewählten SAF-Speicherort gestreamt; es
sind dafür weder breite Storage-Permissions noch ein FileProvider erforderlich.

Beim lokalen Teilen bindet ein kleiner Dart-HTTP-Server an das lokale IPv4-Netz.
Er kann sowohl ein exportiertes PDF als auch das ZIP einer Dokumentauswahl oder
eines ganzen Ordners bereitstellen. Der QR-Code enthält eine kryptografisch
zufällige, nicht erratbare URL. Der Server akzeptiert nur `GET`/`HEAD`, bietet
kein Directory Listing, setzt `no-store` und endet nach 15 Minuten Inaktivität
oder explizitem Stoppen. Sender und Empfänger müssen im selben WLAN oder
Ethernet-LAN sein; eine Cloud ist nicht erforderlich. Eine Host-Firewall kann
den Zugriff blockieren und muss eingehende Verbindungen für die App im privaten
Netz gegebenenfalls erlauben.

„Quick Share“ erzeugt auf Android eine eindeutig benannte temporäre PDF und
übergibt sie über einen lesegeschützten `FileProvider`-URI an `ACTION_SEND`.
Damit stehen Quick Share und andere installierte Ziele im System-Share-Sheet
bereit; die temporäre Datei wird nach der Übergabe wieder bereinigt. ZIP-Bundles
werden plattformübergreifend über `share_plus` an die jeweils verfügbare
Systemfreigabe übergeben und können alternativ über einen Speicherdialog lokal
gesichert werden.

## Android-Widget

`FlowboardWidgetProvider`, Layouts, Icons und Widget-Metadaten sind vollständig
unter `android/app/src/main` enthalten und im Manifest registriert. Das Widget
passt die Zahl der Dokumentzeilen an seine aktuelle Höhe an. Widget-Intents
werden kalt und warm über einen Method Channel seriell abgearbeitet, sodass
schnelle Aktionen nicht verloren gehen. Die Flutter-App aktualisiert die Liste
nach Editor-Rückkehr, Umbenennen und Löschen.

## Lokale Handschrifterkennung

Die App enthält eine unabhängige `HandwritingRecognitionService`-Grenze und eine
echte Auswahlaktion „Handschrift in Text umwandeln“. Android implementiert den
Channel `de.flowboardx/handwriting_recognition`. Android rastert die ausgewählte
Vektortinte außerhalb des UI-Threads und erkennt sie mit
`com.google.mlkit:text-recognition:16.0.1`. Das lateinische Modell ist statisch
im APK enthalten und sofort offline verfügbar; die Play-Services-Variante mit
nachgeladenem Modell wird nicht verwendet. Windows übergibt die Vektorstriche
zuerst an `Windows.UI.Input.Inking.InkRecognizerContainer`. Fehlt dieses
optionale Windows-Handschrift-Feature oder liefert es kein Ergebnis, wird die
Tinte speicherbegrenzt in ein lokales BGRA8-`SoftwareBitmap` gerastert und durch
`Windows.Media.Ocr.OcrEngine` erkannt. Das Raster ist auf 2048 Pixel Kantenlänge
und ein festes Operationsbudget begrenzt; es blockiert nicht den Flutter-Thread.
`isAvailable` ist wahr, sobald Ink oder eine lokal installierte OCR-Sprache
verfügbar ist. Auch dieser Fallback installiert oder lädt nichts nach. Web,
Linux und macOS haben derzeit keinen nativen Adapter, beeinträchtigen aber
Schreib-, Speicher- und Exportpfade nicht.

Nach einer Änderung am nativen Windows-Runner muss ein laufendes
`flutter run -d windows` vollständig beendet und neu gestartet werden. Hot
Reload beziehungsweise Hot Restart registriert den C++-Method-Channel nicht
neu.

Der OCR-Aufruf wurde auch in einem ungepackten Win32-Prozess auf dem
Entwicklungsgerät erfolgreich bis einschließlich `RecognizeAsync` geprüft.
Microsoft dokumentiert `Windows.Media.Ocr` für Desktop-Anwendungen offiziell
jedoch nur mit Paketidentität als unterstützt. Ein produktiver Windows-Release
sollte deshalb als MSIX ausgeliefert werden; der ungepackte `flutter run`-Pfad
bleibt defensiv abgefangen, ist aber keine plattformweite Microsoft-Garantie.

## Architekturentscheidungen

```text
lib/src/
  app/                 App-Shell, Theme, Branding
  domain/              immutable Modelle, Commands, Codec, Gruppierung
  data/                Repository, atomare Dateien, Auto-Save/Recovery
  features/
    board/             Input Policy, Sessions, Viewport, Painter, Objekte
    editor/            Feature-Controller und UI-Orchestrierung
    radial_menu/       Geometrie, State, Painter, mehrstufige Interaktion
    selection/         Hit-Testing und semantische Auswahlkandidaten
    templates/         strukturierte Vorlagenerzeugung
    assets/            sichere Imports und optionale Bildersuche
    pages/             echte Thumbnail-Rasterung
    export_share/      PDF-Writer, LAN-Server, QR-UI und Quick Share
    library/           Dokumentübersicht, Ordner, ZIP- und Systemfreigabe
    handwriting/       Recognition-Port und Android-ML-Kit-Adapter
  platform/            kleine, typisierte Android-Channels
```

Wesentliche Entscheidungen:

- Feature-lokale `ChangeNotifier` plus immutable Dokumente und Commands statt
  globaler UI-State: Live-Pointer erzeugen keine globalen Rebuilds.
- Jeder aktive Pointer besitzt eine isolierte Session. Live-Ink wird in kleine,
  gecachte Segmente zerlegt; committed Ink, Objekte und Preview sind getrennte
  Repaint-Layer.
- Dokument-Commands tragen alle inhaltlichen Undo/Redo-Schritte. Seitenwechsel
  und Viewport bleiben persistent, verbrauchen aber keinen Undo-Eintrag; auch
  die Position des Radialmenüs wird durch Undo/Redo nicht verändert.
- Tinte und Board-Objekte werden anhand einer gemeinsamen, stabilen
  Z-Reihenfolge gerendert, getroffen, exportiert und in Miniaturen dargestellt.
- Objektannotationen liegen in normalisierten Objektkoordinaten und benötigen
  beim Transformieren keine Punkt-für-Punkt-Umschreibung. Gebündelte PDFs
  besitzen zusätzlich eine getrennte Ink-Schicht pro PDF-Quellseite.
- Gruppierung ist eine deterministische, lokal begrenzte Heuristik aus Raum,
  Zeit, Baseline und Bounds; sie benötigt kein Netzwerk und keine KI.
- Abhängigkeiten bleiben bewusst klein: `path_provider`, `path`, `uuid`,
  `file_picker`, `pdfrx`, `http`, `crypto` und `qr_flutter`.

`url_launcher_android` ist auf 6.3.24 fixiert, weil neuere Kotlin-DSL-Releases
mit der hier verwendeten Flutter-3.38/Gradle-8.14-Toolchain einen reproduzierbaren
Accessor-Cachefehler auslösen. Die öffentliche API bleibt kompatibel.

## Qualitätssicherung

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
dart run tool/build_native_release.dart apk --split-per-abi
```

Die Tests decken unter anderem Command-History, untracked Navigation,
Serialisierung/Migration, Auto-Save-Maximallatenz, Crash-Recovery, simultane
Pointer, Palm-Policy, Spatial Index, Gruppierungsheuristik, Auswahl, Vorlagen,
PDF-Struktur, atomaren Export, tokenisierten HTTP-Download, QR-Share-State,
Dokumentbibliothek, Nutzervorlagen, kompakte Radialmenü-Fächer, gemeinsame
Z-Reihenfolge, Widget-, SAF-, Quick-Share- und Handschrift-Bridge ab.
