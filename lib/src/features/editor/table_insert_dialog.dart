import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../radial_menu/radial_menu_models.dart';

/// Responsive, pen-friendly table configuration shown after the Table entry
/// in Ring 2 is chosen. The table is only committed after explicit
/// confirmation.
class TableInsertDialog extends StatefulWidget {
  const TableInsertDialog({
    required this.initialSize,
    this.maximumDimension = 24,
    super.key,
  }) : assert(maximumDimension > 0);

  final RadialTableSize initialSize;
  final int maximumDimension;

  static Future<RadialTableSize?> show(
    BuildContext context, {
    RadialTableSize initialSize = const RadialTableSize(3, 4),
  }) {
    return showDialog<RadialTableSize>(
      context: context,
      builder: (_) => TableInsertDialog(initialSize: initialSize),
    );
  }

  @override
  State<TableInsertDialog> createState() => _TableInsertDialogState();
}

class _TableInsertDialogState extends State<TableInsertDialog> {
  late int _rows;
  late int _columns;

  @override
  void initState() {
    super.initState();
    _rows = widget.initialSize.rows.clamp(1, widget.maximumDimension);
    _columns = widget.initialSize.columns.clamp(1, widget.maximumDimension);
  }

  void _changeRows(int delta) {
    final next = (_rows + delta).clamp(1, widget.maximumDimension);
    if (next != _rows) setState(() => _rows = next);
  }

  void _changeColumns(int delta) {
    final next = (_columns + delta).clamp(1, widget.maximumDimension);
    if (next != _columns) setState(() => _columns = next);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final dialogWidth = math.min(620.0, math.max(280.0, screen.width - 32));
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.table_chart_outlined),
          SizedBox(width: 12),
          Expanded(child: Text('Tabelle einfügen')),
        ],
      ),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Lege Zeilen und Spalten fest. Eine Vorschau zeigt das '
                'Ergebnis vor dem Einfügen.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.center,
                runAlignment: WrapAlignment.center,
                spacing: 16,
                runSpacing: 12,
                children: [
                  _DimensionStepper(
                    label: 'Zeilen',
                    value: _rows,
                    onDecrease: _rows > 1 ? () => _changeRows(-1) : null,
                    onIncrease: _rows < widget.maximumDimension
                        ? () => _changeRows(1)
                        : null,
                  ),
                  _DimensionStepper(
                    label: 'Spalten',
                    value: _columns,
                    onDecrease: _columns > 1 ? () => _changeColumns(-1) : null,
                    onIncrease: _columns < widget.maximumDimension
                        ? () => _changeColumns(1)
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Semantics(
                label:
                    'Tabellenvorschau mit $_rows Zeilen und $_columns Spalten',
                image: true,
                child: Container(
                  height: math.min(260, math.max(150, screen.height * .28)),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8F7F2),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF66716E)),
                  ),
                  padding: const EdgeInsets.all(14),
                  child: CustomPaint(
                    key: const ValueKey('table-insert-preview'),
                    painter: _TablePreviewPainter(
                      rows: _rows,
                      columns: _columns,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton.icon(
          onPressed: () =>
              Navigator.pop(context, RadialTableSize(_rows, _columns)),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Tabelle einfügen'),
        ),
      ],
    );
  }
}

class _DimensionStepper extends StatelessWidget {
  const _DimensionStepper({
    required this.label,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
  });

  final String label;
  final int value;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $value',
      value: '$value',
      child: Container(
        constraints: const BoxConstraints(minWidth: 240),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton.filledTonal(
                  tooltip: '$label verringern',
                  onPressed: onDecrease,
                  icon: const Icon(Icons.remove_rounded),
                ),
                SizedBox(
                  width: 72,
                  child: Text(
                    '$value',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: '$label erhöhen',
                  onPressed: onIncrease,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TablePreviewPainter extends CustomPainter {
  const _TablePreviewPainter({required this.rows, required this.columns});

  final int rows;
  final int columns;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || rows <= 0 || columns <= 0) return;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..color = const Color(0xFF63706D)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    // Board tables deliberately have no outside border. The dialog mirrors
    // that exact rendering so the preview is truthful.
    for (var row = 1; row < rows; row++) {
      final y = rect.top + rect.height * row / rows;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
    }
    for (var column = 1; column < columns; column++) {
      final x = rect.left + rect.width * column / columns;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TablePreviewPainter oldDelegate) {
    return rows != oldDelegate.rows || columns != oldDelegate.columns;
  }
}
