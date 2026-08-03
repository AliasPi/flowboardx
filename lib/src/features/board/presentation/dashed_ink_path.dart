import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// A bounded, defensive representation of a dashed polyline.
///
/// Ink is untrusted render input: it can be live pointer data, recovered JSON,
/// or an object-local annotation transformed by a user resize.  The builder
/// therefore never forwards non-finite/extreme coordinates to the engine and
/// has a hard command budget.  This is especially important on Windows where
/// an unbounded dash loop blocks the raster thread instead of producing a Dart
/// exception.
@immutable
final class DashedInkPath {
  const DashedInkPath({
    required this.path,
    required this.commandCount,
    required this.wasTruncated,
  });

  final Path path;
  final int commandCount;
  final bool wasTruncated;
}

final class DashedInkPathBuilder {
  const DashedInkPathBuilder._();

  /// Enough detail for a long 3x3 board stroke while putting a strict upper
  /// bound on work performed in a single paint call.
  static const int maxPathCommands = 32768;

  /// The board itself is only a few thousand logical pixels across.  Values
  /// beyond this limit are corrupted input or an invalid object transform and
  /// are unsafe to pass to Skia/Impeller.
  static const double maxCoordinateMagnitude = 10000000;

  static const double _progressEpsilon = 1e-7;

  static DashedInkPath build({
    required Iterable<Offset> points,
    required double dashLength,
    required double gapLength,
  }) => buildMapped<Offset>(
    points: points,
    xOf: _offsetX,
    yOf: _offsetY,
    dashLength: dashLength,
    gapLength: gapLength,
  );

  /// Builds a dashed path without first materialising an Offset per source
  /// point.
  ///
  /// Live and persisted ink already store primitive x/y coordinates. The old
  /// `points.map((p) => Offset(...))` path allocated once per sample, while its
  /// vector arithmetic then allocated several more Offsets per generated dash.
  /// Dashed strokes are often long, so those temporary objects caused frequent
  /// GC pauses on the same frame budget as live handwriting.
  static DashedInkPath buildMapped<P>({
    required Iterable<P> points,
    required double Function(P point) xOf,
    required double Function(P point) yOf,
    required double dashLength,
    required double gapLength,
    double xScale = 1,
    double yScale = 1,
  }) {
    final path = Path();
    if (!dashLength.isFinite ||
        !gapLength.isFinite ||
        !xScale.isFinite ||
        !yScale.isFinite ||
        dashLength <= _progressEpsilon ||
        gapLength <= _progressEpsilon ||
        xScale == 0 ||
        yScale == 0) {
      return DashedInkPath(path: path, commandCount: 0, wasTruncated: false);
    }

    final patternLength = dashLength + gapLength;
    if (!patternLength.isFinite || patternLength <= _progressEpsilon) {
      return DashedInkPath(path: path, commandCount: 0, wasTruncated: false);
    }

    double? previousX;
    double? previousY;
    var patternOffset = 0.0;
    var drawing = true;
    var continuingDash = false;
    var commandCount = 0;
    var truncated = false;

    for (final point in points) {
      final endX = xOf(point) * xScale;
      final endY = yOf(point) * yScale;
      if (!_isRenderableCoordinates(endX, endY)) {
        // Do not bridge over a corrupt sample.  A later valid run starts with
        // a fresh dash, which is deterministic and visually unsurprising.
        previousX = null;
        previousY = null;
        patternOffset = 0;
        drawing = true;
        continuingDash = false;
        continue;
      }
      final startX = previousX;
      final startY = previousY;
      previousX = endX;
      previousY = endY;
      if (startX == null || startY == null) continue;

      final vectorX = endX - startX;
      final vectorY = endY - startY;
      final length = math.sqrt(vectorX * vectorX + vectorY * vectorY);
      if (!length.isFinite || length <= _progressEpsilon) continue;
      final unitX = vectorX / length;
      final unitY = vectorY / length;
      if (!_isRenderableCoordinates(unitX, unitY)) continue;

      var traversed = 0.0;
      while (traversed < length) {
        if (commandCount >= maxPathCommands) {
          truncated = true;
          break;
        }

        final phaseRemaining = drawing
            ? dashLength - patternOffset
            : patternLength - patternOffset;
        final segmentRemaining = length - traversed;
        if (!phaseRemaining.isFinite || !segmentRemaining.isFinite) {
          truncated = true;
          break;
        }
        if (segmentRemaining <= _progressEpsilon) {
          // Treat a sub-pixel floating-point remainder as consumed.  It is not
          // a truncation and the next source segment can still be rendered.
          traversed = length;
          break;
        }

        // Rounding at an exact pattern boundary used to produce a zero-sized
        // step here.  Since neither cursor advanced, the raster thread entered
        // an endless loop.  Snap the state across that boundary explicitly.
        if (phaseRemaining <= _progressEpsilon) {
          if (drawing) {
            drawing = false;
            patternOffset = dashLength;
            continuingDash = false;
          } else {
            drawing = true;
            patternOffset = 0;
          }
          continue;
        }

        final step = math.min(phaseRemaining, segmentRemaining);
        final nextTraversed = traversed + step;
        if (!step.isFinite ||
            step <= _progressEpsilon ||
            nextTraversed <= traversed) {
          // Always leave the loop if IEEE-754 precision can no longer advance
          // the cursor.  The next polyline segment remains renderable; only
          // this unrepresentably small tail is discarded.
          traversed = length;
          break;
        }

        if (drawing) {
          final fromX = startX + unitX * traversed;
          final fromY = startY + unitY * traversed;
          final toX = startX + unitX * nextTraversed;
          final toY = startY + unitY * nextTraversed;
          if (!_isRenderableCoordinates(fromX, fromY) ||
              !_isRenderableCoordinates(toX, toY)) {
            continuingDash = false;
          } else {
            if (!continuingDash) path.moveTo(fromX, fromY);
            path.lineTo(toX, toY);
            continuingDash = true;
            commandCount++;
          }
        } else {
          continuingDash = false;
        }

        traversed = nextTraversed;
        patternOffset += step;
        if (drawing && patternOffset >= dashLength - _progressEpsilon) {
          patternOffset = dashLength;
          drawing = false;
          continuingDash = false;
        } else if (!drawing &&
            patternOffset >= patternLength - _progressEpsilon) {
          patternOffset = 0;
          drawing = true;
        }
      }
      if (truncated) break;
    }

    return DashedInkPath(
      path: path,
      commandCount: commandCount,
      wasTruncated: truncated,
    );
  }

  static double _offsetX(Offset point) => point.dx;

  static double _offsetY(Offset point) => point.dy;

  static bool _isRenderableCoordinates(double x, double y) =>
      x.isFinite &&
      y.isFinite &&
      x.abs() <= maxCoordinateMagnitude &&
      y.abs() <= maxCoordinateMagnitude;
}
