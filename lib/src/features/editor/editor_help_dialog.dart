import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';

/// Central, scrollable in-app guide. Kept as a reusable component so the
/// top-bar info button and future first-run onboarding show identical help.
class FlowboardHelpDialog extends StatelessWidget {
  const FlowboardHelpDialog({this.onExportDiagnostics, super.key});

  final Future<void> Function()? onExportDiagnostics;

  static Future<void> show(
    BuildContext context, {
    Future<void> Function()? onExportDiagnostics,
  }) => showDialog<void>(
    context: context,
    builder: (_) =>
        FlowboardHelpDialog(onExportDiagnostics: onExportDiagnostics),
  );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: FlowboardColors.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 880, maxHeight: size.height - 48),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 12, 10),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Flowboard bedienen',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Schließen',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            const Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(24),
                child: Wrap(
                  spacing: 18,
                  runSpacing: 18,
                  children: [
                    _HelpCard(
                      icon: Icons.draw_rounded,
                      title: 'Schreiben und navigieren',
                      lines: [
                        'Mit dem Stift schreiben; mehrere Stifte können gleichzeitig arbeiten.',
                        'Finger-Schreiben ist standardmäßig aus: Ein Finger verschiebt dann das Board. Der Finger-Schalter in der Kopfleiste aktiviert das Schreiben mit einem Finger.',
                        'Zwei Finger übernehmen weiterhin Pan und Zoom, auch wenn Finger-Schreiben aktiv ist.',
                        'Beim Zoomen erscheint rechts unten ein verschiebbarer Navigator. Im roten Rahmen ziehen oder tippen navigiert; ohne Interaktion blendet er sich aus.',
                        'Mit der Unterseite der geballten Faust oder einer breit aufgelegten Hand über die Tinte wischen: Die App erkennt die Radierabsicht automatisch, ohne Werkzeugwechsel.',
                        'Der sichtbare Kreis folgt der erkannten Auflagefläche. Mehr Fläche erzeugt einen größeren Radierer; Kreis und tatsächlich gelöschter Bereich sind identisch.',
                        'Auch der Radiergummi im Stiftfächer bestimmt seine Größe automatisch aus dem Stift-/Hardwarekontakt. Der Dickenregler erscheint nur für zeichnende Stifte.',
                        'Ein oder zwei normale Finger bleiben Auswahl, Verschieben sowie Pan/Zoom und lösen keine Radierung aus.',
                      ],
                    ),
                    _HelpCard(
                      icon: Icons.blur_circular_rounded,
                      title: 'Radialmenü',
                      lines: [
                        'Zentrum antippen: Menü öffnen oder schließen. Zentrum ziehen: Menü verschieben.',
                        'Seitenrad drehen oder mit fünf Fingern um das Menü kreisen, um Seiten zu wechseln.',
                        'Eine Seitenvorschau im Seitenrad gedrückt halten, um diese Seite nach Bestätigung zu löschen.',
                        'In der Kopfleiste wechseln die Pfeile neben der Seitenzahl vor und zurück; daneben liegen Neue Seite und Seite löschen.',
                        '„Menüposition zurücksetzen“ setzt es in die Mitte des sichtbaren Bereichs.',
                        'Der Pfeil am rechten Ende klappt die Kopfleiste platzsparend ein und wieder aus.',
                      ],
                    ),
                    _HelpCard(
                      icon: Icons.select_all_rounded,
                      title: 'Auswählen und gruppieren',
                      lines: [
                        'Rechteck, Lasso oder „Alles auswählen“ verwenden.',
                        'Zum Verschieben genügt ein Drag an einer beliebigen Stelle innerhalb des sichtbaren Auswahlrahmens; ein Fingertipp auf freie Fläche hebt die Auswahl auf.',
                        'Am Griff proportional skalieren oder mit zwei Fingern direkt auf der Auswahl per Pinch vergrößern und verkleinern.',
                        'Der Griff links unten dreht frei. Gedr\u00fcckt halten \u00f6ffnet 30\u00b0, 45\u00b0, 60\u00b0, 90\u00b0, Spiegeln und den manuellen Winkel.',
                        'Gruppen bleiben zusammen, bis „Gruppierung aufheben“ gewählt wird.',
                      ],
                    ),
                    _HelpCard(
                      icon: Icons.people_alt_rounded,
                      title: 'Eine oder zwei Personen',
                      lines: [
                        'Der Personen-Schalter in der Kopfleiste teilt die Arbeitsfl\u00e4che in zwei unabh\u00e4ngige Bedienseiten.',
                        'Jede Seite besitzt ein eigenes Radialmen\u00fc, Werkzeug, eine eigene Kamera und eine eigene aktive Seite.',
                        'Beide Personen schreiben gleichzeitig in dasselbe Dokument; die Mittellinie ordnet Ber\u00fchrungen stabil einer Seite zu. Pan, Zoom und Seitenwechsel wirken nur auf die jeweilige H\u00e4lfte.',
                        'Beim Zur\u00fcckschalten verschwinden nur Mittellinie und zweites Men\u00fc. Dokumentinhalt und Ebenen bleiben unver\u00e4ndert; die einzelne Ansicht verwendet wieder die linke aktive Seite und Kamera.',
                      ],
                    ),
                    _HelpCard(
                      icon: Icons.timer_outlined,
                      title: 'Timer',
                      lines: [
                        'Über das Timer-Symbol eine Dauer einstellen, starten, pausieren oder zurücksetzen.',
                        'Beim Start erscheint die große Anzeige sofort. Beim Wechsel zu einer anderen App bleibt ein laufender Timer unter Android als Bild-im-Bild sichtbar. Bei null ertönt der Alarm wiederholt, bis er dort mit „Alarm stoppen“ bestätigt wird.',
                        'Die große Anzeige lässt sich verschieben und skalieren. Außerhalb ihres Rechtecks kann ohne Unterbrechung weitergeschrieben werden.',
                      ],
                    ),
                    _HelpCard(
                      icon: Icons.developer_board_rounded,
                      title: 'SMART Board MX / iQ',
                      lines: [
                        'F\u00e4ngt SMARTs eigene Anmerkungsebene den Stift ab, am Board Einstellungen \u2192 Annotation \u2192 Alle Apps beziehungsweise Installierte Apps \u00f6ffnen.',
                        'Dort Flowboard X ausw\u00e4hlen und nur dessen Anmerkungsschalter ausschalten. Danach erh\u00e4lt Flowboard X die Stifteingabe direkt.',
                        'Fehlt die App-Liste, iQ aktualisieren. Bei gesperrten Einstellungen muss ein Administrator die \u00c4nderung freigeben.',
                        'Bei Betrieb als Windows-App: SMART Ink f\u00fcr Flowboard X \u00fcber \u201eSMART Ink ausschalten \u2192 In dieser Anwendung\u201c deaktivieren.',
                      ],
                    ),
                    _HelpCard(
                      icon: Icons.text_fields_rounded,
                      title: 'Handschrift und Text',
                      lines: [
                        'Handschrift auswählen und über „In Text umwandeln“ erkennen lassen.',
                        'Das lateinische Erkennungsmodell ist in der Android-App gebündelt und benötigt weder einen ersten Download noch eine Internetverbindung.',
                        'Text auswählen und „Text mit Stift korrigieren“ aktivieren.',
                        'Direkt über ein Wort schreiben, um es zu ersetzen; waagerecht durchstreichen löscht es.',
                        'Rechts hinter dem letzten Wort weiterschreiben hängt den erkannten Text an.',
                        'Die Korrektur läuft auf der Fläche und benötigt weder Tastatur noch separates Fenster.',
                      ],
                    ),
                    _HelpCard(
                      icon: Icons.layers_outlined,
                      title: 'Objekte und Ebenen',
                      lines: [
                        'Bilder, PDFs und Tabellen können verschoben, skaliert und angeordnet werden.',
                        'Darauf geschriebene Annotationen bewegen und skalieren sich mit dem Objekt.',
                        'Abdeckungen lassen sich an allen vier Kanten direkt vergrößern oder verkleinern.',
                        'Die blaue Freilegungsgrenze lässt sich direkt ziehen; pro Kante bleibt genau ein Größengriff.',
                        'Die Auswahlleiste ordnet Inhalte schrittweise oder vollständig nach vorn und hinten.',
                      ],
                    ),
                    _HelpCard(
                      icon: Icons.save_outlined,
                      title: 'Speichern und Teilen',
                      lines: [
                        'Änderungen werden automatisch gespeichert und nach einem Abbruch wiederhergestellt.',
                        'Export erzeugt ein PDF; WLAN/QR teilt lokal und Quick Share nutzt das Gerätesystem.',
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (onExportDiagnostics != null) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    key: const ValueKey('export-diagnostics-button'),
                    onPressed: () => unawaited(onExportDiagnostics!()),
                    icon: const Icon(Icons.bug_report_outlined),
                    label: const Text('Diagnoseprotokoll teilen'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard({
    required this.icon,
    required this.title,
    required this.lines,
  });

  final IconData icon;
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 390),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: FlowboardColors.background,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: FlowboardColors.divider),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: FlowboardColors.mint),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 7),
                        child: CircleAvatar(
                          radius: 2.5,
                          backgroundColor: FlowboardColors.mint,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(line)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
