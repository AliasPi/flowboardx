import 'dart:math' as math;

import 'package:flowboard_x/src/features/board/engine/spatial_index.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('spatial index returns only intersecting entries and updates', () {
    final index = SpatialIndex<String>(cellSize: 50)
      ..insert('a', const Rect.fromLTWH(0, 0, 20, 20))
      ..insert('b', const Rect.fromLTWH(90, 90, 20, 20));

    expect(index.query(const Rect.fromLTWH(10, 10, 10, 10)), {'a'});
    expect(index.query(const Rect.fromLTWH(40, 40, 20, 20)), isEmpty);

    index.update('a', const Rect.fromLTWH(100, 100, 10, 10));
    expect(index.query(const Rect.fromLTWH(0, 0, 30, 30)), isEmpty);
    expect(index.query(const Rect.fromLTWH(95, 95, 30, 30)), {'a', 'b'});
  });

  test('point bounds handles empty and negative coordinates', () {
    expect(boundsForPoints(const []), Rect.zero);
    expect(
      boundsForPoints(const [Offset(-4, 5), Offset(9, -2)], inflate: 2),
      const Rect.fromLTRB(-6, -4, 11, 7),
    );
  });

  test('polyline index leaves a large circle interior sparse', () {
    const radius = 4000.0;
    final points = List<Offset>.generate(721, (index) {
      final angle = index / 720 * math.pi * 2;
      return Offset(math.cos(angle) * radius, math.sin(angle) * radius);
    });
    final index = SpatialIndex<String>(cellSize: 100)
      ..insertPolyline('circle', points, inflate: 4);

    expect(index.occupiedCellCount, lessThan(1400));
    expect(index.query(const Rect.fromLTWH(-10, -10, 20, 20)), isEmpty);
    expect(index.query(const Rect.fromLTWH(radius - 10, -10, 20, 20)), {
      'circle',
    });
  });

  test('mapped polyline indexes point records without Offset conversion', () {
    final points = <({double x, double y})>[
      (x: double.nan, y: 0),
      (x: -20, y: 15),
      (x: 120, y: 15),
      (x: double.infinity, y: 15),
    ];
    final index = SpatialIndex<String>(cellSize: 32)
      ..insertMappedPolyline(
        'ink',
        points,
        xOf: (point) => point.x,
        yOf: (point) => point.y,
        inflate: 4,
      );

    expect(index.length, 1);
    expect(index.query(const Rect.fromLTWH(-24, 10, 8, 10)), {'ink'});
    expect(index.query(const Rect.fromLTWH(40, 10, 8, 10)), {'ink'});
    expect(index.query(const Rect.fromLTWH(40, 40, 8, 8)), isEmpty);
  });

  test('extreme recovered bounds use a bounded linear fallback', () {
    final index = SpatialIndex<String>(cellSize: 32, maximumCellMemberships: 64)
      ..insert('poster', const Rect.fromLTWH(-1e12, -1e12, 2e12, 2e12));

    expect(index.length, 1);
    expect(index.occupiedCellCount, 0);
    expect(index.unindexedEntryCount, 1);
    expect(index.query(const Rect.fromLTWH(-4, -4, 8, 8)), {'poster'});

    index.update('poster', const Rect.fromLTWH(100, 100, 10, 10));
    expect(index.unindexedEntryCount, 0);
    expect(index.query(const Rect.fromLTWH(-4, -4, 8, 8)), isEmpty);
    expect(index.query(const Rect.fromLTWH(95, 95, 20, 20)), {'poster'});
  });

  test('extreme polyline segment never enumerates every crossed cell', () {
    final index = SpatialIndex<String>(cellSize: 32, maximumCellMemberships: 64)
      ..insertPolyline('recovered-ink', const <Offset>[
        Offset(-1e12, 0),
        Offset(1e12, 0),
      ], inflate: 4);

    expect(index.length, 1);
    expect(index.occupiedCellCount, 0);
    expect(index.unindexedEntryCount, 1);
    expect(index.query(const Rect.fromLTWH(-2, -2, 4, 4)), {'recovered-ink'});
    expect(index.query(const Rect.fromLTWH(0, 100, 4, 4)), isEmpty);
  });

  test('huge query falls back without enumerating empty grid cells', () {
    final index = SpatialIndex<String>(cellSize: 32, maximumCellMemberships: 64)
      ..insert('inside', const Rect.fromLTWH(10, 10, 5, 5))
      ..insert('outside', const Rect.fromLTWH(1e9, 1e9, 5, 5));

    expect(index.query(const Rect.fromLTWH(-1e6, -1e6, 2e6, 2e6)), {'inside'});
  });
}
