import 'package:flowboard_x/src/features/board/engine/board_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const surfaceSize = Size(1000, 700);
  const leftVisible = Rect.fromLTWH(0, 0, 500, 700);
  const rightVisible = Rect.fromLTWH(500, 0, 500, 700);
  const boundary = 960.0;
  const leftConstraint = BoardViewportHorizontalConstraint(
    side: BoardViewportPartitionSide.left,
    worldBoundaryX: boundary,
  );
  const rightConstraint = BoardViewportHorizontalConstraint(
    side: BoardViewportPartitionSide.right,
    worldBoundaryX: boundary,
  );

  test('initial split alignment places both inner edges on the divider', () {
    final left = BoardViewport(scale: 1.35, offset: const Offset(275, 64));
    final right = BoardViewport(scale: 1.35, offset: const Offset(275, 64));
    addTearDown(left.dispose);
    addTearDown(right.dispose);

    left.alignToHorizontalPartition(
      viewportSize: surfaceSize,
      visibleScreenBounds: leftVisible,
      horizontalConstraint: leftConstraint,
    );
    right.alignToHorizontalPartition(
      viewportSize: surfaceSize,
      visibleScreenBounds: rightVisible,
      horizontalConstraint: rightConstraint,
    );

    expect(left.scale, 1.35);
    expect(right.scale, 1.35);
    expect(left.offset.dy, 64);
    expect(right.offset.dy, 64);
    expect(
      left.screenToWorld(leftVisible.centerRight).dx,
      closeTo(boundary, 1e-9),
    );
    expect(
      right.screenToWorld(rightVisible.centerLeft).dx,
      closeTo(boundary, 1e-9),
    );
  });

  test('split alignment does not emit a redundant camera update', () {
    final viewport = BoardViewport();
    addTearDown(viewport.dispose);
    var notifications = 0;
    viewport.addListener(() => notifications++);

    viewport.alignToHorizontalPartition(
      viewportSize: surfaceSize,
      visibleScreenBounds: leftVisible,
      horizontalConstraint: leftConstraint,
    );
    expect(notifications, 1);

    viewport.alignToHorizontalPartition(
      viewportSize: surfaceSize,
      visibleScreenBounds: leftVisible,
      horizontalConstraint: leftConstraint,
    );
    expect(notifications, 1);
  });

  test('left viewport cannot pan through the world divider', () {
    final viewport = BoardViewport();
    addTearDown(viewport.dispose);

    viewport.panBy(
      const Offset(-2000, 90),
      surfaceSize,
      visibleScreenBounds: leftVisible,
      horizontalConstraint: leftConstraint,
    );

    expect(
      viewport.screenToWorld(leftVisible.centerRight).dx,
      closeTo(960, 1e-9),
    );
    expect(viewport.offset.dy, 90, reason: 'vertical pan remains independent');

    viewport.panBy(
      const Offset(100, 0),
      surfaceSize,
      visibleScreenBounds: leftVisible,
      horizontalConstraint: leftConstraint,
    );

    expect(viewport.screenToWorld(leftVisible.centerRight).dx, lessThan(960));
  });

  test('right viewport cannot pan through the world divider', () {
    final viewport = BoardViewport();
    addTearDown(viewport.dispose);

    viewport.constrain(
      viewportSize: surfaceSize,
      visibleScreenBounds: rightVisible,
      horizontalConstraint: rightConstraint,
    );
    expect(
      viewport.screenToWorld(rightVisible.centerLeft).dx,
      closeTo(960, 1e-9),
    );

    viewport.panBy(
      const Offset(2000, -80),
      surfaceSize,
      visibleScreenBounds: rightVisible,
      horizontalConstraint: rightConstraint,
    );

    expect(
      viewport.screenToWorld(rightVisible.centerLeft).dx,
      closeTo(960, 1e-9),
    );
    expect(viewport.offset.dy, -80, reason: 'vertical pan remains independent');

    viewport.panBy(
      const Offset(-100, 0),
      surfaceSize,
      visibleScreenBounds: rightVisible,
      horizontalConstraint: rightConstraint,
    );

    expect(
      viewport.screenToWorld(rightVisible.centerLeft).dx,
      greaterThan(960),
    );
  });

  test(
    'zoom-out clamps at the neighbour boundary without raising min scale',
    () {
      final left = BoardViewport(offset: const Offset(-460, 0));
      final right = BoardViewport(offset: const Offset(-460, 0));
      addTearDown(left.dispose);
      addTearDown(right.dispose);

      left.zoomAt(
        factor: .5,
        focalPoint: const Offset(250, 300),
        viewportSize: surfaceSize,
        visibleScreenBounds: leftVisible,
        horizontalConstraint: leftConstraint,
      );
      right.zoomAt(
        factor: .5,
        focalPoint: const Offset(750, 300),
        viewportSize: surfaceSize,
        visibleScreenBounds: rightVisible,
        horizontalConstraint: rightConstraint,
      );

      expect(left.scale, .5);
      expect(right.scale, .5);
      expect(
        left.screenToWorld(leftVisible.centerRight).dx,
        closeTo(960, 1e-9),
      );
      expect(
        right.screenToWorld(rightVisible.centerLeft).dx,
        closeTo(960, 1e-9),
      );
    },
  );

  test('navigator centering also respects the assigned half', () {
    final left = BoardViewport();
    final right = BoardViewport();
    addTearDown(left.dispose);
    addTearDown(right.dispose);

    left.centerOn(
      const Offset(2000, 100),
      surfaceSize,
      visibleScreenBounds: leftVisible,
      horizontalConstraint: leftConstraint,
    );
    right.centerOn(
      const Offset(-500, 100),
      surfaceSize,
      visibleScreenBounds: rightVisible,
      horizontalConstraint: rightConstraint,
    );

    expect(
      left.screenToWorld(leftVisible.centerRight).dx,
      lessThanOrEqualTo(960),
    );
    expect(
      right.screenToWorld(rightVisible.centerLeft).dx,
      greaterThanOrEqualTo(960),
    );
  });
}
