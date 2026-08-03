# Flowboard X

Flowboard X ist eine offline-first Flutter-Smartboard-App für große interaktive
Displays. Der Android-Pfad ist produktionsnah integriert; dieselben Domain-,
Canvas-, Persistenz- und Exportmodule bleiben für Desktop-Plattformen nutzbar.

## Plattformstatus

| Plattform | Status | Plattformspezifische Integration |
| --- | --- | --- |
| Android 7.0+ (API 24+) | Primärziel | Eingebettetes PP-OCRv6-small/ONNX mit Offline-Fallback, Systemwidget, SAF-PDF-Speicherung und Quick Share/Systemfreigabe |
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
- robuste Trennung von Stylus, Finger-Navigation, optionalem Finger-Schreiben,
  Palm-Rejection sowie partiellem Stift-/Faust-Radierer. Android übergibt die
  tatsächliche, zur Flutter-View ausgerichtete Kontaktellipse aus Mittelpunkt,
  Haupt-/Nebenachse und Orientierung. Werkzeug- und Faust-Radierer werden
  automatisch in Bildschirmkoordinaten dimensioniert; sichtbarer Cursor und
  tatsächlicher Löschpfad stimmen bei jedem Zoom überein
- umschaltbarer Ein-/Zwei-Personen-Modus: Im geteilten Betrieb besitzt jede
  Hälfte ein eigenes Radialmenü, einen eigenen Stiftzustand sowie einen
  eigenen Eingabebereich, Viewport und aktiven Seitenzustand. Beide Hälften
  bearbeiten dasselbe unveränderlich modellierte Dokument, ohne Kamera- oder
  Seitennavigation auf die andere Hälfte zu übertragen. Pointer bleiben ihrer
  Hälfte zugeordnet; auch Pan, Zoom, Navigator und wiederhergestellte Viewports
  werden an der stabilen Welt-Mittellinie geklemmt, sodass keine Kamera in den
  Bereich der anderen Person gelangt. Beide Personen können gleichzeitig
  schreiben und besitzen getrennte Undo-/Redo-Zweige. Neue Seiten sind sofort
  Teil des gemeinsamen Dokuments, aber zunächst nur für den Ersteller aktiv;
  beim Umschalten werden weder Inhalt noch Z-Reihenfolge verändert
- begrenzte 3×3-Whiteboard-Fläche mit natürlichem Pan und Zwei-Finger-Zoom;
  außerhalb des beschreibbaren Bereichs wird die Fläche abgedunkelt und beim
  Zoomen erscheint ein verschiebbarer, automatisch ausblendender Navigator mit
  rotem Sichtfenster und direkter Navigation
- dreistufiges, verschiebbares Radialmenü nach `mockup.jpg`, inklusive
  animiertem Zentrum, abgerundeten Segmenten, kompakten parent-zentrierten
  Subring-Fächern, gebündelten Farb-/Stifttypfeldern, einem großen Regler mit
  realer 1–32-px-Dickenvisualisierung, kreisförmigem Hue-/Sättigungs-Farbwähler
  und eindeutigen Aktivfarben; nicht verfügbare Undo-/Redo-Aktionen sind
  sichtbar deaktiviert und nicht bedienbar. Die zyklische Seitenauswahl lässt
  sich auch bei geschlossenem Menü mit fünf Fingern drehen, rastet haptisch in
  18°-Schritten ein und zeigt bis zum Loslassen die echte Zielseiten-Miniatur
- bis zu 100 Seiten, Undo/Redo, Rechteck-/Lassoauswahl, semantische
  Buchstaben-/Wort-/Zeilen-/Skizzenauswahl, „Alles auswählen“, Verschieben,
  freies sowie achsengebundenes Skalieren, freie Rotation, Winkel-Presets,
  horizontales Spiegeln, dauerhaftes Gruppieren bis zum expliziten
  Entgruppieren, Duplizieren, Kopieren, Ausschneiden und Einfügen
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
  Reveal-Abdeckungen an allen vier Kanten direkt skaliert. Abdeckungen erhalten
  dieselben Zwischenablage-, Lösch- und Ebenenaktionen wie andere Objekte und
  werden beim Erstellen standardmäßig ganz vorn eingeordnet
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
- lokale Handschrifterkennung ohne Laufzeit-Download: unter Android primär mit
  dem im APK gebündelten, handschriftfähigen PP-OCRv6-small-Modell über ONNX
  Runtime und mit gebündeltem ML-Kit-Latin-Modell als defensivem Fallback;
  unter Windows primär mit Windows Ink und bei nicht installiertem
  Handschrift-Feature mit lokaler Windows OCR
- erkannter Text erhält automatisch eine exakt vermessene, gepolsterte
  Inhaltsbox; Messung, Canvas-Darstellung, Export und Inline-Caret verwenden
  dieselben theme- und zoomunabhängigen Schriftmetriken. Schrift und Rahmen
  skalieren gemeinsam. Direktes Schreiben über ein Wort ersetzt es,
  waagerechtes Durchstreichen löscht es und Schreiben rechts vom letzten Wort
  hängt neuen erkannten Text an und erweitert den Rahmen anhand der realen
  Glyphbreite. Bereits gespeicherte Textfelder werden beim ersten Öffnen
  einmalig, verlustfrei und ohne Undo-Eintrag auf die neuen Maße migriert
- driftfreier Countdown-Timer in der Kopfleiste mit Start, Pause, Zurücksetzen
  und einem bis zur Bestätigung wiederholten akustischen Alarm; Kopfleiste und
  große, frei verschiebbare sowie skalierbare Anzeige verwenden denselben
  atomaren Live-Zustand, während die übrige Schreibfläche bedienbar bleibt
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

Ein Release-Build setzt eine gültige `android/key.properties` voraus. Dadurch
kann der Build nicht mehr versehentlich formal erzeugte, aber von Android als
ungültig abgelehnte unsignierte APKs ausliefern. Für auszuliefernde native
Builds ist der Repository-Wrapper der verbindliche Buildpfad:

```powershell
dart run tool/build_native_release.dart apk --split-per-abi
```

Er führt intern `flutter build apk --split-per-abi` aus, entfernt davor aber
kontrolliert die ausschließlich für Web benötigten PDFium-WASM-Dateien und
einen von Flutter 3.38 gegebenenfalls zurückgelassenen
`integration_test`-Registrant. Anschließend stellt er beide Entwicklungsstände
auch bei einem fehlgeschlagenen Build wieder her. Produktions-Plugins bleiben
im Release-Registrant erhalten.

Die Ergebnisse liegen unter `build/app/outputs/flutter-apk/`:

```text
app-armeabi-v7a-release.apk
app-arm64-v8a-release.apk
app-x86_64-release.apk
```

Für aktuelle 64-Bit-Android-Smartboards ist üblicherweise
`app-arm64-v8a-release.apk` passend. Die ABI des Zielgeräts sollte vor der
Verteilung geprüft werden, zum Beispiel mit
`adb shell getprop ro.product.cpu.abilist`.

Android akzeptiert ein Update nur, wenn die bereits installierte App mit
demselben Schlüssel signiert wurde. Wurde zuvor ein Debug-Build, eine
unsignierte Vorabversion oder ein Build mit einem anderen Release-Schlüssel
installiert, müssen wichtige Dokumente zuerst exportiert und diese alte App
einmal deinstalliert werden. Danach lässt sich die signierte APK installieren;
weitere Updates mit demselben Release-Schlüssel erhalten die App-Daten.

Für einen sofort installierbaren lokalen Test ohne Release-Key kann stattdessen
ein automatisch mit dem Android-Entwicklerschlüssel signierter Debug-Split
gebaut werden:

```powershell
flutter build apk --debug --split-per-abi
```

Debug-signierte APKs sind nur für Entwicklung und Sideloading gedacht. Sie
dürfen nicht im Store veröffentlicht werden.

## Release-Signierung

Für einen signierten Store-Build wird eine nicht eingecheckte
`android/key.properties` mit einem dauerhaft gesicherten Upload-/Release-Key
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

## SMART Board MX / MX Pro

SMART iQ aktiviert für neu installierte Android-Drittanbieter-Apps
standardmäßig eine eigene Anmerkungsebene. Diese privilegierte Ebene liegt über
der App und kann den Stift abfangen, bevor Flowboard X einen Android-Pointer
erhält. Auf erkannter SMART-Hardware zeigt Flowboard X deshalb einmalig den
offiziellen Einrichtungsweg an:

1. Am Board **Einstellungen → Annotation** öffnen.
2. Unter **Alle Apps** beziehungsweise **Installierte Apps** Flowboard X
   auswählen.
3. Den Anmerkungsschalter ausschließlich für Flowboard X ausschalten.
4. Zu Flowboard X zurückkehren und die Einrichtung bestätigen.

Die globale SMART-Anmerkungsfunktion muss nicht abgeschaltet werden. Fehlt die
App-Liste, benötigt das Board mindestens iQ 3.12. Sind die Einstellungen
administrativ gesperrt, muss ein Administrator sie entsperren. Es existiert
keine veröffentlichte SMART-API, mit der eine normale APK diese privilegierte
Geräteeinstellung selbst verändern darf.

Als zusätzliche Absicherung fordert die Android-App
`HIDE_OVERLAY_WINDOWS` an und aktiviert ab Android 12
`Window.setHideOverlayWindows(true)`. Außerdem wird Androids automatische
Stylus-IME-Handschrift über der Flutter-Zeichenfläche deaktiviert. Diese
Maßnahmen schützen vor gewöhnlichen App-Overlays und einem konkurrierenden
Android-Text-Eingabepfad, ersetzen aber nicht den appbezogenen SMART-Schalter
auf älteren MX286-Pro/iQ-Geräten.

Wird Flowboard X als Windows-App auf einem OPS oder verbundenen Rechner
ausgeführt, ist stattdessen in den SMART-Ink-Fensterwerkzeugen
**SMART Ink ausschalten → In dieser Anwendung** zu wählen.

## Bedienung auf dem Smartboard

- Stylus: schreiben; invertierter Stylus oder „Radiergummi“ im Stiftfächer:
  partiell radieren. Die Radiergröße folgt automatisch der gemeldeten
  Stift-/Hardwarekontaktfläche und ist unabhängig von der Stiftdicke
- mit der Unterseite der geballten Faust oder einer breit aufgelegten Hand über
  die Tinte wischen: Nur die überstrichenen Linienabschnitte werden unabhängig
  vom aktiven Werkzeug und vom Menüstatus entfernt. Der sichtbare Kreis folgt
  der erkannten Auflagefläche und entspricht exakt dem Löschbereich. Androids native
  Palm-Klassifizierung (`TOOL_TYPE_PALM`, `FLAG_CANCELED` und der ältere
  `ACTION_CANCEL`-Pfad) wird zusätzlich zum Flutter-Kontaktprofil ausgewertet.
  Teilt ein Touchpanel die Faust in mehrere kleine Kontakte auf, erkennt die
  App drei oder mehr kompakte, gemeinsam bewegte Kontakte als eine
  Radiergeste und bildet daraus einen gemeinsamen Kontakt-Hüllkreis; der
  gesamte Wisch bleibt ein einzelner Undo-Schritt. Normale Ein-/Zwei-Finger-
  Gesten bleiben Auswahl, Verschieben beziehungsweise Pan/Zoom
- Finger-Schalter in der Kopfleiste aus (Standard): ein Finger auf leerem Board
  verschiebt die Fläche; eingeschaltet schreibt ein einzelner Finger. Ein
  zweiter Finger übernimmt weiterhin zuverlässig Pan und Zoom
- zwei Finger ohne aktive Auswahl: pan und zoomen; dabei erscheint kurz der
  verschiebbare Navigator, dessen roter Rahmen auch direkt gezogen werden kann
- Auswahlmodus: tippen wechselt nachvollziehbar zwischen Stroke, Buchstabe,
  Wort, Zeile und Skizze; ziehen erzeugt Rechteck oder Lasso, „Alles auswählen“
  erfasst den vollständigen Seiteninhalt
- Auswahl verschieben oder skalieren: Der gesamte sichtbare Auswahlrahmen ist
  als Drag-Fläche nutzbar, Inhalt und objektgebundene Annotationen folgen live.
  Ein Fingertipp auf freie Fläche hebt die Auswahl auf. Zwei Finger innerhalb
  des Rahmens skalieren proportional; Undo entsteht erst beim Loslassen
- Auswahl drehen: Der Griff links unten rotiert frei; langes Drücken bietet
  30°, 45°, 60°, 90°, Spiegeln und eine manuelle Gradeingabe
- Auswahl anordnen: eine Ebene oder vollständig nach vorn beziehungsweise
  hinten; Tinte und Objekte teilen dabei dieselbe stabile Reihenfolge
- Geometrie aufziehen: Rechteck, Kreis, Ellipse oder Dreieck werden bereits
  während der Geste in ihren tatsächlichen Proportionen dargestellt
- Reveal-Abdeckung: die blaue Freilegungsgrenze direkt ziehen; vier getrennte,
  mittig platzierte Kantengriffe ändern die Größe ohne doppelte Seitengriffe.
  Beides funktioniert ohne Slider und ist gegen Mehrfachgesten geschützt
- Long-Press auf leerer Fläche: alles leeren, Handschrift leeren, einfügen und
  – nach Kopieren/Ausschneiden – Zwischenablage einsetzen
- Zentrum des Radialmenüs: öffnen/schließen; Drag im Zentrum: frei verschieben.
  Im Zwei-Personen-Modus erreicht ein geschlossenes Menü alle Außen- und
  Unterkanten seiner Hälfte; beim Öffnen bleiben die Ringe innerhalb der
  jeweiligen Bedienhälfte und beim Schließen kehrt das Zentrum an seine
  vorherige Randposition zurück. „Menüposition zurücksetzen“ in der Kopfleiste
  zentriert es im Sichtfeld
- Stiftfarbe sowie Normal, Marker, Gestrichelt, Gerade Linie und Radiergummi
  lassen sich direkt in der Kopfleiste wechseln; auf schmalen Displays liegen
  dieselben Schnellaktionen im Überlaufmenü
- bereits aktive Hauptfunktion erneut wählen: deren Außenringe einklappen
- Stift: Farben bilden Ring 2; der große Dickenbogen und die kompakt gebündelten
  Typen Normal, Marker, Gestrichelt, Gerade Linie und Radiergummi bilden Ring 3.
  Der Dickenbogen wird nur für zeichnende Stifte angezeigt. Beim Radiergummi
  wird die Größe automatisch aus dem Live-Kontakt bestimmt; dessen eigenes
  Blockradierer-Glyph zeigt mit einer unterbrochenen Tintenlinie eindeutig die
  Löschfunktion
- Vorlagen: Ring 2 enthält die vier eingebauten Vorlagen und „Eigene Vorlagen“;
  der Eintrag öffnet eine Bibliothek mit Vorschau, Auswahl und Löschen
- das Vorlagensymbol in der Kopfleiste speichert die aktuelle Seite als eigene
  Vorlage
- vorherige/nächste/neue Seite: führt die Aktion aus und öffnet das zyklische
  Miniatur-Drehrad; Kreisbewegung oder eine Fünf-Finger-Kreisgeste wechselt
  weiter, einschließlich des Übergangs letzte ↔ erste Seite. Langes Drücken
  einer Vorschau bietet das bestätigte, per Undo rücknehmbare Löschen an
- Seitensymbol in der Kopfleiste: breites Seitenfach mit echten Miniaturen;
  horizontal wischen oder scrollen, um weitere Seiten direkt anzuwählen
- neben der Seitenzahl in der Kopfleiste: Pfeile für vorherige/nächste Seite
  sowie Schaltflächen für eine neue beziehungsweise die bestätigte Löschung
  der aktuellen Seite; die letzte verbleibende Seite ist geschützt
- Pfeil am rechten Ende der Kopfleiste: Leiste auf Zurück, Logo und
  Ausklapppfeil reduzieren beziehungsweise wieder vollständig anzeigen
- Personen-Schalter in der Kopfleiste: zwischen voller Arbeitsfläche und zwei
  strikt getrennten Bedienhälften wechseln. Pan, Zoom, Seitenwechsel und neue
  Seiten wirken nur auf die auslösende Hälfte; Inhalte bleiben beim Umschalten
  unverändert erhalten
- Timer-Symbol in der Kopfleiste: Dauer einstellen, starten, pausieren oder
  zurücksetzen; ab einer Minute Restzeit erscheint die große Anzeige
  automatisch. Sie kann ohne Schreibunterbrechung verschoben und skaliert
  werden. Bei 00:00 bleibt sie geöffnet und der Alarm wird wiederholt, bis er
  dort ausdrücklich bestätigt wird
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

Das aktuelle Format ist Schema 5. Es speichert Seiten, Viewports, Ink,
Gruppierungen, Objekte, Objektannotationen, Templates, PDF-Seitenzustände,
Assets, Presets, Auswahlzustände, Rotation, Spiegelung, Metadaten und
Menüposition. Assets werden mit
SHA-256 und relativen, gegen Path Traversal geprüften Pfaden geführt. Saves
werden außerhalb des Rendering-Pfads serialisiert, zunächst in eine temporäre
Datei geschrieben, verifiziert und atomar befördert. Beim Start werden Primary,
Journal und Backup validiert und die höchste konsistente Revision gewählt.
Gleichlautende Dokument-, Vorlagen-, Export- und Quelldateinamen sind erlaubt:
interne UUIDs beziehungsweise eindeutige Exportnamen verhindern Kollisionen.
Nicht abgefangene Flutter-, Plattform-, Isolate- und Zonenfehler werden
datensparsam im rotierenden Ordner `FlowboardX/diagnostics` protokolliert, ohne
Auto-Save, Rendering oder den Startpfad zu blockieren.

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
Vektortinte außerhalb des UI-Threads und führt als primäre Engine das offizielle
`PP-OCRv6_small_rec` aus. Dieses Modell unterstützt 50 Sprachen und wurde
ausdrücklich auch auf Handschrift trainiert. Die Inferenz läuft lokal über ONNX
Runtime: Modell (21.159.378 Bytes), Originalkonfiguration und Lizenztexte sind
vollständig im APK enthalten. Es findet weder beim ersten Start noch später ein
Modell-Download statt. Falls ONNX Runtime auf einem ungewöhnlichen Gerät nicht
initialisiert werden kann oder ein Kandidat nicht sicher genug ist, bleibt das
ebenfalls gebündelte `com.google.mlkit:text-recognition:16.0.1` als defensiver,
unabhängiger Offline-Fallback verfügbar; die Play-Services-Variante wird nicht
verwendet.

Beim ersten Erkennungsauftrag wird das unveränderliche ONNX-Asset atomar in den
privaten App-Speicher gestreamt und von dort geladen. Dadurch liegen nicht
gleichzeitig eine vollständige Java-Bytekopie und das native Modell im Speicher.
Session, Session-Optionen und wiederverwendeter Tensorpuffer besitzen einen
gemeinsamen, serialisierten Lebenszyklus. Die ML-Kit-Laufzeit wird nur dann
lazy initialisiert, wenn PP-OCR technisch nicht verfügbar ist oder sein
Ergebnis keine ausreichend sichere Einzel- beziehungsweise geometrische
Evidenz besitzt.

ONNX Runtime löst einen Teil seiner Java-Typen aus nativem JNI-Code über feste
Binärnamen auf. Der Android-Release übernimmt deshalb die
[offizielle `ai.onnxruntime`-Keep-Regel](https://onnxruntime.ai/docs/build/android.html#note-proguard-rules-for-r8-minimization-android-app-builds-to-work).
Der Build kontrolliert sowohl die R8-Berichte als auch die tatsächlich erzeugten
DEX-Dateien jeder APK; fehlen beispielsweise `TensorInfo` oder `OnnxTensor`,
wird das Artefakt nicht ausgeliefert. Das verhindert einen ansonsten nicht
abfangbaren Release-only-`SIGABRT`.

Vor dem Laden wird die materialisierte ONNX-Datei zusätzlich gegen den
eingebetteten SHA-256-Wert geprüft. Jede Inferenz verwendet eigene
`OrtSession.RunOptions`; der gemeinsame Erkennungs-Deadline kann dadurch auch
einen bereits laufenden nativen ORT-Aufruf beenden, statt nur den Dart-Future
abzubrechen.

Modellquelle:
[`PaddlePaddle/PP-OCRv6_small_rec_onnx`](https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx),
SHA-256
`5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634`.

Der Release-Build prüft Modell, Konfiguration und Lizenzen vor dem Verpacken
bytegenau per SHA-256. Der nachgelagerte APK-Verifier kontrolliert zusätzlich
die wirklich gepackten Assets und die ML-Kit-Fallbackmodelle. Ein Release ohne
vollständige lokale Erkennung bricht deshalb ab, statt eine erst auf dem
Zielgerät unvollständige APK auszuliefern.

Androids geräteunabhängige Vorverarbeitung entfernt dichte
Sampling-Duplikate, begrenzt Pfadkommandos und segmentiert die Vektortinte
geometrisch in Zeilen. Für PP-OCRv6 wird jede Zeile seitenverhältnistreu auf
48 Pixel Höhe skaliert, in BGR/CHW angeordnet und exakt wie in der offiziellen
Modellkonfiguration normalisiert. Ein eigener, getesteter CTC-Decoder bildet
die 18.710 Ausgabeklassen einschließlich Leerzeichen und deutscher Sonderzeichen
zurück. Mehrzeilige Ergebnisse werden erst übernommen, wenn jede Zeile erkannt
wurde; bei unsicherem Ergebnis greift die bestehende Profil-, Wort- und
Zeilenheuristik des Offline-Fallbacks.

Da PP-OCRv6 ein gemeinsames mehrsprachiges Vokabular verwendet, berechnet die
Android-Engine beim Sessionstart einmalig eine Latin-Klassenmaske. Der
CTC-Decoder berücksichtigt danach nur Blank, Leerzeichen, lateinische
Buchstaben einschließlich Umlauten und `ß`, Ziffern sowie übliche Satzzeichen.
Visuell ähnliche griechische, kyrillische, CJK- oder Emoji-Klassen können daher
deutschen Text nicht verdrängen; zugleich sinkt der Argmax-Aufwand deutlich.

Strichreihenfolge und Zeitstempel unterstützen weiterhin die
räumlich-zeitliche Worttrennung. Der Platform-Channel überträgt Koordinaten als
kompakte Typed-Arrays statt als tausende einzelne Maps und ist auf 20.000
geometrieerhaltend vereinfachte Punkte begrenzt. Pro Editor ist nur eine
Textumwandlung gleichzeitig aktiv; Änderungen an Auswahl, Seite oder
Originalstrichen machen ein verspätetes Ergebnis ungültig. Modell-,
Bitmap- und Auswahllebenszyklen bleiben auch bei Timeout und App-Ende
serialisiert. Ein gültiger, aber nicht erkannter Strich ist ein
`notRecognized`-Ergebnis und keine `FormatException`.
Wie jede lokale Handschrifterkennung bleibt auch diese probabilistisch; sie
verwendet jedoch auf allen unterstützten Android-Geräten dasselbe
handschrifttrainierte Modell und hängt nicht von herstellerspezifisch
installierten Sprachmodulen ab.

Windows übergibt die Vektorstriche
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
  diagnostics/         rotierende, datensparsame Sitzungs- und Fehlerlogs
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
    handwriting/       Recognition-Port und native Offline-Adapter
  platform/            kleine, typisierte Android-Channels
```

Wesentliche Entscheidungen:

- Feature-lokale `ChangeNotifier` plus immutable Dokumente und Commands statt
  globaler UI-State: Live-Pointer erzeugen keine globalen Rebuilds.
- Jeder aktive Pointer besitzt eine isolierte Session. Live-Ink wird in kleine,
  gecachte Segmente zerlegt; committed Ink, Objekte und Preview sind getrennte
  Repaint-Layer.
- Dokument-Commands tragen alle inhaltlichen Undo/Redo-Schritte. Seitenwechsel
  und Viewports bleiben persistent, verbrauchen aber keinen Undo-Eintrag. Im
  Zwei-Personen-Modus besitzt jede Hälfte eine lokale Kamera und aktive Seite,
  während selektives Drei-Wege-Replay pro Teilnehmer nur dessen eigene
  Command-Folge zurücknimmt und fremde, zeitlich verschachtelte Änderungen
  erhält. Beide speisen weiterhin eine gemeinsame absturzsichere
  Dokument-/Auto-Save-Sitzung; auch die Position des Radialmenüs wird durch
  Undo/Redo nicht verändert.
- Tinte und Board-Objekte werden anhand einer gemeinsamen, stabilen
  Z-Reihenfolge gerendert, getroffen, exportiert und in Miniaturen dargestellt.
- Objektannotationen liegen in normalisierten Objektkoordinaten und benötigen
  beim Transformieren keine Punkt-für-Punkt-Umschreibung. Gebündelte PDFs
  besitzen zusätzlich eine getrennte Ink-Schicht pro PDF-Quellseite.
- Gruppierung ist eine deterministische, lokal begrenzte Heuristik aus Raum,
  Zeit, Baseline und Bounds; sie benötigt kein Netzwerk und keine KI.
- Abhängigkeiten bleiben bewusst klein: `path_provider`, `path`, `uuid`,
  `file_picker`, `pdfrx`, `http`, `crypto`, `qr_flutter` und
  `package_info_plus`.

## Diagnose-Logs

Flowboard X schreibt lokal strukturierte, größenbegrenzte JSONL-Logs in den
Unterordner `FlowboardX/diagnostics` des App-Support-Verzeichnisses. Vier
Dateien mit jeweils höchstens ungefähr 768 KiB werden rotierend aufbewahrt.
Erfasst werden Sitzungs-ID, App-/Build-Version, Plattform, Lebenszyklus,
Speicherdruck und globale Flutter-, Isolate- und Zonenfehler. Fehler werden nur
mit Typ, datensicherem Quellstellen-Ausschnitt und stabilem Fingerprint
gespeichert. Handschrift, Strichpunkte, erkannter Text, Dokumentnamen/-IDs,
lokale Dokument-/Asset-/Dateisystempfade, URLs und Zugangsdaten werden weder
protokolliert noch in Fehlermeldungen übernommen. Stacktraces behalten nur
paketrelative Code-Quellstellen.

`DiagnosticLogService.instance` stellt für weitere Features `debug`, `info`,
`warning` und `recordException` bereit. `flush`, `logFiles` und
`createExportCopy` bilden eine kleine Service-API für Support-Exporte;
`shutdown` beendet die Queue idempotent. Der
Export enthält ausschließlich die bereits bereinigten Einträge. Logging und
Rotation laufen über eine begrenzte serielle Queue. Der App-Start wartet nicht
auf Log-Schreibzugriffe; Metadaten- und explizite Flush-Wartezeiten sind
begrenzt.
Schreibfehler oder ein volles Dateisystem beeinflussen den Whiteboard-Pfad
nicht.

Über **Bedienhilfe → Diagnoseprotokoll teilen** kann der Nutzer die bereinigten
JSONL-Dateien direkt über die Systemfreigabe an den Support übergeben. Dadurch
bleiben die Logs im privaten App-Speicher, bis der Nutzer den Export bewusst
auslöst.

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
  Z-Reihenfolge, freie Rotation, Abdeckungsaktionen, getrennte
  Zwei-Personen-Viewports und -Seitennavigation, simultane Zwei-Personen-Tinte,
  Auswahl-Pinch, Timer, Finger-Schreibmodus, partielles Radieren sowie Widget-,
  SAF-, Quick-Share- und Handschrift-Bridge ab.
