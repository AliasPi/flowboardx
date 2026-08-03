import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/engine/ink_session_manager.dart';
import 'package:flowboard_x/src/features/board/presentation/live_ink_preview_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('isolates frozen chunks from the moving tail', (tester) async {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    _beginLongStroke(manager);
    _appendPoints(manager, from: 1, through: 2400);
    expect(manager.buildPreviewStrokes().length, greaterThan(10));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 800,
          height: 600,
          child: LiveInkPreviewLayer(
            sessions: manager,
            worldToScreenScale: 1,
            worldToScreenOffset: Offset.zero,
          ),
        ),
      ),
    );

    final frozenFinder = _frozenPreviewPaints();
    final frozenBatches = manager.buildFrozenPreviewBatches();
    final frozenSegments = manager.buildFrozenPreviewStrokes();
    expect(frozenFinder, findsNWidgets(frozenBatches.length));
    expect(frozenBatches.length, lessThan(frozenSegments.length));
    expect(
      find.byKey(const ValueKey<String>('live-ink-active-preview-paint')),
      findsOneWidget,
    );
    final frozenSizes = frozenFinder
        .evaluate()
        .map(
          (element) => tester.getSize(
            find.byElementPredicate((candidate) {
              return identical(candidate, element);
            }),
          ),
        )
        .toList(growable: false);
    final activeSize = tester.getSize(
      find.byKey(const ValueKey<String>('live-ink-active-preview-paint')),
    );
    expect(frozenSizes.every((size) => size.width < 220), isTrue);
    expect(frozenSizes.every((size) => size.height < 220), isTrue);
    expect(activeSize.width, lessThan(220));
    expect(activeSize.height, lessThan(220));

    final frozenBefore = _frozenPaintsByKey(tester);
    final activeBefore = tester.widget<CustomPaint>(
      find.byKey(const ValueKey<String>('live-ink-active-preview-paint')),
    );
    final activePainterBefore = activeBefore.painter! as LiveInkPreviewPainter;
    expect(activeBefore.willChange, isTrue);
    expect(activePainterBefore.cachePictures, isFalse);
    expect(
      activePainterBefore.cache.entryCount,
      0,
      reason: 'A changing tail must not churn one ui.Picture per MOVE.',
    );
    _movePendingEndpointNearAnchor(manager);
    await tester.pump();
    final frozenAfter = _frozenPaintsByKey(tester);
    final activeAfter = tester.widget<CustomPaint>(
      find.byKey(const ValueKey<String>('live-ink-active-preview-paint')),
    );

    expect(frozenAfter.keys, unorderedEquals(frozenBefore.keys));
    for (final key in frozenBefore.keys) {
      expect(
        (frozenAfter[key]!.painter! as LiveInkPreviewPainter).shouldRepaint(
          frozenBefore[key]!.painter! as LiveInkPreviewPainter,
        ),
        isFalse,
        reason: 'Ordinary MOVE repainted frozen batch $key.',
      );
    }
    expect(
      (activeAfter.painter! as LiveInkPreviewPainter).shouldRepaint(
        activePainterBefore,
      ),
      isTrue,
    );
    expect((activeAfter.painter! as LiveInkPreviewPainter).cache.entryCount, 0);
  });

  testWidgets('repaints at most one existing batch at a chunk boundary', (
    tester,
  ) async {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    _beginLongStroke(manager);
    _appendPoints(manager, from: 1, through: 4200);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 800,
          height: 600,
          child: LiveInkPreviewLayer(
            sessions: manager,
            worldToScreenScale: 1,
            worldToScreenOffset: Offset.zero,
          ),
        ),
      ),
    );
    final beforePaints = _frozenPaintsByKey(tester);
    final beforeBatches = manager.buildFrozenPreviewBatches();
    final frozenSegmentCount = manager.buildFrozenPreviewStrokes().length;

    var nextPoint = 4201;
    while (manager.buildFrozenPreviewStrokes().length == frozenSegmentCount) {
      _appendPoints(manager, from: nextPoint, through: nextPoint);
      nextPoint++;
      expect(nextPoint, lessThan(5000));
    }
    await tester.pump();

    final afterPaints = _frozenPaintsByKey(tester);
    final afterBatches = manager.buildFrozenPreviewBatches();
    expect(
      afterBatches.length,
      anyOf(beforeBatches.length, beforeBatches.length + 1),
    );
    var repaintedExistingBatches = 0;
    for (final entry in beforePaints.entries) {
      final nextPaint = afterPaints[entry.key];
      expect(nextPaint, isNotNull);
      if ((nextPaint!.painter! as LiveInkPreviewPainter).shouldRepaint(
        entry.value.painter! as LiveInkPreviewPainter,
      )) {
        repaintedExistingBatches++;
      }
    }
    expect(
      repaintedExistingBatches,
      lessThanOrEqualTo(1),
      reason:
          'A new frozen chunk may update only its bounded open batch; '
          'sealed batches must remain inert.',
    );
    expect(
      afterPaints.values.every(
        (paint) =>
            (paint.painter! as LiveInkPreviewPainter).strokes.length <=
            InkSessionManager.maxFrozenPreviewBatchSegments,
      ),
      isTrue,
    );
  });

  test('reuses a frozen vector picture while the live tail grows', () {
    final manager = InkSessionManager();
    final cache = LiveInkPictureCache();
    addTearDown(manager.dispose);
    addTearDown(cache.dispose);
    _beginLongStroke(manager);
    _appendPoints(manager, from: 1, through: 450);

    final before = manager.buildPreviewStrokes();
    final frozenStroke = before.first;
    final frozenPicture = cache.pictureFor(frozenStroke);

    _appendPoints(manager, from: 451, through: 1200);
    final after = manager.buildPreviewStrokes();
    expect(identical(after.first, frozenStroke), isTrue);
    expect(identical(cache.pictureFor(after.first), frozenPicture), isTrue);

    final recorder = ui.PictureRecorder();
    final painter = LiveInkPreviewPainter(
      strokes: after,
      worldToScreenScale: 1,
      worldToScreenOffset: Offset.zero,
      cache: cache,
    );
    expect(
      () => painter.paint(ui.Canvas(recorder), const Size(1600, 1200)),
      returnsNormally,
    );
    recorder.endRecording().dispose();
    expect(cache.entryCount, after.length);
  });

  testWidgets('keeps vector caches isolated per simultaneous pointer', (
    tester,
  ) async {
    final manager = InkSessionManager();
    addTearDown(manager.dispose);
    _beginLongStroke(manager, pointer: 27, center: const Offset(220, 220));
    _beginLongStroke(manager, pointer: 28, center: const Offset(580, 340));
    _appendPoints(
      manager,
      pointer: 27,
      center: const Offset(220, 220),
      from: 1,
      through: 720,
    );
    _appendPoints(
      manager,
      pointer: 28,
      center: const Offset(580, 340),
      from: 1,
      through: 720,
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 800,
          height: 600,
          child: LiveInkPreviewLayer(
            sessions: manager,
            worldToScreenScale: 1,
            worldToScreenOffset: Offset.zero,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('live-ink-pointer-27')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('live-ink-pointer-28')),
      findsOneWidget,
    );
    final frozenPaints = tester
        .widgetList<CustomPaint>(_frozenPreviewPaints())
        .toList(growable: false);
    expect(frozenPaints.length, greaterThanOrEqualTo(2));
    final painters = frozenPaints
        .map((paint) => paint.painter! as LiveInkPreviewPainter)
        .toList(growable: false);
    expect(
      painters.map((painter) => painter.cache).toSet(),
      hasLength(painters.length),
    );
    expect(painters.every((painter) => painter.cache.entryCount > 0), isTrue);
    final rightBefore = <String, (LiveInkPictureCache, int)>{
      for (final entry in _frozenPaintsByKey(tester).entries)
        if (entry.key.contains('live-28-batch-'))
          entry.key: (
            (entry.value.painter! as LiveInkPreviewPainter).cache,
            (entry.value.painter! as LiveInkPreviewPainter).cache.entryCount,
          ),
    };
    expect(rightBefore, isNotEmpty);
    _movePendingEndpointNearAnchor(manager, pointer: 27);
    await tester.pump();
    final after = _frozenPaintsByKey(tester);
    for (final entry in rightBefore.entries) {
      final next = after[entry.key]!.painter! as LiveInkPreviewPainter;
      expect(identical(next.cache, entry.value.$1), isTrue);
      expect(next.cache.entryCount, entry.value.$2);
    }
  });
}

void _beginLongStroke(
  InkSessionManager manager, {
  int pointer = 27,
  Offset center = const Offset(320, 240),
}) {
  expect(
    manager.begin(
      event: PointerDownEvent(pointer: pointer, position: center),
      worldPosition: center,
      samplingPosition: center,
      style: const ActivePenStyle(type: InkToolType.normal, width: 8),
      authorId: 'preview-cache',
    ),
    isTrue,
  );
}

void _appendPoints(
  InkSessionManager manager, {
  int pointer = 27,
  Offset center = const Offset(320, 240),
  required int from,
  required int through,
}) {
  for (var index = from; index <= through; index++) {
    final angle = index * .18;
    final point = Offset(
      center.dx + math.cos(angle) * 72,
      center.dy + math.sin(angle) * 72,
    );
    manager.update(
      PointerMoveEvent(pointer: pointer, position: point),
      point,
      samplingPosition: point,
    );
  }
}

void _movePendingEndpointNearAnchor(
  InkSessionManager manager, {
  int pointer = 27,
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

Finder _frozenPreviewPaints() => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return widget is CustomPaint &&
      key is ValueKey<String> &&
      key.value.startsWith('live-ink-frozen-preview-paint-');
});

Map<String, CustomPaint> _frozenPaintsByKey(WidgetTester tester) {
  final result = <String, CustomPaint>{};
  for (final paint in tester.widgetList<CustomPaint>(_frozenPreviewPaints())) {
    result[(paint.key! as ValueKey<String>).value] = paint;
  }
  return result;
}
