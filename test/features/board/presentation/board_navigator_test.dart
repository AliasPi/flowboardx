import 'package:flowboard_x/src/features/board/engine/board_viewport.dart';
import 'package:flowboard_x/src/features/board/presentation/board_navigator.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BoardNavigatorGeometry', () {
    const worldBounds = Rect.fromLTWH(-1000, -500, 3000, 1500);
    const mapSize = Size(600, 300);

    test('maps navigator positions to world coordinates and clamps edges', () {
      expect(
        BoardNavigatorGeometry.worldAt(
          const Offset(300, 150),
          mapSize: mapSize,
          worldBounds: worldBounds,
        ),
        const Offset(500, 250),
      );
      expect(
        BoardNavigatorGeometry.worldAt(
          const Offset(-50, 400),
          mapSize: mapSize,
          worldBounds: worldBounds,
        ),
        const Offset(-1000, 1000),
      );
    });

    test('maps world rectangles into the navigator coordinate system', () {
      expect(
        BoardNavigatorGeometry.mapRect(
          const Rect.fromLTWH(-250, -125, 1500, 750),
          mapSize,
          worldBounds,
        ),
        const Rect.fromLTWH(150, 75, 300, 150),
      );
    });

    test('uses only the assigned participant half for the viewport frame', () {
      const world = Rect.fromLTWH(0, 0, 3000, 1800);
      const leftHalf = Rect.fromLTWH(0, 0, 500, 600);
      const rightHalf = Rect.fromLTWH(500, 0, 500, 600);

      expect(
        BoardNavigatorGeometry.visibleWorldRect(
          viewportScale: 1,
          viewportOffset: Offset.zero,
          visibleScreenBounds: leftHalf,
          worldBounds: world,
        ),
        leftHalf,
      );
      expect(
        BoardNavigatorGeometry.visibleWorldRect(
          viewportScale: 1,
          viewportOffset: Offset.zero,
          visibleScreenBounds: rightHalf,
          worldBounds: world,
        ),
        rightHalf,
      );
    });
  });

  group('BoardViewport.centerOn', () {
    test(
      'places a world position at the screen center at the current zoom',
      () {
        final viewport = BoardViewport(scale: 2);
        const viewportSize = Size(1000, 600);
        const target = Offset(420, 230);
        var notifications = 0;
        viewport.addListener(() => notifications++);

        viewport.centerOn(target, viewportSize);

        expect(
          viewport.worldToScreen(target),
          viewportSize.center(Offset.zero),
        );
        expect(notifications, 1);
      },
    );

    test('ignores non-finite positions and empty viewport sizes', () {
      final viewport = BoardViewport(scale: 1.4, offset: const Offset(70, -35));
      final originalOffset = viewport.offset;
      var notifications = 0;
      viewport.addListener(() => notifications++);

      viewport.centerOn(const Offset(double.nan, 0), const Size(800, 600));
      viewport.centerOn(const Offset(100, 100), Size.zero);

      expect(viewport.offset, originalOffset);
      expect(notifications, 0);
    });
  });

  test('camera motion does not repaint static navigator content', () {
    final strokes = <InkStroke>[
      InkStroke(
        id: 'navigator-ink',
        points: const <InkPoint>[
          InkPoint(x: 10, y: 10),
          InkPoint(x: 80, y: 60),
        ],
      ),
    ];
    final before = BoardNavigatorContentPainter(
      worldBounds: const Rect.fromLTWH(0, 0, 1000, 600),
      objects: const [],
      strokes: strokes,
    );
    final afterCameraMove = BoardNavigatorContentPainter(
      worldBounds: const Rect.fromLTWH(0, 0, 1000, 600),
      objects: const [],
      strokes: strokes,
    );

    expect(afterCameraMove.shouldRepaint(before), isFalse);
  });
}
