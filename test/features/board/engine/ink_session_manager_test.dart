import 'dart:math' as math;

import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/engine/ink_session_manager.dart';
import 'package:flowboard_x/src/features/board/presentation/ink_painter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('coalesces accepted MOVE notifications to one per frame', (
    tester,
  ) async {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    var notifications = 0;
    manager.addListener(() => notifications++);

    expect(
      manager.begin(
        event: const PointerDownEvent(pointer: 90, position: Offset.zero),
        worldPosition: Offset.zero,
        style: const ActivePenStyle(),
        authorId: 'frame-coalescing',
      ),
      isTrue,
    );
    expect(notifications, 1, reason: 'DOWN remains synchronous.');

    _appendHorizontalLine(manager, pointer: 90, from: 1, through: 200);
    expect(
      notifications,
      1,
      reason: 'MOVE packets wait for the next paintable frame.',
    );
    await tester.pump();
    expect(notifications, 2);

    _appendHorizontalLine(manager, pointer: 90, from: 201, through: 400);
    manager.end(
      const PointerUpEvent(pointer: 90, position: Offset(800, 0)),
      const Offset(800, 0),
      samplingPosition: const Offset(800, 0),
    );
    expect(
      notifications,
      3,
      reason: 'UP supersedes the queued MOVE and remains synchronous.',
    );
    await tester.pump();
    expect(notifications, 3, reason: 'No stale frame callback may survive UP.');
  });

  test('tracks a short quiet period after the stylus is lifted', () async {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    expect(manager.wasActiveWithin(const Duration(seconds: 1)), isFalse);

    expect(
      manager.begin(
        event: const PointerDownEvent(pointer: 91, position: Offset.zero),
        worldPosition: Offset.zero,
        style: const ActivePenStyle(),
        authorId: 'quiet-period',
      ),
      isTrue,
    );
    manager.end(
      const PointerUpEvent(pointer: 91, position: Offset(1, 1)),
      const Offset(1, 1),
    );

    expect(manager.isWriting, isFalse);
    expect(manager.wasActiveWithin(const Duration(seconds: 1)), isTrue);
  });

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

  test('retains fine curve detail when handwriting at minimum zoom', () {
    InkStroke drawSmallCircle({required double viewportScale}) {
      final manager = InkSessionManager();
      addTearDown(manager.dispose);
      const pointer = 6;
      const screenRadius = 3.0;
      final worldRadius = screenRadius / viewportScale;
      expect(
        manager.begin(
          event: const PointerDownEvent(
            pointer: pointer,
            position: Offset(screenRadius, 0),
          ),
          worldPosition: Offset(worldRadius, 0),
          samplingPosition: const Offset(screenRadius, 0),
          viewportScale: viewportScale,
          style: const ActivePenStyle(type: InkToolType.normal, width: 4),
          authorId: 'small-writing',
        ),
        isTrue,
      );
      for (var index = 1; index < 72; index++) {
        final angle = index * math.pi * 2 / 72;
        final screen = Offset(
          math.cos(angle) * screenRadius,
          math.sin(angle) * screenRadius,
        );
        final world = screen / viewportScale;
        manager.update(
          PointerMoveEvent(pointer: pointer, position: screen),
          world,
          samplingPosition: screen,
        );
      }
      return manager.end(
        const PointerUpEvent(
          pointer: pointer,
          position: Offset(screenRadius, 0),
        ),
        Offset(worldRadius, 0),
        samplingPosition: const Offset(screenRadius, 0),
      )!;
    }

    final normalZoom = drawSmallCircle(viewportScale: 1);
    final minimumZoom = drawSmallCircle(viewportScale: .18);

    expect(
      minimumZoom.points.length,
      greaterThan(normalZoom.points.length),
      reason:
          'Small curves need more anchors while the page is strongly zoomed out.',
    );
    expect(minimumZoom.points.length, greaterThanOrEqualTo(10));
    final commands = InkPainter.debugAdaptiveCommandCounts(minimumZoom.points);
    expect(
      commands.curves,
      greaterThan(commands.lines),
      reason: 'The retained anchors must produce a predominantly curved path.',
    );
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
      maximumPointsPerChunk: InkSessionManager.markerActivePreviewPointLimit,
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
      maximumPointsPerChunk: InkSessionManager.normalActivePreviewPointLimit,
    );
  });

  test('keeps long circular repaint batches bounded and identity-stable', () {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    manager.begin(
      event: const PointerDownEvent(pointer: 18, position: Offset.zero),
      worldPosition: Offset.zero,
      style: const ActivePenStyle(type: InkToolType.normal, width: 8),
      authorId: 'bounded-batches',
    );
    _appendSpiral(manager, pointer: 18, from: 1, through: 18000);

    final frozenSegments = manager.buildFrozenPreviewStrokes();
    final before = manager.buildFrozenPreviewBatches();
    expect(frozenSegments.length, greaterThan(20));
    expect(
      before.length,
      (frozenSegments.length / InkSessionManager.maxFrozenPreviewBatchSegments)
          .ceil(),
      reason: 'A circular stroke should pack several chunks into each layer.',
    );
    _expectBoundedBatches(before, frozenSegments);

    final unchangedSnapshot = manager.buildFrozenPreviewBatches();
    _movePendingEndpointNearAnchor(manager, pointer: 18);
    expect(
      identical(manager.buildFrozenPreviewBatches(), unchangedSnapshot),
      isTrue,
      reason: 'An ordinary MOVE must not rebuild any frozen batch list.',
    );

    final sealedBefore = before.take(before.length - 1).toList();
    final frozenCount = frozenSegments.length;
    var nextPoint = 18001;
    while (manager.buildFrozenPreviewStrokes().length == frozenCount) {
      _appendSpiral(manager, pointer: 18, from: nextPoint, through: nextPoint);
      nextPoint++;
      expect(nextPoint, lessThan(19000));
    }
    final after = manager.buildFrozenPreviewBatches();
    for (var index = 0; index < sealedBefore.length; index++) {
      expect(
        identical(after[index], sealedBefore[index]),
        isTrue,
        reason: 'Sealed batch $index must retain its cache identity.',
      );
    }
    _expectBoundedBatches(after, manager.buildFrozenPreviewStrokes());
  });

  test('preserves every horizontal chunk in its batch bounds', () {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    manager.begin(
      event: const PointerDownEvent(pointer: 19, position: Offset.zero),
      worldPosition: Offset.zero,
      style: const ActivePenStyle(type: InkToolType.normal, width: 8),
      authorId: 'horizontal-bounds',
    );
    _appendHorizontalLine(manager, pointer: 19, from: 1, through: 2400);

    final frozen = manager.buildFrozenPreviewStrokes();
    final batches = manager.buildFrozenPreviewBatches();
    expect(frozen, isNotEmpty);
    expect(batches, isNotEmpty);
    expect(batches.first.worldBounds.left, frozen.first.bounds.left);
    expect(
      batches.first.worldBounds.right,
      batches.first.strokes.last.bounds.right,
    );
    expect(batches.first.worldBounds.height, greaterThanOrEqualTo(0));
    _expectBoundedBatches(batches, frozen);
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
      maximumPointsPerChunk: InkSessionManager.normalActivePreviewPointLimit,
    );
  });

  test('reuses stable active InkPoints while only the endpoint moves', () {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    manager.begin(
      event: const PointerDownEvent(pointer: 29, position: Offset.zero),
      worldPosition: Offset.zero,
      style: const ActivePenStyle(type: InkToolType.normal),
      authorId: 'active-point-cache',
    );
    _appendLine(manager, pointer: 29, from: 1, through: 24);

    final before = manager.buildActivePreviewStrokes().single;
    expect(before.points.length, greaterThan(2));
    expect(
      identical(manager.buildActivePreviewStrokes().single, before),
      isTrue,
      reason: 'A parent rebuild without new input must reuse the snapshot.',
    );

    _movePendingEndpointNearAnchor(manager, pointer: 29);
    final after = manager.buildActivePreviewStrokes().single;
    expect(after.points, hasLength(before.points.length));
    expect(identical(after, before), isFalse);
    for (var index = 0; index < before.points.length - 1; index++) {
      expect(
        identical(after.points[index], before.points[index]),
        isTrue,
        reason: 'Stable point $index was allocated again.',
      );
    }
    expect(identical(after.points.last, before.points.last), isFalse);
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
    _expectBoundedChunks(
      previews,
      sampledPointCount: manager.sessions[17]!.sampler.samples.length,
      maximumPointsPerChunk: InkSessionManager.dashedActivePreviewPointLimit,
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

void _appendHorizontalLine(
  InkSessionManager manager, {
  required int pointer,
  required int from,
  required int through,
}) {
  for (var index = from; index <= through; index++) {
    final point = Offset(index * 2, 0);
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

void _expectBoundedBatches(
  List<FrozenInkPreviewBatch> batches,
  List<InkStroke> frozenSegments,
) {
  expect(batches, isNotEmpty);
  expect(
    batches.every(
      (batch) =>
          batch.strokes.isNotEmpty &&
          batch.strokes.length <=
              InkSessionManager.maxFrozenPreviewBatchSegments &&
          batch.pointCount <= InkSessionManager.maxFrozenPreviewBatchPoints &&
          batch.pointCount ==
              batch.strokes.fold<int>(
                0,
                (total, stroke) => total + stroke.points.length,
              ),
    ),
    isTrue,
  );
  final flattened = batches.expand((batch) => batch.strokes).toList();
  expect(flattened.length, frozenSegments.length);
  for (var index = 0; index < frozenSegments.length; index++) {
    expect(identical(flattened[index], frozenSegments[index]), isTrue);
  }
}

void _movePendingEndpointNearAnchor(
  InkSessionManager manager, {
  required int pointer,
}) {
  final samples = manager.sessions[pointer]!.sampler.samples;
  final anchor = samples[samples.length - 2].position;
  final next = anchor + const Offset(.1, 0);
  manager.update(
    PointerMoveEvent(pointer: pointer, position: next),
    next,
    samplingPosition: next,
  );
}
