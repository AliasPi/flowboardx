import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../domain/model/board_object.dart';
import '../../domain/model/geometry.dart';

/// Measures board text with the same typography that is used by the canvas.
///
/// Keeping the measurement in one place prevents OCR and later edits from
/// retaining an unrelated handwriting rectangle or clipping multiline text.
abstract final class TextObjectLayout {
  static const double minimumWidth = 72;
  static const double minimumHeight = 40;
  static const double defaultMaximumWidth = 760;
  static const double safetyInset = 2;

  static TextStyle styleFor(TextObject text) => TextStyle(
    color: Color(text.colorArgb),
    fontSize: text.fontSize,
    fontWeight: text.bold ? FontWeight.bold : FontWeight.normal,
    fontStyle: text.italic ? FontStyle.italic : FontStyle.normal,
  );

  static TextAlign textAlignFor(BoardTextAlign alignment) =>
      switch (alignment) {
        BoardTextAlign.left => TextAlign.left,
        BoardTextAlign.center => TextAlign.center,
        BoardTextAlign.right => TextAlign.right,
      };

  /// Returns a finite canvas transform fitted to [value]. Long text wraps at
  /// [maximumWidth], while explicit line breaks are preserved.
  static ObjectTransform fit({
    required TextObject value,
    double? x,
    double? y,
    double maximumWidth = defaultMaximumWidth,
  }) {
    final safeMaximum = maximumWidth.isFinite
        ? math.max(minimumWidth, maximumWidth)
        : defaultMaximumWidth;
    final content = value.text.isEmpty ? ' ' : value.text;
    final intrinsic = TextPainter(
      text: TextSpan(text: content, style: styleFor(value)),
      textDirection: TextDirection.ltr,
      textAlign: textAlignFor(value.alignment),
      maxLines: null,
      textWidthBasis: TextWidthBasis.longestLine,
    )..layout();
    final width = (intrinsic.maxIntrinsicWidth + safetyInset)
        .clamp(minimumWidth, safeMaximum)
        .ceilToDouble();
    intrinsic.dispose();

    // A second painter is required after disposing the intrinsic measurement.
    // It reflects wrapping at the chosen object width.
    final wrapped = TextPainter(
      text: TextSpan(text: content, style: styleFor(value)),
      textDirection: TextDirection.ltr,
      textAlign: textAlignFor(value.alignment),
      maxLines: null,
      textWidthBasis: TextWidthBasis.longestLine,
    )..layout(maxWidth: width);
    final height = math.max(
      minimumHeight,
      (wrapped.height + safetyInset).ceilToDouble(),
    );
    wrapped.dispose();
    return ObjectTransform(
      x: _finiteOr(x, value.transform.x),
      y: _finiteOr(y, value.transform.y),
      width: width,
      height: height,
    );
  }

  static double _finiteOr(double? candidate, double fallback) =>
      candidate != null && candidate.isFinite ? candidate : fallback;
}
