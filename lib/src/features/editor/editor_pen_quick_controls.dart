import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../radial_menu/radial_menu_models.dart';
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

/// Fast switching between every drawing tool exposed by the pen fan.
///
/// [RadialPenType] is used deliberately instead of [InkToolType]: an eraser is
/// an input tool and must not be persisted as an ink stroke style.
class EditorPenTypeQuickButton extends StatelessWidget {
  const EditorPenTypeQuickButton({
    required this.type,
    required this.onTypeSelected,
    this.controlId,
    super.key,
  });

  static const List<RadialPenType> quickTypes = <RadialPenType>[
    RadialPenType.normal,
    RadialPenType.marker,
    RadialPenType.dashed,
    RadialPenType.straight,
    RadialPenType.eraser,
  ];

  final RadialPenType type;
  final ValueChanged<RadialPenType> onTypeSelected;
  final String? controlId;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<RadialPenType>(
      key: ValueKey(
        controlId == null
            ? 'editor-pen-type-quick-button'
            : 'editor-pen-type-quick-button-$controlId',
      ),
      tooltip: 'Stiftart',
      initialValue: quickTypes.contains(type) ? type : null,
      onSelected: onTypeSelected,
      itemBuilder: (context) => <PopupMenuEntry<RadialPenType>>[
        for (final candidate in quickTypes)
          PopupMenuItem<RadialPenType>(
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
      icon: Icon(editorPenTypeIcon(type), color: FlowboardColors.mint),
    );
  }
}

IconData editorPenTypeIcon(RadialPenType type) => switch (type) {
  RadialPenType.normal => Icons.edit_rounded,
  RadialPenType.marker => Icons.border_color_rounded,
  RadialPenType.dashed => Icons.more_horiz_rounded,
  RadialPenType.straight => Icons.show_chart_rounded,
  RadialPenType.eraser => Icons.cleaning_services_rounded,
};

String editorPenTypeLabel(RadialPenType type) => switch (type) {
  RadialPenType.normal => 'Normal',
  RadialPenType.marker => 'Marker',
  RadialPenType.dashed => 'Gestrichelt',
  RadialPenType.straight => 'Gerade Linie',
  RadialPenType.eraser => 'Radiergummi',
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
