import 'dart:math' as math;

import '../../../domain/model/geometry.dart';
import '../../../domain/model/ink.dart';

typedef InkPointProjection = Vec2 Function(InkPoint point);
typedef ErasedStrokeIdFactory =
    String Function(String sourceStrokeId, int fragmentIndex);

/// Result of subtracting one swept circular eraser footprint from a stroke.
///
/// The returned fragments retain every persisted style/author attribute of the
/// source stroke. The first surviving fragment keeps the source ID so existing
/// selections and groups remain stable; additional fragments receive IDs from
/// [ErasedStrokeIdFactory].
final class InkStrokeEraseResult {
  const InkStrokeEraseResult({required this.changed, required this.fragments});

  final bool changed;
  final List<InkStroke> fragments;
}

/// Geometrically subtracts a capsule from a sampled ink polyline.
///
/// Unlike whole-stroke hit testing this calculates the exact entry and exit
/// parameters along every sampled segment. Sparse, fast pen strokes therefore
/// split at the eraser boundary instead of disappearing completely or leaving
/// large unerased gaps.
final class InkStrokeEraser {
  const InkStrokeEraser._();

  static const double _parameterEpsilon = 1e-8;
  static const double _positionEpsilonSquared = 1e-12;

  static InkStrokeEraseResult eraseCapsule({
    required InkStroke stroke,
    required Vec2 eraserStart,
    required Vec2 eraserEnd,
    required double radius,
    required ErasedStrokeIdFactory idFactory,
    InkPointProjection? project,
  }) {
    if (stroke.points.isEmpty ||
        !_isFinite(eraserStart) ||
        !_isFinite(eraserEnd) ||
        !radius.isFinite ||
        radius <= 0) {
      return InkStrokeEraseResult(
        changed: false,
        fragments: <InkStroke>[stroke],
      );
    }
    final projection = project ?? (InkPoint point) => point.position;
    final projected = <Vec2>[];
    for (final point in stroke.points) {
      final value = projection(point);
      if (!_isFinite(value)) {
        return InkStrokeEraseResult(
          changed: false,
          fragments: <InkStroke>[stroke],
        );
      }
      projected.add(value);
    }

    if (stroke.points.length == 1) {
      final erased =
          _pointToSegmentDistanceSquared(
            projected.single,
            eraserStart,
            eraserEnd,
          ) <=
          radius * radius;
      return InkStrokeEraseResult(
        changed: erased,
        fragments: erased ? const <InkStroke>[] : <InkStroke>[stroke],
      );
    }

    final retained = <List<InkPoint>>[];
    List<InkPoint>? active;
    var removedAny = false;

    for (
      var segmentIndex = 0;
      segmentIndex < stroke.points.length - 1;
      segmentIndex++
    ) {
      final sourceStart = stroke.points[segmentIndex];
      final sourceEnd = stroke.points[segmentIndex + 1];
      final keptIntervals = _outsideIntervals(
        projected[segmentIndex],
        projected[segmentIndex + 1],
        eraserStart,
        eraserEnd,
        radius,
      );
      if (keptIntervals.length != 1 ||
          keptIntervals.single.start > _parameterEpsilon ||
          keptIntervals.single.end < 1 - _parameterEpsilon) {
        removedAny = true;
      }

      for (
        var intervalIndex = 0;
        intervalIndex < keptIntervals.length;
        intervalIndex++
      ) {
        final interval = keptIntervals[intervalIndex];
        if (interval.end - interval.start <= _parameterEpsilon) continue;
        final beginsAtSegmentStart = interval.start <= _parameterEpsilon;
        if (active == null ||
            !beginsAtSegmentStart ||
            !_samePoint(active.last, sourceStart)) {
          active = <InkPoint>[];
          retained.add(active);
        }
        _appendDistinct(
          active,
          interval.start <= _parameterEpsilon
              ? sourceStart
              : _interpolatePoint(sourceStart, sourceEnd, interval.start),
        );
        _appendDistinct(
          active,
          interval.end >= 1 - _parameterEpsilon
              ? sourceEnd
              : _interpolatePoint(sourceStart, sourceEnd, interval.end),
        );

        if (interval.end < 1 - _parameterEpsilon) active = null;
      }
      if (keptIntervals.isEmpty ||
          keptIntervals.last.end < 1 - _parameterEpsilon) {
        active = null;
      }
    }

    if (!removedAny) {
      return InkStrokeEraseResult(
        changed: false,
        fragments: <InkStroke>[stroke],
      );
    }

    final usable = retained.where(_hasVisibleExtent).toList(growable: false);
    final fragments = <InkStroke>[];
    for (var index = 0; index < usable.length; index++) {
      fragments.add(
        stroke.copyWith(
          id: index == 0 ? stroke.id : idFactory(stroke.id, index),
          points: usable[index],
        ),
      );
    }
    return InkStrokeEraseResult(changed: true, fragments: fragments);
  }

  /// Returns the portions of `strokeStart → strokeEnd` outside the eraser
  /// capsule. The squared distance to a finite segment is piecewise quadratic:
  /// the projection breakpoints and quadratic roots provide exact boundaries.
  static List<_ParameterInterval> _outsideIntervals(
    Vec2 strokeStart,
    Vec2 strokeEnd,
    Vec2 eraserStart,
    Vec2 eraserEnd,
    double radius,
  ) {
    final breakpoints = <double>[0, 1];
    final eraserDx = eraserEnd.x - eraserStart.x;
    final eraserDy = eraserEnd.y - eraserStart.y;
    final eraserLengthSquared = eraserDx * eraserDx + eraserDy * eraserDy;
    final strokeDx = strokeEnd.x - strokeStart.x;
    final strokeDy = strokeEnd.y - strokeStart.y;

    if (eraserLengthSquared > _positionEpsilonSquared) {
      final projectionStart =
          ((strokeStart.x - eraserStart.x) * eraserDx +
              (strokeStart.y - eraserStart.y) * eraserDy) /
          eraserLengthSquared;
      final projectionDelta =
          (strokeDx * eraserDx + strokeDy * eraserDy) / eraserLengthSquared;
      if (projectionDelta.abs() > _parameterEpsilon) {
        _addUnitBreakpoint(breakpoints, -projectionStart / projectionDelta);
        _addUnitBreakpoint(
          breakpoints,
          (1 - projectionStart) / projectionDelta,
        );
      }
    }
    breakpoints.sort();
    final projectionBreakpoints = _deduplicateParameters(breakpoints);

    final allBoundaries = <double>[...projectionBreakpoints];
    for (var index = 0; index < projectionBreakpoints.length - 1; index++) {
      final left = projectionBreakpoints[index];
      final right = projectionBreakpoints[index + 1];
      if (right - left <= _parameterEpsilon) continue;
      final middle = (left + right) / 2;
      final projectedMiddle = Vec2(
        strokeStart.x + strokeDx * middle,
        strokeStart.y + strokeDy * middle,
      );
      final coefficients = _distanceQuadratic(
        strokeStart: strokeStart,
        strokeDelta: Vec2(strokeDx, strokeDy),
        eraserStart: eraserStart,
        eraserEnd: eraserEnd,
        projectedMiddle: projectedMiddle,
        eraserLengthSquared: eraserLengthSquared,
        radiusSquared: radius * radius,
      );
      for (final root in _quadraticRoots(coefficients)) {
        if (root > left + _parameterEpsilon &&
            root < right - _parameterEpsilon) {
          allBoundaries.add(root);
        }
      }
    }

    allBoundaries.sort();
    final boundaries = _deduplicateParameters(allBoundaries);
    final outside = <_ParameterInterval>[];
    for (var index = 0; index < boundaries.length - 1; index++) {
      final start = boundaries[index];
      final end = boundaries[index + 1];
      if (end - start <= _parameterEpsilon) continue;
      final middle = (start + end) / 2;
      final point = Vec2(
        strokeStart.x + strokeDx * middle,
        strokeStart.y + strokeDy * middle,
      );
      if (_pointToSegmentDistanceSquared(point, eraserStart, eraserEnd) >
          radius * radius) {
        if (outside.isNotEmpty &&
            (outside.last.end - start).abs() <= _parameterEpsilon) {
          outside[outside.length - 1] = _ParameterInterval(
            outside.last.start,
            end,
          );
        } else {
          outside.add(_ParameterInterval(start, end));
        }
      }
    }
    return outside;
  }

  static _Quadratic _distanceQuadratic({
    required Vec2 strokeStart,
    required Vec2 strokeDelta,
    required Vec2 eraserStart,
    required Vec2 eraserEnd,
    required Vec2 projectedMiddle,
    required double eraserLengthSquared,
    required double radiusSquared,
  }) {
    if (eraserLengthSquared <= _positionEpsilonSquared) {
      return _pointDistanceQuadratic(
        strokeStart,
        strokeDelta,
        eraserStart,
        radiusSquared,
      );
    }
    final eraserDelta = eraserEnd - eraserStart;
    final projection =
        ((projectedMiddle.x - eraserStart.x) * eraserDelta.x +
            (projectedMiddle.y - eraserStart.y) * eraserDelta.y) /
        eraserLengthSquared;
    if (projection <= 0) {
      return _pointDistanceQuadratic(
        strokeStart,
        strokeDelta,
        eraserStart,
        radiusSquared,
      );
    }
    if (projection >= 1) {
      return _pointDistanceQuadratic(
        strokeStart,
        strokeDelta,
        eraserEnd,
        radiusSquared,
      );
    }

    final relative = strokeStart - eraserStart;
    final crossStart = relative.x * eraserDelta.y - relative.y * eraserDelta.x;
    final crossDelta =
        strokeDelta.x * eraserDelta.y - strokeDelta.y * eraserDelta.x;
    return _Quadratic(
      a: crossDelta * crossDelta / eraserLengthSquared,
      b: 2 * crossStart * crossDelta / eraserLengthSquared,
      c: crossStart * crossStart / eraserLengthSquared - radiusSquared,
    );
  }

  static _Quadratic _pointDistanceQuadratic(
    Vec2 strokeStart,
    Vec2 strokeDelta,
    Vec2 center,
    double radiusSquared,
  ) {
    final relative = strokeStart - center;
    return _Quadratic(
      a: strokeDelta.x * strokeDelta.x + strokeDelta.y * strokeDelta.y,
      b: 2 * (relative.x * strokeDelta.x + relative.y * strokeDelta.y),
      c: relative.x * relative.x + relative.y * relative.y - radiusSquared,
    );
  }

  static Iterable<double> _quadraticRoots(_Quadratic value) sync* {
    if (value.a.abs() <= _parameterEpsilon) {
      if (value.b.abs() > _parameterEpsilon) yield -value.c / value.b;
      return;
    }
    final discriminant = value.b * value.b - 4 * value.a * value.c;
    if (discriminant < -_parameterEpsilon) return;
    if (discriminant.abs() <= _parameterEpsilon) {
      yield -value.b / (2 * value.a);
      return;
    }
    final root = math.sqrt(math.max(0, discriminant));
    // The sign-aware form avoids catastrophic cancellation for long sparse
    // segments, which are common when a board drops intermediate pointer data.
    final q = -.5 * (value.b + (value.b < 0 ? -root : root));
    if (q.abs() <= _parameterEpsilon) {
      yield (-value.b - root) / (2 * value.a);
      yield (-value.b + root) / (2 * value.a);
    } else {
      yield q / value.a;
      yield value.c / q;
    }
  }

  static double _pointToSegmentDistanceSquared(
    Vec2 point,
    Vec2 start,
    Vec2 end,
  ) {
    final dx = end.x - start.x;
    final dy = end.y - start.y;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared <= _positionEpsilonSquared) {
      final px = point.x - start.x;
      final py = point.y - start.y;
      return px * px + py * py;
    }
    final projection =
        (((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)
            .clamp(0.0, 1.0);
    final nearestX = start.x + dx * projection;
    final nearestY = start.y + dy * projection;
    final px = point.x - nearestX;
    final py = point.y - nearestY;
    return px * px + py * py;
  }

  static InkPoint _interpolatePoint(
    InkPoint start,
    InkPoint end,
    double parameter,
  ) {
    final t = parameter.clamp(0.0, 1.0);
    double lerp(double a, double b) => a + (b - a) * t;
    return InkPoint(
      x: lerp(start.x, end.x),
      y: lerp(start.y, end.y),
      pressure: lerp(start.pressure, end.pressure).clamp(0.0, 1.0),
      timestampMicros:
          start.timestampMicros +
          ((end.timestampMicros - start.timestampMicros) * t).round(),
      tiltX: lerp(start.tiltX, end.tiltX).clamp(-1.0, 1.0),
      tiltY: lerp(start.tiltY, end.tiltY).clamp(-1.0, 1.0),
    );
  }

  static bool _hasVisibleExtent(List<InkPoint> points) {
    if (points.length < 2) return false;
    final first = points.first;
    for (var index = 1; index < points.length; index++) {
      final dx = points[index].x - first.x;
      final dy = points[index].y - first.y;
      if (dx * dx + dy * dy > _positionEpsilonSquared) return true;
    }
    return false;
  }

  static void _appendDistinct(List<InkPoint> points, InkPoint value) {
    if (points.isEmpty || !_samePoint(points.last, value)) points.add(value);
  }

  static bool _samePoint(InkPoint first, InkPoint second) {
    final dx = first.x - second.x;
    final dy = first.y - second.y;
    return dx * dx + dy * dy <= _positionEpsilonSquared;
  }

  static bool _isFinite(Vec2 point) => point.x.isFinite && point.y.isFinite;

  static void _addUnitBreakpoint(List<double> values, double value) {
    if (value.isFinite &&
        value > _parameterEpsilon &&
        value < 1 - _parameterEpsilon) {
      values.add(value);
    }
  }

  static List<double> _deduplicateParameters(List<double> values) {
    final result = <double>[];
    for (final value in values) {
      final bounded = value.clamp(0.0, 1.0);
      if (result.isEmpty || (result.last - bounded).abs() > _parameterEpsilon) {
        result.add(bounded);
      }
    }
    return result;
  }
}

final class _ParameterInterval {
  const _ParameterInterval(this.start, this.end);

  final double start;
  final double end;
}

final class _Quadratic {
  const _Quadratic({required this.a, required this.b, required this.c});

  final double a;
  final double b;
  final double c;
}
