import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Mutable grid index used for localized hit tests and erasing. Entries may
/// span multiple cells; query results are de-duplicated.
class SpatialIndex<T extends Object> {
  SpatialIndex({this.cellSize = 128}) : assert(cellSize > 0);

  final double cellSize;
  final Map<(int, int), Set<T>> _cells = <(int, int), Set<T>>{};
  final Map<T, Rect> _bounds = <T, Rect>{};

  int get length => _bounds.length;

  void insert(T value, Rect bounds) {
    remove(value);
    if (!_valid(bounds)) return;
    _bounds[value] = bounds;
    for (final cell in _cellsFor(bounds)) {
      (_cells[cell] ??= <T>{}).add(value);
    }
  }

  void update(T value, Rect bounds) => insert(value, bounds);

  void remove(T value) {
    final old = _bounds.remove(value);
    if (old == null) return;
    for (final cell in _cellsFor(old)) {
      final values = _cells[cell];
      values?.remove(value);
      if (values?.isEmpty ?? false) _cells.remove(cell);
    }
  }

  Set<T> query(Rect area) {
    if (!_valid(area)) return <T>{};
    final candidates = <T>{};
    for (final cell in _cellsFor(area)) {
      final values = _cells[cell];
      if (values != null) candidates.addAll(values);
    }
    candidates.removeWhere(
      (value) => !(_bounds[value]?.overlaps(area) ?? false),
    );
    return candidates;
  }

  void clear() {
    _cells.clear();
    _bounds.clear();
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
}

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
