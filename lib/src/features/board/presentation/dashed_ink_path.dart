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
  }) {
    final path = Path();
    if (!dashLength.isFinite ||
        !gapLength.isFinite ||
        dashLength <= _progressEpsilon ||
        gapLength <= _progressEpsilon) {
      return DashedInkPath(path: path, commandCount: 0, wasTruncated: false);
    }

    final patternLength = dashLength + gapLength;
    if (!patternLength.isFinite || patternLength <= _progressEpsilon) {
      return DashedInkPath(path: path, commandCount: 0, wasTruncated: false);
    }

    Offset? previous;
    var patternOffset = 0.0;
    var drawing = true;
    var continuingDash = false;
    var commandCount = 0;
    var truncated = false;

    for (final end in points) {
      if (!_isRenderable(end)) {
        // Do not bridge over a corrupt sample.  A later valid run starts with
        // a fresh dash, which is deterministic and visually unsurprising.
        previous = null;
        patternOffset = 0;
        drawing = true;
        continuingDash = false;
        continue;
      }
      final start = previous;
      previous = end;
      if (start == null) continue;

      final vector = end - start;
      final length = vector.distance;
      if (!length.isFinite || length <= _progressEpsilon) continue;
      final unit = vector / length;
      if (!_isRenderable(unit)) continue;

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
          final from = start + unit * traversed;
          final to = start + unit * nextTraversed;
          if (!_isRenderable(from) || !_isRenderable(to)) {
            continuingDash = false;
          } else {
            if (!continuingDash) path.moveTo(from.dx, from.dy);
            path.lineTo(to.dx, to.dy);
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

  static bool _isRenderable(Offset point) =>
      point.dx.isFinite &&
      point.dy.isFinite &&
      point.dx.abs() <= maxCoordinateMagnitude &&
      point.dy.abs() <= maxCoordinateMagnitude;
}
