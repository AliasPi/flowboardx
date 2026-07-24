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

  static TextStyle styleFor(TextObject text) => TextStyle(
    inherit: false,
    color: Color(text.colorArgb),
    fontSize: text.fontSize,
    fontFamily: 'sans-serif',
    fontFamilyFallback: const <String>['Roboto', 'Arial'],
    fontWeight: text.bold ? FontWeight.bold : FontWeight.normal,
    fontStyle: text.italic ? FontStyle.italic : FontStyle.normal,
    letterSpacing: 0,
    wordSpacing: 0,
    height: 1.18,
    leadingDistribution: TextLeadingDistribution.even,
    decoration: TextDecoration.none,
  );

  static TextAlign textAlignFor(BoardTextAlign alignment) =>
      switch (alignment) {
        BoardTextAlign.left => TextAlign.left,
        BoardTextAlign.center => TextAlign.center,
        BoardTextAlign.right => TextAlign.right,
      };

  /// Logical padding inside the persisted object frame.
  ///
  /// Font-relative padding protects italic overhang, raster rounding and font
  /// fallback differences when a document moves between Android and desktop.
  static EdgeInsets contentInsetsFor(TextObject value) {
    final fontSize = value.fontSize.isFinite && value.fontSize > 0
        ? value.fontSize
        : 28.0;
    final horizontal = math.max(6.0, fontSize * (value.italic ? .2 : .14));
    final vertical = math.max(4.0, fontSize * .1);
    return EdgeInsets.symmetric(horizontal: horizontal, vertical: vertical);
  }

  static Rect contentRectFor(TextObject value, Size objectSize) {
    final insets = contentInsetsFor(value);
    return Rect.fromLTWH(
      insets.left,
      insets.top,
      math.max(1, objectSize.width - insets.horizontal),
      math.max(1, objectSize.height - insets.vertical),
    );
  }

  /// Creates the canonical, theme-independent paragraph used everywhere.
  ///
  /// Callers own the returned painter and must dispose it.
  static TextPainter createPainter(TextObject value, {String? text}) =>
      TextPainter(
        text: TextSpan(text: text ?? value.text, style: styleFor(value)),
        textDirection: TextDirection.ltr,
        textAlign: textAlignFor(value.alignment),
        maxLines: null,
        textScaler: TextScaler.noScaling,
        textWidthBasis: TextWidthBasis.longestLine,
      );

  /// Exact unwrapped object width, including the canonical content insets.
  static double preferredWidth(TextObject value) {
    final content = value.text.isEmpty ? ' ' : value.text;
    final painter = createPainter(value, text: content)..layout();
    final width =
        painter.maxIntrinsicWidth + contentInsetsFor(value).horizontal;
    painter.dispose();
    return math.max(minimumWidth, width).ceilToDouble();
  }

  /// Upgrades a persisted frame from the legacy unpadded renderer.
  ///
  /// The former frame width becomes the new content width, so existing line
  /// breaks cannot become narrower. Height is then measured with the canonical
  /// paragraph. This operation is monotonic and idempotent: position,
  /// orientation and mirroring are preserved, and a current frame is returned
  /// unchanged.
  static TextObject upgradeLegacyFrame(TextObject value) {
    if (value.textLayoutVersion >= TextObject.currentLayoutVersion) {
      return value;
    }
    final insets = contentInsetsFor(value);
    final width = math
        .max(minimumWidth, value.transform.width + insets.horizontal)
        .ceilToDouble();
    final content = value.text.isEmpty ? ' ' : value.text;
    final painter = createPainter(value, text: content)
      ..layout(maxWidth: math.max(1, width - insets.horizontal));
    final height = math
        .max(
          math.max(minimumHeight, value.transform.height),
          painter.height + insets.vertical,
        )
        .ceilToDouble();
    painter.dispose();
    return value.copyWith(
      transform: ObjectTransform(
        x: value.transform.x,
        y: value.transform.y,
        width: width,
        height: height,
        rotationRadians: value.transform.rotationRadians,
        flipX: value.transform.flipX,
        flipY: value.transform.flipY,
      ),
      textLayoutVersion: TextObject.currentLayoutVersion,
    );
  }

  /// Returns a finite canvas transform fitted to [value]. Long text wraps at
  /// [maximumWidth], while explicit line breaks are preserved.
  static ObjectTransform fit({
    required TextObject value,
    double? x,
    double? y,
    double maximumWidth = defaultMaximumWidth,
    double minimumObjectWidth = minimumWidth,
  }) {
    final safeMaximum = maximumWidth.isFinite
        ? math.max(minimumWidth, maximumWidth)
        : defaultMaximumWidth;
    final safeMinimum = minimumObjectWidth.isFinite
        ? minimumObjectWidth.clamp(minimumWidth, safeMaximum)
        : minimumWidth;
    final content = value.text.isEmpty ? ' ' : value.text;
    final insets = contentInsetsFor(value);
    final intrinsic = createPainter(value, text: content)..layout();
    final width = (intrinsic.maxIntrinsicWidth + insets.horizontal)
        .clamp(safeMinimum, safeMaximum)
        .ceilToDouble();
    intrinsic.dispose();

    // A second painter is required after disposing the intrinsic measurement.
    // It reflects wrapping inside the exact content rectangle used on canvas.
    final wrapped = createPainter(value, text: content)
      ..layout(maxWidth: math.max(1, width - insets.horizontal));
    final height = math.max(
      minimumHeight,
      (wrapped.height + insets.vertical).ceilToDouble(),
    );
    wrapped.dispose();
    return ObjectTransform(
      x: _finiteOr(x, value.transform.x),
      y: _finiteOr(y, value.transform.y),
      width: width,
      height: height,
      rotationRadians: value.transform.rotationRadians,
      flipX: value.transform.flipX,
      flipY: value.transform.flipY,
    );
  }

  static double _finiteOr(double? candidate, double fallback) =>
      candidate != null && candidate.isFinite ? candidate : fallback;
}
