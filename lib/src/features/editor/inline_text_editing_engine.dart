import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../domain/model/board_object.dart';
import 'text_object_layout.dart';

/// One visible, non-whitespace token and its bounds inside a [TextObject].
final class InlineTextToken {
  const InlineTextToken({
    required this.start,
    required this.end,
    required this.bounds,
  });

  final int start;
  final int end;
  final Rect bounds;
}

/// Deterministic pen-editing rules for converted text.
///
/// A nearly horizontal stroke through one or more words removes them. Any
/// other ink is sent to the offline handwriting recognizer and replaces the
/// word under the ink (or is inserted at the nearest caret when no word was
/// hit). Coordinates are local to the text object's top-left corner.
abstract final class InlineTextEditingEngine {
  static List<InlineTextToken> tokensFor(TextObject value) {
    if (value.text.isEmpty) return const <InlineTextToken>[];
    final painter = _painter(value);
    final origin = _painterOrigin(value, painter);
    final tokens = <InlineTextToken>[];
    for (final match in RegExp(r'\S+').allMatches(value.text)) {
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: match.start, extentOffset: match.end),
      );
      Rect? bounds;
      for (final box in boxes) {
        final rect = Rect.fromLTRB(
          box.left,
          box.top,
          box.right,
          box.bottom,
        ).shift(origin);
        bounds = bounds == null ? rect : bounds.expandToInclude(rect);
      }
      if (bounds != null && !bounds.isEmpty) {
        tokens.add(
          InlineTextToken(start: match.start, end: match.end, bounds: bounds),
        );
      }
    }
    painter.dispose();
    return List<InlineTextToken>.unmodifiable(tokens);
  }

  static bool isStrikeThrough(TextObject value, List<Offset> points) {
    if (points.length < 2 || value.text.trim().isEmpty) return false;
    final bounds = _pointsBounds(points);
    if (bounds.width < math.max(36, value.fontSize * 1.15) ||
        bounds.height > math.max(10, value.fontSize * .48)) {
      return false;
    }
    final displacement = (points.last - points.first).distance;
    var pathLength = 0.0;
    var reversals = 0;
    var lastDirection = 0;
    for (var index = 1; index < points.length; index++) {
      final delta = points[index] - points[index - 1];
      pathLength += delta.distance;
      final direction = delta.dx.abs() < .5 ? 0 : delta.dx.sign.toInt();
      if (direction != 0 && lastDirection != 0 && direction != lastDirection) {
        reversals++;
      }
      if (direction != 0) lastDirection = direction;
    }
    if (displacement < bounds.width * .72 ||
        pathLength > bounds.width * 1.55 ||
        reversals > 1) {
      return false;
    }
    final hits = _tokensHitByStroke(value, points);
    return hits.any((token) {
      final overlap = math.max(
        0,
        math.min(bounds.right, token.bounds.right) -
            math.max(bounds.left, token.bounds.left),
      );
      return overlap >= token.bounds.width * .65;
    });
  }

  static String deleteAtStroke(TextObject value, List<Offset> points) {
    if (!isStrikeThrough(value, points)) return value.text;
    final hits = _tokensHitByStroke(value, points);
    if (hits.isEmpty) return value.text;
    var result = value.text;
    for (final token in hits.reversed) {
      var start = token.start;
      var end = token.end;
      while (end < result.length &&
          result[end] != '\n' &&
          _isHorizontalWhitespace(result.codeUnitAt(end))) {
        end++;
      }
      if (end == token.end) {
        while (start > 0 &&
            result[start - 1] != '\n' &&
            _isHorizontalWhitespace(result.codeUnitAt(start - 1))) {
          start--;
        }
      }
      result = result.replaceRange(start, end, '');
    }
    return result
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim())
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  static String replaceOrInsert(
    TextObject value, {
    required List<Offset> inkPoints,
    required String recognizedText,
  }) {
    final replacement = recognizedText
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();
    if (replacement.isEmpty || inkPoints.isEmpty) return value.text;
    if (value.text.isEmpty) return replacement;

    if (isAppendAtEnd(value, inkPoints)) {
      final separator = RegExp(r'\s$').hasMatch(value.text) ? '' : ' ';
      return '${value.text}$separator$replacement';
    }

    final inkBounds = _pointsBounds(inkPoints).inflate(value.fontSize * .22);
    final tokens = tokensFor(value);
    InlineTextToken? best;
    var bestScore = 0.0;
    for (final token in tokens) {
      final overlap = token.bounds.intersect(inkBounds);
      final overlapArea = overlap.isEmpty
          ? 0.0
          : overlap.width * overlap.height;
      final tokenArea = math.max(1, token.bounds.width * token.bounds.height);
      final containsCenter = token.bounds
          .inflate(value.fontSize * .35)
          .contains(inkBounds.center);
      final score = overlapArea / tokenArea + (containsCenter ? .65 : 0);
      if (score > bestScore) {
        best = token;
        bestScore = score;
      }
    }
    if (best != null && bestScore >= .18) {
      return value.text.replaceRange(best.start, best.end, replacement);
    }

    final painter = _painter(value);
    final origin = _painterOrigin(value, painter);
    final caret = painter
        .getPositionForOffset(inkBounds.center - origin)
        .offset
        .clamp(0, value.text.length);
    painter.dispose();
    final before = value.text.substring(0, caret);
    final after = value.text.substring(caret);
    final leadingSpace =
        before.isNotEmpty && !_isBoundary(before.codeUnitAt(before.length - 1))
        ? ' '
        : '';
    final trailingSpace = after.isNotEmpty && !_isBoundary(after.codeUnitAt(0))
        ? ' '
        : '';
    return '$before$leadingSpace$replacement$trailingSpace$after';
  }

  /// True when handwriting starts clearly to the right of the final caret.
  /// This creates an explicit, keyboard-free append zone without making a
  /// correction over the final word accidentally replace the whole word.
  static bool isAppendAtEnd(TextObject value, List<Offset> inkPoints) {
    if (value.text.isEmpty || inkPoints.isEmpty) return false;
    final painter = _painter(value);
    final origin = _painterOrigin(value, painter);
    final caret =
        painter.getOffsetForCaret(
          TextPosition(offset: value.text.length),
          Rect.zero,
        ) +
        origin;
    painter.dispose();
    final bounds = _pointsBounds(inkPoints);
    final verticalTolerance = math.max(22, value.fontSize * 1.25);
    final startsAfterCaret =
        bounds.left >= caret.dx + math.max(5, value.fontSize * .16);
    final onFinalLine =
        (bounds.center.dy - (caret.dy + value.fontSize * .45)).abs() <=
        verticalTolerance;
    return startsAfterCaret && onFinalLine;
  }

  static List<InlineTextToken> _tokensHitByStroke(
    TextObject value,
    List<Offset> points,
  ) {
    if (points.length < 2) return const <InlineTextToken>[];
    final strokeBounds = _pointsBounds(
      points,
    ).inflate(math.max(3, value.fontSize * .12));
    final meanY =
        points.fold<double>(0, (sum, point) => sum + point.dy) / points.length;
    return tokensFor(value)
        .where(
          (token) =>
              token.bounds
                  .inflate(value.fontSize * .12)
                  .overlaps(strokeBounds) &&
              meanY >= token.bounds.top - value.fontSize * .2 &&
              meanY <= token.bounds.bottom + value.fontSize * .2,
        )
        .toList(growable: false);
  }

  static TextPainter _painter(TextObject value) {
    final insets = TextObjectLayout.contentInsetsFor(value);
    return TextObjectLayout.createPainter(
      value,
    )..layout(maxWidth: math.max(1, value.transform.width - insets.horizontal));
  }

  static Offset _painterOrigin(TextObject value, TextPainter painter) {
    final insets = TextObjectLayout.contentInsetsFor(value);
    final contentWidth = math.max(1, value.transform.width - insets.horizontal);
    final x = switch (value.alignment) {
      BoardTextAlign.left => insets.left,
      BoardTextAlign.center =>
        insets.left + contentWidth / 2 - painter.width / 2,
      BoardTextAlign.right =>
        value.transform.width - insets.right - painter.width,
    };
    return Offset(x, insets.top);
  }

  static Rect _pointsBounds(List<Offset> points) {
    var left = points.first.dx;
    var right = left;
    var top = points.first.dy;
    var bottom = top;
    for (final point in points.skip(1)) {
      left = math.min(left, point.dx);
      right = math.max(right, point.dx);
      top = math.min(top, point.dy);
      bottom = math.max(bottom, point.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  static bool _isHorizontalWhitespace(int unit) => unit == 0x20 || unit == 0x09;

  static bool _isBoundary(int unit) =>
      _isHorizontalWhitespace(unit) || unit == 0x0A;
}
