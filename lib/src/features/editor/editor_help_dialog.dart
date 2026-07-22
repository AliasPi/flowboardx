import 'package:flutter/material.dart';

import '../../app/app_theme.dart';

/// Central, scrollable in-app guide. Kept as a reusable component so the
/// top-bar info button and future first-run onboarding show identical help.
class FlowboardHelpDialog extends StatelessWidget {
  const FlowboardHelpDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const FlowboardHelpDialog(),
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
                        'Auf leerer Fläche ziehen verschiebt das Board. Mit zwei Fingern zoomen.',
                        'Beim Zoomen erscheint rechts unten ein verschiebbarer Navigator. Im roten Rahmen ziehen oder tippen navigiert; ohne Interaktion blendet er sich aus.',
                        'Handkante oder breiter Kontakt radiert, während Stifte weiter schreiben können.',
                      ],
                    ),
                    _HelpCard(
                      icon: Icons.blur_circular_rounded,
                      title: 'Radialmenü',
                      lines: [
                        'Zentrum antippen: Menü öffnen oder schließen. Zentrum ziehen: Menü verschieben.',
                        'Seitenrad drehen oder mit fünf Fingern um das Menü kreisen, um Seiten zu wechseln.',
                        '„Menüposition zurücksetzen“ setzt es in die Mitte des sichtbaren Bereichs.',
                        'Der Pfeil am rechten Ende klappt die Kopfleiste platzsparend ein und wieder aus.',
                      ],
                    ),
                    _HelpCard(
                      icon: Icons.select_all_rounded,
                      title: 'Auswählen und gruppieren',
                      lines: [
                        'Rechteck, Lasso oder „Alles auswählen“ verwenden.',
                        'Am Rahmen verschieben oder am Griff proportional skalieren.',
                        'Gruppen bleiben zusammen, bis „Gruppierung aufheben“ gewählt wird.',
                      ],
                    ),
                    _HelpCard(
                      icon: Icons.text_fields_rounded,
                      title: 'Handschrift und Text',
                      lines: [
                        'Handschrift auswählen und über „In Text umwandeln“ erkennen lassen.',
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
