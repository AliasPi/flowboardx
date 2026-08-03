import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../domain/model/ink.dart';
import '../radial_menu/radial_menu_widget.dart';

/// Compact access to the current pen colour without opening the radial menu.
///
/// The regular palette is intentionally shared with [RadialMenu], so both
/// entry points always expose the same colours. The final menu item delegates
/// to the full colour wheel owned by the editor.
class EditorPenColorQuickButton extends StatelessWidget {
  const EditorPenColorQuickButton({
    required this.color,
    required this.onColorSelected,
    required this.onCustomColorRequested,
    this.controlId,
    super.key,
  });

  static const int _customColorValue = -1;

  final Color color;
  final ValueChanged<Color> onColorSelected;
  final VoidCallback onCustomColorRequested;
  final String? controlId;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      key: ValueKey(
        controlId == null
            ? 'editor-pen-color-quick-button'
            : 'editor-pen-color-quick-button-$controlId',
      ),
      tooltip: 'Stiftfarbe',
      initialValue: RadialMenu.defaultPalette.contains(color)
          ? color.toARGB32()
          : null,
      onSelected: (value) {
        if (value == _customColorValue) {
          onCustomColorRequested();
          return;
        }
        onColorSelected(Color(value));
      },
      itemBuilder: (context) => <PopupMenuEntry<int>>[
        for (final paletteColor in RadialMenu.defaultPalette)
          PopupMenuItem<int>(
            value: paletteColor.toARGB32(),
            child: _ColorMenuEntry(
              color: paletteColor,
              selected: paletteColor.toARGB32() == color.toARGB32(),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<int>(
          value: _customColorValue,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.colorize_rounded),
            title: Text('Freie Farbe …'),
          ),
        ),
      ],
      icon: _CurrentColorGlyph(color: color),
    );
  }
}

/// Fast switching between the handwriting modes most often used in class.
/// Marker remains available in the radial menu; if it is active, its icon is
/// still represented here until one of these three quick modes is selected.
class EditorPenTypeQuickButton extends StatelessWidget {
  const EditorPenTypeQuickButton({
    required this.type,
    required this.onTypeSelected,
    this.controlId,
    super.key,
  });

  static const List<InkToolType> quickTypes = <InkToolType>[
    InkToolType.normal,
    InkToolType.dashed,
    InkToolType.straightLine,
  ];

  final InkToolType type;
  final ValueChanged<InkToolType> onTypeSelected;
  final String? controlId;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<InkToolType>(
      key: ValueKey(
        controlId == null
            ? 'editor-pen-type-quick-button'
            : 'editor-pen-type-quick-button-$controlId',
      ),
      tooltip: 'Stiftart',
      initialValue: quickTypes.contains(type) ? type : null,
      onSelected: onTypeSelected,
      itemBuilder: (context) => <PopupMenuEntry<InkToolType>>[
        for (final candidate in quickTypes)
          PopupMenuItem<InkToolType>(
            value: candidate,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                editorPenTypeIcon(candidate),
                color: candidate == type ? FlowboardColors.mint : null,
              ),
              title: Text(editorPenTypeLabel(candidate)),
              trailing: candidate == type
                  ? const Icon(
                      Icons.check_rounded,
                      size: 19,
                      color: FlowboardColors.mint,
                    )
                  : null,
            ),
          ),
      ],
      icon: Icon(
        editorPenTypeIcon(type),
        color: quickTypes.contains(type) ? FlowboardColors.mint : null,
      ),
    );
  }
}

IconData editorPenTypeIcon(InkToolType type) => switch (type) {
  InkToolType.normal => Icons.edit_rounded,
  InkToolType.marker => Icons.border_color_rounded,
  InkToolType.dashed => Icons.more_horiz_rounded,
  InkToolType.straightLine => Icons.show_chart_rounded,
};

String editorPenTypeLabel(InkToolType type) => switch (type) {
  InkToolType.normal => 'Normal',
  InkToolType.marker => 'Marker',
  InkToolType.dashed => 'Gestrichelt',
  InkToolType.straightLine => 'Gerade Linie',
};

class _CurrentColorGlyph extends StatelessWidget {
  const _CurrentColorGlyph({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Aktuelle Stiftfarbe',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white70, width: 1.5),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: Colors.black38, blurRadius: 3),
          ],
        ),
        child: const SizedBox.square(dimension: 22),
      ),
    );
  }
}

class _ColorMenuEntry extends StatelessWidget {
  const _ColorMenuEntry({required this.color, required this.selected});

  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white70),
        ),
        child: const SizedBox.square(dimension: 24),
      ),
      title: Text(_colorName(color)),
      trailing: selected
          ? const Icon(
              Icons.check_rounded,
              size: 19,
              color: FlowboardColors.mint,
            )
          : null,
    );
  }

  static String _colorName(Color color) => switch (color.toARGB32()) {
    0xFF000000 => 'Schwarz',
    0xFF2196F3 => 'Blau',
    0xFFF44336 => 'Rot',
    0xFF4CAF50 => 'Grün',
    0xFFFFC107 => 'Gelb',
    0xFF00BCD4 => 'Türkis',
    0xFFFFFFFF => 'Weiß',
    0xFF9C27B0 => 'Violett',
    _ => 'Farbe',
  };
}
