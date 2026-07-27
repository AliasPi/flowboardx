import 'package:flowboard_x/src/features/board/engine/board_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const viewportSize = Size(1000, 700);

  test(
    'atomic gesture preserves pan-then-zoom geometry with one notification',
    () {
      const initialScale = 1.25;
      const initialOffset = Offset(80, -30);
      const oldCentroid = Offset(300, 250);
      const panDelta = Offset(20, -10);
      const newCentroid = Offset(320, 240);
      const zoomFactor = 1.4;
      final sequential = BoardViewport(
        scale: initialScale,
        offset: initialOffset,
      );
      final atomic = BoardViewport(scale: initialScale, offset: initialOffset);
      addTearDown(sequential.dispose);
      addTearDown(atomic.dispose);
      var sequentialNotifications = 0;
      var atomicNotifications = 0;
      sequential.addListener(() => sequentialNotifications++);
      atomic.addListener(() => atomicNotifications++);
      final anchoredWorldPoint = atomic.screenToWorld(oldCentroid);

      sequential.panBy(panDelta, viewportSize);
      sequential.zoomAt(
        factor: zoomFactor,
        focalPoint: newCentroid,
        viewportSize: viewportSize,
      );
      atomic.applyGestureTransform(
        panDelta: panDelta,
        focalPoint: newCentroid,
        viewportSize: viewportSize,
        zoomFactor: zoomFactor,
      );

      expect(atomic.scale, sequential.scale);
      expect(atomic.offset.dx, closeTo(sequential.offset.dx, 1e-9));
      expect(atomic.offset.dy, closeTo(sequential.offset.dy, 1e-9));
      expect(
        atomic.screenToWorld(newCentroid).dx,
        closeTo(anchoredWorldPoint.dx, 1e-9),
      );
      expect(
        atomic.screenToWorld(newCentroid).dy,
        closeTo(anchoredWorldPoint.dy, 1e-9),
      );
      expect(sequentialNotifications, 2);
      expect(atomicNotifications, 1);
    },
  );

  test('atomic gesture preserves both split-view constraint passes', () {
    const visibleBounds = Rect.fromLTWH(0, 0, 500, 700);
    const constraint = BoardViewportHorizontalConstraint(
      side: BoardViewportPartitionSide.left,
      worldBoundaryX: 960,
    );
    final sequential = BoardViewport(offset: const Offset(-420, 25));
    final atomic = BoardViewport(offset: const Offset(-420, 25));
    addTearDown(sequential.dispose);
    addTearDown(atomic.dispose);

    sequential.panBy(
      const Offset(-180, 35),
      viewportSize,
      visibleScreenBounds: visibleBounds,
      horizontalConstraint: constraint,
    );
    sequential.zoomAt(
      factor: .62,
      focalPoint: const Offset(430, 310),
      viewportSize: viewportSize,
      visibleScreenBounds: visibleBounds,
      horizontalConstraint: constraint,
    );
    atomic.applyGestureTransform(
      panDelta: const Offset(-180, 35),
      focalPoint: const Offset(430, 310),
      viewportSize: viewportSize,
      zoomFactor: .62,
      visibleScreenBounds: visibleBounds,
      horizontalConstraint: constraint,
    );

    expect(atomic.scale, sequential.scale);
    expect(atomic.offset.dx, closeTo(sequential.offset.dx, 1e-9));
    expect(atomic.offset.dy, closeTo(sequential.offset.dy, 1e-9));
    expect(
      atomic.screenToWorld(visibleBounds.centerRight).dx,
      closeTo(960, 1e-9),
    );
  });

  test(
    'atomic gesture does not notify when clamping keeps state unchanged',
    () {
      const visibleBounds = Rect.fromLTWH(0, 0, 500, 700);
      const constraint = BoardViewportHorizontalConstraint(
        side: BoardViewportPartitionSide.left,
        worldBoundaryX: 960,
      );
      final viewport = BoardViewport(offset: const Offset(-460, 0));
      addTearDown(viewport.dispose);
      var notifications = 0;
      viewport.addListener(() => notifications++);

      viewport.applyGestureTransform(
        panDelta: const Offset(-120, 0),
        focalPoint: const Offset(250, 300),
        viewportSize: viewportSize,
        zoomFactor: 1,
        visibleScreenBounds: visibleBounds,
        horizontalConstraint: constraint,
      );

      expect(viewport.scale, 1);
      expect(viewport.offset, const Offset(-460, 0));
      expect(notifications, 0);
    },
  );
}
