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

    expect(
      find.descendant(
        of: find.byType(LiveInkPreviewLayer),
        matching: find.byType(CustomPaint),
      ),
      findsNWidgets(2),
    );
    expect(
      find.byKey(const ValueKey<String>('live-ink-frozen-preview-paint')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('live-ink-active-preview-paint')),
      findsOneWidget,
    );

    final frozenBefore = tester.widget<CustomPaint>(
      find.byKey(const ValueKey<String>('live-ink-frozen-preview-paint')),
    );
    final activeBefore = tester.widget<CustomPaint>(
      find.byKey(const ValueKey<String>('live-ink-active-preview-paint')),
    );
    _appendPoints(manager, from: 2401, through: 2401);
    await tester.pump();
    final frozenAfter = tester.widget<CustomPaint>(
      find.byKey(const ValueKey<String>('live-ink-frozen-preview-paint')),
    );
    final activeAfter = tester.widget<CustomPaint>(
      find.byKey(const ValueKey<String>('live-ink-active-preview-paint')),
    );

    expect(
      (frozenAfter.painter! as LiveInkPreviewPainter).shouldRepaint(
        frozenBefore.painter! as LiveInkPreviewPainter,
      ),
      isFalse,
    );
    expect(
      (activeAfter.painter! as LiveInkPreviewPainter).shouldRepaint(
        activeBefore.painter! as LiveInkPreviewPainter,
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
}

void _beginLongStroke(InkSessionManager manager) {
  expect(
    manager.begin(
      event: const PointerDownEvent(pointer: 27, position: Offset.zero),
      worldPosition: Offset.zero,
      samplingPosition: Offset.zero,
      style: const ActivePenStyle(type: InkToolType.normal, width: 8),
      authorId: 'preview-cache',
    ),
    isTrue,
  );
}

void _appendPoints(
  InkSessionManager manager, {
  required int from,
  required int through,
}) {
  for (var index = from; index <= through; index++) {
    final point = Offset(index.toDouble(), 80 + (index % 120).toDouble());
    manager.update(
      PointerMoveEvent(pointer: 27, position: point),
      point,
      samplingPosition: point,
    );
  }
}
