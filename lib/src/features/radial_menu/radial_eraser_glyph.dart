import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Scalable, theme-aware eraser glyph used by the radial pen-type selector.
///
/// The silhouette deliberately depicts a classic two-part block eraser rather
/// than a brush or cleaning tool. A short interrupted ink line underneath makes
/// the action unambiguous even at compact smartboard menu sizes.
abstract final class RadialEraserGlyph {
  static void paint(
    Canvas canvas, {
    required Offset center,
    required double size,
    required Color color,
  }) {
    if (!size.isFinite || size <= 0 || color.a <= 0) return;

    final unit = size / 28;

    final erasedInk = Paint()
      ..color = color.withValues(alpha: color.a * .74)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.9 * unit;
    final trailY = center.dy + 9.8 * unit;
    canvas
      ..drawLine(
        Offset(center.dx - 11 * unit, trailY),
        Offset(center.dx - 4.5 * unit, trailY),
        erasedInk,
      )
      ..drawLine(
        Offset(center.dx + 4.5 * unit, trailY),
        Offset(center.dx + 11 * unit, trailY),
        erasedInk,
      );

    canvas.save();
    canvas.translate(center.dx, center.dy - .8 * unit);
    canvas.rotate(-math.pi / 4);

    final body = bodyPath(size);
    canvas.drawPath(
      body,
      Paint()
        ..color = color.withValues(alpha: color.a * .15)
        ..style = PaintingStyle.fill,
    );

    // The solid leading section is the rubber; the outlined rear section reads
    // as its paper sleeve. Both use the supplied menu-state color.
    canvas.save();
    canvas.clipPath(body);
    canvas.drawRect(
      Rect.fromLTRB(3.1 * unit, -7 * unit, 11 * unit, 7 * unit),
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    canvas.restore();

    final outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 1.75 * unit;
    canvas
      ..drawPath(body, outline)
      ..drawLine(
        Offset(3.1 * unit, -5.25 * unit),
        Offset(3.1 * unit, 5.25 * unit),
        outline..strokeWidth = 1.35 * unit,
      )
      ..drawLine(
        Offset(-6.4 * unit, -2.25 * unit),
        Offset(-1.4 * unit, -2.25 * unit),
        Paint()
          ..color = color.withValues(alpha: color.a * .7)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 1.3 * unit,
      );

    canvas.restore();
  }

  /// Local-coordinate body geometry, exposed to keep scale regressions
  /// testable without relying on platform-specific font glyph rendering.
  @visibleForTesting
  static Path bodyPath(double size) {
    final unit = size / 28;
    return Path()
      ..moveTo(-7.8 * unit, -6 * unit)
      ..lineTo(7.2 * unit, -6 * unit)
      ..quadraticBezierTo(10 * unit, -6 * unit, 10 * unit, -3.2 * unit)
      ..lineTo(10 * unit, 3.2 * unit)
      ..quadraticBezierTo(10 * unit, 6 * unit, 7.2 * unit, 6 * unit)
      ..lineTo(-7.8 * unit, 6 * unit)
      ..quadraticBezierTo(-10 * unit, 6 * unit, -10 * unit, 3.8 * unit)
      ..lineTo(-10 * unit, -3.8 * unit)
      ..quadraticBezierTo(-10 * unit, -6 * unit, -7.8 * unit, -6 * unit)
      ..close();
  }
}
