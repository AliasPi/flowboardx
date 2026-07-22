import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';

/// A full-range saturation/value coordinate used by [PenColorPickerMath].
@immutable
class PenSaturationValue {
  const PenSaturationValue({required this.saturation, required this.value});

  final double saturation;
  final double value;
}

/// Geometry and color helpers shared by the painter and pointer handling.
///
/// The inner picker is visually circular, but still represents the complete
/// saturation/value square. An elliptical square-to-disc mapping keeps all
/// four important extremes reachable: white, black, pure hue and black.
abstract final class PenColorPickerMath {
  static double normalizeHue(double hue) {
    if (!hue.isFinite) return 0;
    final normalized = hue % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  /// Hue at [position], with red at 12 o'clock and increasing clockwise.
  static double hueForPosition(Offset position, Offset center) {
    final delta = position - center;
    if (delta.distanceSquared <= 1e-8) return 0;
    final degrees = math.atan2(delta.dy, delta.dx) * 180 / math.pi + 90;
    return normalizeHue(degrees);
  }

  static Color oppositeColor(HSVColor color) =>
      color.withHue(normalizeHue(color.hue + 180)).toColor();

  /// Maps saturation/value to a point relative to the inner disc's center.
  static Offset pointForSaturationValue({
    required double saturation,
    required double value,
    required double radius,
  }) {
    if (!radius.isFinite || radius <= 0) return Offset.zero;
    final square = Offset(
      saturation.clamp(0.0, 1.0) * 2 - 1,
      (1 - value.clamp(0.0, 1.0)) * 2 - 1,
    );
    return _squareToDisc(square) * radius;
  }

  /// Maps a point relative to the inner disc center back to saturation/value.
  static PenSaturationValue saturationValueForPoint({
    required Offset point,
    required double radius,
  }) {
    if (!radius.isFinite || radius <= 0) {
      return const PenSaturationValue(saturation: 0, value: 1);
    }
    var normalized = point / radius;
    final distance = normalized.distance;
    if (distance > 1) normalized /= distance;
    final square = _discToSquare(normalized);
    return PenSaturationValue(
      saturation: ((square.dx + 1) / 2).clamp(0.0, 1.0),
      value: (1 - (square.dy + 1) / 2).clamp(0.0, 1.0),
    );
  }

  static Offset _squareToDisc(Offset square) {
    final x = square.dx.clamp(-1.0, 1.0);
    final y = square.dy.clamp(-1.0, 1.0);
    return Offset(
      x * math.sqrt(math.max(0, 1 - y * y / 2)),
      y * math.sqrt(math.max(0, 1 - x * x / 2)),
    );
  }

  static Offset _discToSquare(Offset disc) {
    final u = disc.dx.clamp(-1.0, 1.0);
    final v = disc.dy.clamp(-1.0, 1.0);
    const rootTwo = math.sqrt2;
    final uSquared = u * u;
    final vSquared = v * v;

    final xPositive = math.sqrt(
      math.max(0, 2 + uSquared - vSquared + 2 * rootTwo * u),
    );
    final xNegative = math.sqrt(
      math.max(0, 2 + uSquared - vSquared - 2 * rootTwo * u),
    );
    final yPositive = math.sqrt(
      math.max(0, 2 - uSquared + vSquared + 2 * rootTwo * v),
    );
    final yNegative = math.sqrt(
      math.max(0, 2 - uSquared + vSquared - 2 * rootTwo * v),
    );
    return Offset(
      ((xPositive - xNegative) / 2).clamp(-1.0, 1.0),
      ((yPositive - yNegative) / 2).clamp(-1.0, 1.0),
    );
  }
}

/// Responsive color dialog for the free pen color in the radial menu.
class PenColorPickerDialog extends StatefulWidget {
  const PenColorPickerDialog({
    required this.initialColor,
    this.recentColors = const <Color>[],
    super.key,
  });

  final Color initialColor;
  final List<Color> recentColors;

  @override
  State<PenColorPickerDialog> createState() => _PenColorPickerDialogState();
}

class _PenColorPickerDialogState extends State<PenColorPickerDialog> {
  late HSVColor _color = HSVColor.fromColor(widget.initialColor);

  List<Color> get _recentColors {
    final seen = <int>{};
    return widget.recentColors
        .where((color) => seen.add(color.toARGB32()))
        .take(10)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final dialogWidth = math.min(580.0, math.max(220.0, viewport.width - 32));
    final wheelSize = math.min(460.0, math.max(176.0, dialogWidth - 48));
    final selected = _color.toColor();
    final opposite = PenColorPickerMath.oppositeColor(_color);

    return Dialog(
      key: const ValueKey('pen-color-picker-dialog'),
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 580,
          maxHeight: math.max(180, viewport.height - 32),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 10, 6),
              child: Row(
                children: [
                  const Icon(
                    Icons.palette_outlined,
                    color: FlowboardColors.mint,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Freie Stiftfarbe',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Abbrechen',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RepaintBoundary(
                      child: PenColorWheel(
                        key: const ValueKey('pen-color-wheel'),
                        value: _color,
                        size: wheelSize,
                        onChanged: (next) => setState(() => _color = next),
                      ),
                    ),
                    if (_recentColors.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Zuletzt verwendet',
                          style: TextStyle(
                            color: FlowboardColors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 9),
                      Semantics(
                        label: 'Zuletzt verwendete Stiftfarben',
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            for (
                              var index = 0;
                              index < _recentColors.length;
                              index++
                            )
                              _RecentColorSwatch(
                                key: ValueKey('recent-pen-color-$index'),
                                color: _recentColors[index],
                                selected:
                                    _recentColors[index].toARGB32() ==
                                    selected.toARGB32(),
                                onTap: () => setState(
                                  () => _color = HSVColor.fromColor(
                                    _recentColors[index],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Wrap(
                      alignment: WrapAlignment.center,
                      runAlignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _ColorSummary(
                          key: const ValueKey('pen-color-current-swatch'),
                          label: 'Ausgewählt',
                          color: selected,
                          selected: true,
                        ),
                        _ColorSummary(
                          key: const ValueKey('pen-color-opposite-swatch'),
                          label: 'Gegenfarbe',
                          color: opposite,
                          onTap: () => setState(
                            () => _color = _color.withHue(
                              PenColorPickerMath.normalizeHue(_color.hue + 180),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Farbton ${_color.hue.round()}°  ·  '
                      'Sättigung ${(_color.saturation * 100).round()} %  ·  '
                      'Helligkeit ${(_color.value * 100).round()} %',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: FlowboardColors.textSecondary,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_hex(selected)}  ·  '
                      'RGB ${_red(selected)}, ${_green(selected)}, ${_blue(selected)}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: FlowboardColors.textSecondary,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 10,
                overflowSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Abbrechen'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('pen-color-apply'),
                    onPressed: () => Navigator.of(context).pop(selected),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Übernehmen'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static int _red(Color color) => (color.r * 255).round().clamp(0, 255);
  static int _green(Color color) => (color.g * 255).round().clamp(0, 255);
  static int _blue(Color color) => (color.b * 255).round().clamp(0, 255);

  static String _hex(Color color) =>
      '#${_red(color).toRadixString(16).padLeft(2, '0')}'
              '${_green(color).toRadixString(16).padLeft(2, '0')}'
              '${_blue(color).toRadixString(16).padLeft(2, '0')}'
          .toUpperCase();
}

class _RecentColorSwatch extends StatelessWidget {
  const _RecentColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: 'Letzte Farbe ${_PenColorHex.value(color)}',
    child: Tooltip(
      message: _PenColorHex.value(color),
      child: InkResponse(
        onTap: onTap,
        radius: 27,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? FlowboardColors.mint : Colors.white70,
              width: selected ? 4 : 2,
            ),
            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 5)],
          ),
          child: selected
              ? Icon(
                  Icons.check_rounded,
                  color:
                      ThemeData.estimateBrightnessForColor(color) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black,
                )
              : null,
        ),
      ),
    ),
  );
}

abstract final class _PenColorHex {
  static String value(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}

class _ColorSummary extends StatelessWidget {
  const _ColorSummary({
    required this.label,
    required this.color,
    this.selected = false,
    this.onTap,
    super.key,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      constraints: const BoxConstraints(minWidth: 156),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: FlowboardColors.panelElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? FlowboardColors.mint : FlowboardColors.divider,
          width: selected ? 2 : 1,
        ),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 6,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white70, width: 1.5),
              boxShadow: const [
                BoxShadow(color: Colors.black38, blurRadius: 5),
              ],
            ),
          ),
          Text(label),
          if (onTap != null) ...[
            const Icon(Icons.swap_horiz_rounded, size: 18),
          ],
        ],
      ),
    );
    if (onTap == null) return content;
    return Semantics(
      button: true,
      label: 'Gegenfarbe auswählen',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: content,
      ),
    );
  }
}

enum _PickerRegion { hue, saturationValue }

/// Circular hue and saturation/value control with pointer-safe dragging.
class PenColorWheel extends StatefulWidget {
  const PenColorWheel({
    required this.value,
    required this.onChanged,
    required this.size,
    super.key,
  });

  final HSVColor value;
  final ValueChanged<HSVColor> onChanged;
  final double size;

  @override
  State<PenColorWheel> createState() => _PenColorWheelState();
}

class _PenColorWheelState extends State<PenColorWheel> {
  int? _activePointer;
  _PickerRegion? _activeRegion;

  double get _outerRadius => widget.size / 2 - 4;
  double get _ringWidth => math.max(28, widget.size * .175);
  double get _ringInnerRadius => _outerRadius - _ringWidth;
  double get _innerRadius =>
      math.max(22, _ringInnerRadius - widget.size * .035);
  Offset get _center => Offset(widget.size / 2, widget.size / 2);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Stiftfarbkreis',
      value:
          'Farbton ${widget.value.hue.round()} Grad, '
          'Sättigung ${(widget.value.saturation * 100).round()} Prozent, '
          'Helligkeit ${(widget.value.value * 100).round()} Prozent',
      increasedValue: 'Nächster Farbton',
      decreasedValue: 'Vorheriger Farbton',
      onIncrease: () => _changeHue(5),
      onDecrease: () => _changeHue(-5),
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: _pointerEnd,
          onPointerCancel: _pointerEnd,
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: _PenColorWheelPainter(widget.value),
          ),
        ),
      ),
    );
  }

  void _changeHue(double delta) {
    widget.onChanged(
      widget.value.withHue(
        PenColorPickerMath.normalizeHue(widget.value.hue + delta),
      ),
    );
  }

  void _pointerDown(PointerDownEvent event) {
    if (_activePointer != null) return;
    final distance = (event.localPosition - _center).distance;
    if (distance > _outerRadius + 12) return;
    _activePointer = event.pointer;
    _activeRegion = distance >= _ringInnerRadius
        ? _PickerRegion.hue
        : _PickerRegion.saturationValue;
    _update(event.localPosition);
  }

  void _pointerMove(PointerMoveEvent event) {
    if (_activePointer != event.pointer) return;
    _update(event.localPosition);
  }

  void _pointerEnd(PointerEvent event) {
    if (_activePointer != event.pointer) return;
    _activePointer = null;
    _activeRegion = null;
  }

  void _update(Offset position) {
    switch (_activeRegion) {
      case _PickerRegion.hue:
        widget.onChanged(
          widget.value.withHue(
            PenColorPickerMath.hueForPosition(position, _center),
          ),
        );
      case _PickerRegion.saturationValue:
        final next = PenColorPickerMath.saturationValueForPoint(
          point: position - _center,
          radius: _innerRadius,
        );
        widget.onChanged(
          widget.value.withSaturation(next.saturation).withValue(next.value),
        );
      case null:
        return;
    }
  }
}

class _PenColorWheelPainter extends CustomPainter {
  const _PenColorWheelPainter(this.color);

  final HSVColor color;

  @override
  void paint(Canvas canvas, Size size) {
    final shortest = size.shortestSide;
    final center = size.center(Offset.zero);
    final outerRadius = shortest / 2 - 4;
    final ringWidth = math.max(28, shortest * .175).toDouble();
    final ringRadius = outerRadius - ringWidth / 2;
    final ringInnerRadius = outerRadius - ringWidth;
    final innerRadius = math
        .max(22, ringInnerRadius - shortest * .035)
        .toDouble();
    final wheelRect = Rect.fromCircle(center: center, radius: ringRadius);

    canvas.drawCircle(
      center,
      outerRadius + 2,
      Paint()
        ..color = Colors.black.withValues(alpha: .36)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawCircle(
      center,
      ringRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..shader = const SweepGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
          stops: [0, 1 / 6, 2 / 6, 3 / 6, 4 / 6, 5 / 6, 1],
          transform: GradientRotation(-math.pi / 2),
        ).createShader(wheelRect),
    );
    canvas.drawCircle(
      center,
      outerRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: .2),
    );
    canvas.drawCircle(
      center,
      ringInnerRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.black.withValues(alpha: .5),
    );

    _paintSaturationValueDisc(canvas, center, innerRadius);
    _paintHueMarkers(canvas, center, ringRadius, shortest);
    _paintSaturationValueMarker(canvas, center, innerRadius, shortest);
  }

  void _paintSaturationValueDisc(Canvas canvas, Offset center, double radius) {
    const divisions = 24;
    final positions = <Offset>[];
    final colors = <Color>[];
    final indices = <int>[];
    for (var row = 0; row <= divisions; row++) {
      final squareY = -1 + row * 2 / divisions;
      final value = (1 - row / divisions).clamp(0.0, 1.0);
      for (var column = 0; column <= divisions; column++) {
        final squareX = -1 + column * 2 / divisions;
        final saturation = (column / divisions).clamp(0.0, 1.0);
        final mapped = PenColorPickerMath._squareToDisc(
          Offset(squareX, squareY),
        );
        positions.add(center + mapped * radius);
        colors.add(
          HSVColor.fromAHSV(
            1,
            PenColorPickerMath.normalizeHue(color.hue),
            saturation,
            value,
          ).toColor(),
        );
      }
    }
    for (var row = 0; row < divisions; row++) {
      for (var column = 0; column < divisions; column++) {
        final topLeft = row * (divisions + 1) + column;
        final topRight = topLeft + 1;
        final bottomLeft = topLeft + divisions + 1;
        final bottomRight = bottomLeft + 1;
        indices.addAll([
          topLeft,
          topRight,
          bottomRight,
          topLeft,
          bottomRight,
          bottomLeft,
        ]);
      }
    }
    final vertices = ui.Vertices(
      ui.VertexMode.triangles,
      positions,
      colors: colors,
      indices: indices,
    );
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawVertices(vertices, BlendMode.dst, Paint()..isAntiAlias = true);

    final guidePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: .075);
    for (final fraction in const [.25, .5, .75]) {
      canvas.drawCircle(center, radius * fraction, guidePaint);
    }
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      guidePaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      guidePaint,
    );
    canvas.restore();
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: .25),
    );
  }

  void _paintHueMarkers(
    Canvas canvas,
    Offset center,
    double radius,
    double size,
  ) {
    final selected = _pointOnRing(center, radius, color.hue);
    final oppositeHue = PenColorPickerMath.normalizeHue(color.hue + 180);
    final opposite = _pointOnRing(center, radius, oppositeHue);
    _paintMarker(
      canvas,
      opposite,
      HSVColor.fromAHSV(1, oppositeHue, 1, 1).toColor(),
      math.max(5, size * .016),
      secondary: true,
    );
    _paintMarker(
      canvas,
      selected,
      HSVColor.fromAHSV(1, color.hue, 1, 1).toColor(),
      math.max(8, size * .025),
    );
  }

  void _paintSaturationValueMarker(
    Canvas canvas,
    Offset center,
    double radius,
    double size,
  ) {
    final relative = PenColorPickerMath.pointForSaturationValue(
      saturation: color.saturation,
      value: color.value,
      radius: radius,
    );
    _paintMarker(
      canvas,
      center + relative,
      color.toColor(),
      math.max(7, size * .021),
    );
  }

  static Offset _pointOnRing(Offset center, double radius, double hue) {
    final angle = (PenColorPickerMath.normalizeHue(hue) - 90) * math.pi / 180;
    return center + Offset(math.cos(angle), math.sin(angle)) * radius;
  }

  static void _paintMarker(
    Canvas canvas,
    Offset center,
    Color fill,
    double radius, {
    bool secondary = false,
  }) {
    canvas.drawCircle(
      center + const Offset(0, 1.5),
      radius + 2,
      Paint()
        ..color = Colors.black.withValues(alpha: secondary ? .3 : .55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(center, radius, Paint()..color = fill);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = secondary ? 1.5 : 2.5
        ..color = Colors.white.withValues(alpha: secondary ? .72 : .95),
    );
  }

  @override
  bool shouldRepaint(_PenColorWheelPainter oldDelegate) =>
      oldDelegate.color != color;
}
