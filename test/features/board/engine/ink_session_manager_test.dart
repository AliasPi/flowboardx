import 'dart:math' as math;

import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/engine/ink_session_manager.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tracks stylus sessions independently from other active pointers', () {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    expect(
      manager.begin(
        event: const PointerDownEvent(
          pointer: 1,
          kind: PointerDeviceKind.mouse,
        ),
        worldPosition: Offset.zero,
        style: const ActivePenStyle(),
        authorId: 'mouse',
      ),
      isTrue,
    );
    expect(manager.hasActiveStylus, isFalse);
    expect(
      manager.begin(
        event: const PointerDownEvent(
          pointer: 2,
          kind: PointerDeviceKind.stylus,
        ),
        worldPosition: const Offset(10, 10),
        style: const ActivePenStyle(),
        authorId: 'pen',
      ),
      isTrue,
    );
    expect(manager.hasActiveStylus, isTrue);
    manager.cancel(2);
    expect(manager.hasActiveStylus, isFalse);
  });

  test('keeps simultaneous pen sessions isolated', () {
    final manager = InkSessionManager();
    const style = ActivePenStyle(type: InkToolType.normal);
    manager.begin(
      event: const PointerDownEvent(pointer: 1, position: Offset.zero),
      worldPosition: Offset.zero,
      style: style,
      authorId: 'left',
    );
    manager.begin(
      event: const PointerDownEvent(pointer: 2, position: Offset(100, 0)),
      worldPosition: const Offset(100, 0),
      style: style,
      authorId: 'right',
    );
    manager.update(
      const PointerMoveEvent(pointer: 1, position: Offset(10, 0)),
      const Offset(10, 0),
    );
    manager.update(
      const PointerMoveEvent(pointer: 2, position: Offset(110, 0)),
      const Offset(110, 0),
    );

    final first = manager.end(
      const PointerUpEvent(pointer: 1, position: Offset(10, 0)),
      const Offset(10, 0),
    );
    final second = manager.end(
      const PointerUpEvent(pointer: 2, position: Offset(110, 0)),
      const Offset(110, 0),
    );

    expect(first?.authorId, 'left');
    expect(second?.authorId, 'right');
    expect(first?.points.first.x, 0);
    expect(second?.points.first.x, 100);
  });

  test('bounds a long live marker in reusable preview chunks', () {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    manager.begin(
      event: const PointerDownEvent(pointer: 7, position: Offset.zero),
      worldPosition: Offset.zero,
      style: const ActivePenStyle(type: InkToolType.marker, width: 16),
      authorId: 'marker',
    );
    _appendSpiral(manager, pointer: 7, from: 1, through: 3000);

    final previews = manager.buildPreviewStrokes();
    final sampledPointCount = manager.sessions[7]!.sampler.samples.length;

    expect(previews.length, greaterThan(1));
    expect(
      previews.every((stroke) => stroke.type == InkToolType.marker),
      isTrue,
    );
    _expectBoundedChunks(
      previews,
      sampledPointCount: sampledPointCount,
      maximumPointsPerChunk: 192,
    );
  });

  test('bounds a long circular normal stroke as it grows', () {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    manager.begin(
      event: const PointerDownEvent(pointer: 8, position: Offset.zero),
      worldPosition: Offset.zero,
      style: const ActivePenStyle(type: InkToolType.normal, width: 8),
      authorId: 'spiral',
    );
    _appendSpiral(manager, pointer: 8, from: 1, through: 6000);

    final previews = manager.buildPreviewStrokes();
    final sampledPointCount = manager.sessions[8]!.sampler.samples.length;

    expect(previews.length, greaterThan(20));
    expect(
      previews.every((stroke) => stroke.type == InkToolType.normal),
      isTrue,
    );
    _expectBoundedChunks(
      previews,
      sampledPointCount: sampledPointCount,
      maximumPointsPerChunk: 192,
    );
  });

  test('retains frozen chunk identity while only the live tail changes', () {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    manager.begin(
      event: const PointerDownEvent(pointer: 9, position: Offset.zero),
      worldPosition: Offset.zero,
      style: const ActivePenStyle(type: InkToolType.normal),
      authorId: 'cached-preview',
    );
    _appendLine(manager, pointer: 9, from: 1, through: 450);

    final before = manager.buildPreviewStrokes();
    final frozenBefore = before.sublist(0, before.length - 1);
    final tailBefore = before.last;
    expect(frozenBefore.length, greaterThanOrEqualTo(2));

    _appendLine(manager, pointer: 9, from: 451, through: 900);
    final after = manager.buildPreviewStrokes();

    for (var index = 0; index < frozenBefore.length; index++) {
      expect(
        identical(after[index], frozenBefore[index]),
        isTrue,
        reason: 'Frozen chunk $index must remain cacheable by identity.',
      );
    }
    expect(identical(after.last, tailBefore), isFalse);
    _expectBoundedChunks(
      after,
      sampledPointCount: manager.sessions[9]!.sampler.samples.length,
      maximumPointsPerChunk: 192,
    );
  });

  test('keeps simultaneous dashed previews finite and pointer-isolated', () {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    for (final pointer in <int>[11, 12]) {
      expect(
        manager.begin(
          event: PointerDownEvent(pointer: pointer, position: Offset.zero),
          worldPosition: Offset(pointer.toDouble(), 0),
          style: const ActivePenStyle(
            type: InkToolType.dashed,
            width: double.nan,
          ),
          authorId: 'writer-$pointer',
        ),
        isTrue,
      );
    }

    manager.update(
      const PointerMoveEvent(pointer: 11),
      const Offset(double.nan, 4),
    );
    manager.update(const PointerMoveEvent(pointer: 11), const Offset(40, 4));
    manager.update(const PointerMoveEvent(pointer: 12), const Offset(80, 8));

    final previews = manager.buildPreviewStrokes();
    expect(previews, hasLength(2));
    expect(
      previews.map((stroke) => stroke.pointerId),
      containsAll(<int>[11, 12]),
    );
    expect(
      previews.every((stroke) => stroke.type == InkToolType.dashed),
      isTrue,
    );
    expect(
      previews.every(
        (stroke) =>
            stroke.width.isFinite &&
            stroke.points.every(
              (point) => point.x.isFinite && point.y.isFinite,
            ),
      ),
      isTrue,
    );

    final first = manager.end(
      const PointerUpEvent(pointer: 11),
      const Offset(45, 4),
    );
    final second = manager.end(
      const PointerUpEvent(pointer: 12),
      const Offset(85, 8),
    );
    expect(first?.authorId, 'writer-11');
    expect(second?.authorId, 'writer-12');
    expect(first?.width, 4);
    expect(second?.width, 4);
  });

  test('bounds repaint layers for a long live dashed stroke', () {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    manager.begin(
      event: const PointerDownEvent(pointer: 17, position: Offset.zero),
      worldPosition: Offset.zero,
      style: const ActivePenStyle(type: InkToolType.dashed, width: 8),
      authorId: 'long-dash',
    );
    for (var index = 1; index <= 1200; index++) {
      final position = Offset(index.toDouble(), (index % 11).toDouble());
      manager.update(
        PointerMoveEvent(pointer: 17, position: position),
        position,
      );
    }

    final previews = manager.buildPreviewStrokes();

    expect(previews, hasLength(3));
    expect(
      previews.fold<int>(0, (total, stroke) => total + stroke.points.length),
      // Adjacent immutable chunks intentionally share one endpoint.
      1203,
    );
  });
}

void _appendSpiral(
  InkSessionManager manager, {
  required int pointer,
  required int from,
  required int through,
}) {
  for (var index = from; index <= through; index++) {
    final angle = index * .09;
    final radius = 20 + index * .03;
    final point = Offset(radius * math.cos(angle), radius * math.sin(angle));
    manager.update(
      PointerMoveEvent(pointer: pointer, position: point),
      point,
      samplingPosition: point,
    );
  }
}

void _appendLine(
  InkSessionManager manager, {
  required int pointer,
  required int from,
  required int through,
}) {
  for (var index = from; index <= through; index++) {
    final point = Offset(index * 2, (index % 7).toDouble());
    manager.update(
      PointerMoveEvent(pointer: pointer, position: point),
      point,
      samplingPosition: point,
    );
  }
}

void _expectBoundedChunks(
  List<InkStroke> previews, {
  required int sampledPointCount,
  required int maximumPointsPerChunk,
}) {
  expect(previews, isNotEmpty);
  expect(
    previews.every(
      (stroke) =>
          stroke.points.isNotEmpty &&
          stroke.points.length <= maximumPointsPerChunk,
    ),
    isTrue,
  );
  expect(
    previews.fold<int>(0, (total, stroke) => total + stroke.points.length),
    sampledPointCount + previews.length - 1,
    reason: 'Adjacent chunks share exactly one seam endpoint.',
  );
}
