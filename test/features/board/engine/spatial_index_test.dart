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
}
