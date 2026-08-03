import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Mutable grid index used for localized hit tests and erasing. Entries may
/// span multiple cells; query results are de-duplicated.
class SpatialIndex<T extends Object> {
  SpatialIndex({this.cellSize = 128, this.maximumCellMemberships = 4096})
    : assert(cellSize > 0),
      assert(maximumCellMemberships > 0);

  final double cellSize;
  final int maximumCellMemberships;
  final Map<(int, int), Set<T>> _cells = <(int, int), Set<T>>{};
  final Map<T, Rect> _bounds = <T, Rect>{};
  final Map<T, Set<(int, int)>> _memberships = <T, Set<(int, int)>>{};
  final Set<T> _unindexed = <T>{};

  int get length => _bounds.length;
  @visibleForTesting
  int get occupiedCellCount => _cells.length;
  @visibleForTesting
  int get unindexedEntryCount => _unindexed.length;

  void insert(T value, Rect bounds) {
    remove(value);
    if (!_valid(bounds)) return;
    _bounds[value] = bounds;
    if (!_canEnumerateBounds(bounds)) {
      _unindexed.add(value);
      return;
    }
    final memberships = _cellsFor(bounds).toSet();
    _memberships[value] = memberships;
    for (final cell in memberships) {
      (_cells[cell] ??= <T>{}).add(value);
    }
  }

  /// Indexes the occupied polyline cells rather than every cell in its AABB.
  ///
  /// A large handwritten circle has a large bounding square but almost no ink
  /// in its interior. Filling that square made the first eraser contact grow
  /// with radius squared. Segment traversal keeps membership proportional to
  /// actual stroke length while [_bounds] still provides the cheap final
  /// rejection used by [query].
  void insertPolyline(T value, Iterable<Offset> points, {double inflate = 0}) =>
      insertMappedPolyline<Offset>(
        value,
        points,
        xOf: _offsetX,
        yOf: _offsetY,
        inflate: inflate,
      );

  /// Indexes arbitrary point records without first allocating one [Offset] per
  /// sample. Ink strokes use this path directly; curved handwriting contains
  /// many more anchors, so avoiding that temporary list materially reduces
  /// the first-erase/index-rebuild pause on dense pages.
  void insertMappedPolyline<P>(
    T value,
    Iterable<P> points, {
    required double Function(P point) xOf,
    required double Function(P point) yOf,
    double inflate = 0,
  }) {
    remove(value);
    if (!inflate.isFinite || inflate < 0) return;
    final memberships = <(int, int)>{};
    var pointCount = 0;
    var previousX = 0.0;
    var previousY = 0.0;
    var left = 0.0;
    var right = 0.0;
    var top = 0.0;
    var bottom = 0.0;
    var membershipsOverflowed = false;
    for (final point in points) {
      final x = xOf(point);
      final y = yOf(point);
      if (!x.isFinite || !y.isFinite) continue;
      if (pointCount == 0) {
        left = right = previousX = x;
        top = bottom = previousY = y;
      } else {
        left = math.min(left, x);
        right = math.max(right, x);
        top = math.min(top, y);
        bottom = math.max(bottom, y);
        if (!membershipsOverflowed) {
          membershipsOverflowed = !_addSegmentCoordinateCells(
            memberships,
            previousX,
            previousY,
            x,
            y,
            inflate,
          );
          if (membershipsOverflowed) memberships.clear();
        }
      }
      previousX = x;
      previousY = y;
      pointCount++;
    }
    if (pointCount == 0) return;
    final bounds = Rect.fromLTRB(left, top, right, bottom).inflate(inflate);
    if (!_valid(bounds)) return;
    _bounds[value] = bounds;
    if (membershipsOverflowed ||
        (memberships.isEmpty && !_canEnumerateBounds(bounds))) {
      _unindexed.add(value);
      return;
    }
    if (memberships.isEmpty) memberships.addAll(_cellsFor(bounds));
    _memberships[value] = memberships;
    for (final cell in memberships) {
      (_cells[cell] ??= <T>{}).add(value);
    }
  }

  void update(T value, Rect bounds) => insert(value, bounds);

  void remove(T value) {
    _bounds.remove(value);
    _unindexed.remove(value);
    final memberships = _memberships.remove(value);
    if (memberships == null) return;
    for (final cell in memberships) {
      final values = _cells[cell];
      values?.remove(value);
      if (values?.isEmpty ?? false) _cells.remove(cell);
    }
  }

  Set<T> query(Rect area) {
    if (!_valid(area)) return <T>{};
    final candidates = <T>{..._unindexed};
    if (_canEnumerateBounds(area)) {
      for (final cell in _cellsFor(area)) {
        final values = _cells[cell];
        if (values != null) candidates.addAll(values);
      }
    } else {
      // A corrupt import or an extreme zoom must not enumerate billions of
      // empty grid cells. Huge queries are rare and are safer as one bounded
      // pass over the registered entries.
      candidates.addAll(_bounds.keys);
    }
    candidates.removeWhere(
      (value) => !(_bounds[value]?.overlaps(area) ?? false),
    );
    return candidates;
  }

  void clear() {
    _cells.clear();
    _bounds.clear();
    _memberships.clear();
    _unindexed.clear();
  }

  bool _addSegmentCoordinateCells(
    Set<(int, int)> result,
    double startX,
    double startY,
    double endX,
    double endY,
    double inflate,
  ) {
    final dx = endX - startX;
    final dy = endY - startY;
    final stepExtent = math.max(dx.abs(), dy.abs()) / cellSize;
    if (!stepExtent.isFinite || stepExtent > maximumCellMemberships) {
      return false;
    }
    final steps = math.max(1, stepExtent.ceil());
    final neighborRadius = math.max(0, (inflate / cellSize).ceil());
    final neighborDiameter = neighborRadius * 2 + 1;
    if (neighborDiameter > maximumCellMemberships ||
        neighborDiameter * neighborDiameter > maximumCellMemberships) {
      return false;
    }
    for (var step = 0; step <= steps; step++) {
      final t = step / steps;
      final x = ((startX + dx * t) / cellSize).floor();
      final y = ((startY + dy * t) / cellSize).floor();
      for (
        var offsetX = -neighborRadius;
        offsetX <= neighborRadius;
        offsetX++
      ) {
        for (
          var offsetY = -neighborRadius;
          offsetY <= neighborRadius;
          offsetY++
        ) {
          result.add((x + offsetX, y + offsetY));
          if (result.length > maximumCellMemberships) return false;
        }
      }
    }
    return true;
  }

  Iterable<(int, int)> _cellsFor(Rect rect) sync* {
    final left = (rect.left / cellSize).floor();
    final top = (rect.top / cellSize).floor();
    final right = (rect.right / cellSize).floor();
    final bottom = (rect.bottom / cellSize).floor();
    for (var x = left; x <= right; x++) {
      for (var y = top; y <= bottom; y++) {
        yield (x, y);
      }
    }
  }

  bool _valid(Rect rect) =>
      rect.left.isFinite &&
      rect.top.isFinite &&
      rect.right.isFinite &&
      rect.bottom.isFinite &&
      rect.width >= 0 &&
      rect.height >= 0 &&
      math.max(rect.width, rect.height) < double.maxFinite;

  bool _canEnumerateBounds(Rect rect) {
    final horizontalCells = rect.width / cellSize + 2;
    final verticalCells = rect.height / cellSize + 2;
    return horizontalCells.isFinite &&
        verticalCells.isFinite &&
        horizontalCells <= maximumCellMemberships &&
        verticalCells <= maximumCellMemberships &&
        horizontalCells * verticalCells <= maximumCellMemberships;
  }
}

double _offsetX(Offset point) => point.dx;
double _offsetY(Offset point) => point.dy;

@visibleForTesting
Rect boundsForPoints(Iterable<Offset> points, {double inflate = 0}) {
  final iterator = points.iterator;
  if (!iterator.moveNext()) return Rect.zero;
  var left = iterator.current.dx;
  var right = iterator.current.dx;
  var top = iterator.current.dy;
  var bottom = iterator.current.dy;
  while (iterator.moveNext()) {
    left = math.min(left, iterator.current.dx);
    right = math.max(right, iterator.current.dx);
    top = math.min(top, iterator.current.dy);
    bottom = math.max(bottom, iterator.current.dy);
  }
  return Rect.fromLTRB(left, top, right, bottom).inflate(inflate);
}
