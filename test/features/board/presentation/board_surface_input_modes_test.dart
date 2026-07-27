import 'dart:io';
import 'dart:math' as math;

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/features/board/engine/input_policy.dart';
import 'package:flowboard_x/src/features/board/presentation/board_pointer_indicator.dart';
import 'package:flowboard_x/src/features/board/presentation/board_surface.dart';
import 'package:flowboard_x/src/features/editor/board_participant_controller.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<EditorController> pumpBoard(
    WidgetTester tester, {
    bool fingerDrawingEnabled = false,
    EmptyBoardLongPress? onEmptyLongPress,
    bool withParticipantController = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    final controller = EditorController(
      document: WhiteboardDocument.create(id: 'input-mode-test'),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    final participant = withParticipantController
        ? BoardParticipantController(id: 'primary')
        : null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BoardSurface(
            controller: controller,
            participant: participant,
            fingerDrawingEnabled: fingerDrawingEnabled,
            onEmptyLongPress: onEmptyLongPress,
          ),
        ),
      ),
    );
    await tester.pump();
    addTearDown(() async {
      await controller.close();
      controller.dispose();
      participant?.dispose();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    return controller;
  }

  testWidgets('finger drawing remains disabled by default', (tester) async {
    final controller = await pumpBoard(tester);
    final gesture = await tester.startGesture(
      const Offset(180, 220),
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveTo(const Offset(260, 260));
    await gesture.up();
    await tester.pump();

    expect(controller.page.strokes, isEmpty);
    expect(controller.selectedIds, isEmpty);
    expect(controller.viewport.offset, isNot(Offset.zero));
    await controller.flush();
  });

  testWidgets(
    'stationary finger tap selects an object when finger drawing is disabled',
    (tester) async {
      final controller = await pumpBoard(tester);
      controller.addShape(
        ShapeKind.rectangle,
        const Rect.fromLTWH(200, 180, 220, 140),
      );
      final objectId = controller.page.objects.single.id;
      controller.clearSelection();
      await tester.pump();
      final viewportOffset = controller.viewport.offset;

      final tap = await tester.startGesture(
        const Offset(300, 240),
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );
      await tap.up();
      await tester.pump();

      expect(controller.page.strokes, isEmpty);
      expect(controller.selectedIds, <String>{objectId});
      expect(controller.viewport.offset, viewportOffset);
      await controller.flush();
    },
  );

  testWidgets(
    'finger drags a selected item live in participant pen mode and commits once',
    (tester) async {
      final controller = await pumpBoard(
        tester,
        withParticipantController: true,
      );
      controller.addShape(
        ShapeKind.rectangle,
        const Rect.fromLTWH(200, 180, 220, 140),
      );
      final objectId = controller.page.objects.single.id;
      controller.clearSelection();
      await tester.pump();

      final select = await tester.startGesture(
        const Offset(300, 240),
        pointer: 71,
        kind: PointerDeviceKind.touch,
      );
      await select.up();
      await tester.pump();
      expect(controller.selectedIds, <String>{objectId});

      final before = controller.page.objects.single.transform;
      final historyBeforeMove = controller.history.undoDepth;
      final drag = await tester.startGesture(
        const Offset(300, 240),
        pointer: 72,
        kind: PointerDeviceKind.touch,
      );
      await drag.moveTo(const Offset(330, 260));
      await tester.pump();

      // Preview rendering follows every move while the durable page remains
      // unchanged until pointer-up.
      expect(controller.page.objects.single.transform.x, before.x);
      expect(controller.page.objects.single.transform.y, before.y);
      expect(
        controller.renderObjects.single.transform.x,
        closeTo(before.x + 30, .01),
      );
      expect(
        controller.renderObjects.single.transform.y,
        closeTo(before.y + 20, .01),
      );

      await drag.moveTo(const Offset(365, 275));
      await tester.pump();
      expect(
        controller.renderObjects.single.transform.x,
        closeTo(before.x + 65, .01),
      );
      expect(
        controller.renderObjects.single.transform.y,
        closeTo(before.y + 35, .01),
      );

      await drag.up();
      await tester.pump();

      final committed = controller.page.objects.single.transform;
      expect(committed.x, closeTo(before.x + 65, .01));
      expect(committed.y, closeTo(before.y + 35, .01));
      expect(controller.history.undoDepth, historyBeforeMove + 1);

      controller.undo();
      expect(controller.page.objects.single.transform, before);
      await controller.flush();
    },
  );

  testWidgets(
    'stylus down cancels a touch selection preview and touch up cannot replay it',
    (tester) async {
      final controller = await pumpBoard(
        tester,
        withParticipantController: true,
      );
      controller.addShape(
        ShapeKind.rectangle,
        const Rect.fromLTWH(200, 180, 220, 140),
      );
      final objectId = controller.page.objects.single.id;
      controller.clearSelection();
      await tester.pump();

      final select = await tester.startGesture(
        const Offset(300, 240),
        pointer: 101,
        kind: PointerDeviceKind.touch,
      );
      await select.up();
      await tester.pump();
      expect(controller.selectedIds, <String>{objectId});

      final original = controller.page.objects.single.transform;
      final hand = await tester.startGesture(
        const Offset(300, 240),
        pointer: 102,
        kind: PointerDeviceKind.touch,
      );
      await hand.moveTo(const Offset(350, 270));
      await tester.pump();
      expect(controller.renderObjects.single.transform.x, original.x + 50);

      final pen = await tester.startGesture(
        const Offset(520, 120),
        pointer: 103,
        kind: PointerDeviceKind.stylus,
      );
      expect(controller.inkSessions.hasActiveStylus, isTrue);
      expect(controller.renderObjects.single.transform, original);

      // The old hand pointer remains down, but is latched as ignored.
      await hand.moveTo(const Offset(390, 300));
      await hand.up();
      await pen.moveTo(const Offset(570, 150));
      await pen.up();
      await tester.pump();

      expect(controller.page.objects.single.transform, original);
      expect(controller.page.strokes, hasLength(1));
      expect(controller.inkSessions.isWriting, isFalse);
      await controller.flush();
    },
  );

  testWidgets(
    'stylus down rolls back touch pan and stationary later touch up is inert',
    (tester) async {
      final controller = await pumpBoard(tester);
      final initialScale = controller.viewport.scale;
      final initialOffset = controller.viewport.offset;
      final hand = await tester.startGesture(
        const Offset(620, 420),
        pointer: 111,
        kind: PointerDeviceKind.touch,
      );
      await hand.moveTo(const Offset(680, 450));
      expect(controller.viewport.offset, isNot(initialOffset));

      final pen = await tester.startGesture(
        const Offset(140, 140),
        pointer: 112,
        kind: PointerDeviceKind.stylus,
      );
      expect(controller.inkSessions.hasActiveStylus, isTrue);
      expect(controller.viewport.scale, initialScale);
      expect(controller.viewport.offset, initialOffset);

      await pen.moveTo(const Offset(200, 180));
      await pen.up();
      // Releasing the old contact after the pen must not select or recommit
      // the provisional camera.
      await hand.up();
      await tester.pump();

      expect(controller.viewport.scale, initialScale);
      expect(controller.viewport.offset, initialOffset);
      expect(controller.selectedIds, isEmpty);
      expect(controller.page.strokes, hasLength(1));
      await controller.flush();
    },
  );

  testWidgets(
    'stylus replaces provisional finger ink without a leaked session',
    (tester) async {
      final controller = await pumpBoard(tester, fingerDrawingEnabled: true);
      final hand = await tester.startGesture(
        const Offset(260, 260),
        pointer: 121,
        kind: PointerDeviceKind.touch,
      );
      await hand.moveTo(const Offset(330, 300));
      expect(controller.inkSessions.isWriting, isTrue);

      final pen = await tester.startGesture(
        const Offset(500, 180),
        pointer: 122,
        kind: PointerDeviceKind.stylus,
      );
      expect(controller.inkSessions.sessions.keys, <int>{122});
      await pen.moveTo(const Offset(560, 220));
      await hand.up();
      await pen.up();
      await tester.pump();

      expect(controller.inkSessions.isWriting, isFalse);
      expect(controller.page.strokes, hasLength(1));
      expect(controller.page.strokes.single.pointerId, 122);
      await controller.flush();
    },
  );

  testWidgets('stylus rolls back a provisional touch eraser', (tester) async {
    final controller = await pumpBoard(tester);
    final initialInk = await tester.startGesture(
      const Offset(260, 260),
      pointer: 131,
      kind: PointerDeviceKind.stylus,
    );
    await initialInk.moveTo(const Offset(420, 260));
    await initialInk.up();
    await tester.pump();
    final existingId = controller.page.strokes.single.id;

    const palmDown = PointerDownEvent(
      pointer: 132,
      device: 132,
      kind: PointerDeviceKind.touch,
      position: Offset(340, 260),
      radiusMajor: 34,
      radiusMinor: 18,
      size: .36,
    );
    await tester.sendEventToBinding(palmDown);

    final pen = await tester.startGesture(
      const Offset(520, 380),
      pointer: 133,
      kind: PointerDeviceKind.stylus,
    );
    expect(controller.inkSessions.hasActiveStylus, isTrue);
    expect(controller.page.strokeById(existingId), isNotNull);

    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 132,
        device: 132,
        kind: PointerDeviceKind.touch,
        position: Offset(340, 260),
        radiusMajor: 34,
        radiusMinor: 18,
        size: .36,
      ),
    );
    await pen.moveTo(const Offset(580, 420));
    await pen.up();
    await tester.pump();

    expect(controller.page.strokeById(existingId), isNotNull);
    expect(controller.page.strokes, hasLength(2));
    expect(controller.inkSessions.isWriting, isFalse);
    await controller.flush();
  });

  testWidgets(
    'stylus arbitration does not cancel the other participant touch transform',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      final owner = EditorController(
        document: WhiteboardDocument.create(id: 'split-arbitration'),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      final secondary = EditorController.participantView(
        owner,
        participantId: 'right',
      );
      final leftParticipant = BoardParticipantController(id: 'left');
      final rightParticipant = BoardParticipantController(id: 'right');
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await secondary.close();
        secondary.dispose();
        await owner.close();
        owner.dispose();
        leftParticipant.dispose();
        rightParticipant.dispose();
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      owner.addShape(
        ShapeKind.rectangle,
        const Rect.fromLTWH(100, 180, 220, 140),
      );
      owner.clearSelection();
      secondary.selectAt(const Offset(200, 240));
      final objectId = secondary.page.objects.single.id;
      final original = secondary.page.objects.single.transform;

      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              Expanded(
                child: BoardSurface(
                  controller: owner,
                  participant: leftParticipant,
                  participantId: 'left',
                ),
              ),
              Expanded(
                child: BoardSurface(
                  controller: secondary,
                  participant: rightParticipant,
                  participantId: 'right',
                ),
              ),
            ],
          ),
        ),
      );

      final rightHand = await tester.startGesture(
        const Offset(600, 240),
        pointer: 141,
        kind: PointerDeviceKind.touch,
      );
      await rightHand.moveTo(const Offset(635, 265));
      await tester.pump();
      expect(
        secondary.renderObjects.single.transform.x,
        closeTo(original.x + 35, .01),
      );

      final leftPen = await tester.startGesture(
        const Offset(120, 120),
        pointer: 142,
        kind: PointerDeviceKind.stylus,
      );
      expect(owner.inkSessions.hasActiveStylus, isTrue);
      // The right controller owns its own pointer sessions and transform lock.
      expect(secondary.selectedIds, <String>{objectId});
      expect(
        secondary.renderObjects.single.transform.x,
        closeTo(original.x + 35, .01),
      );

      await leftPen.moveTo(const Offset(180, 150));
      await leftPen.up();
      await rightHand.up();
      await tester.pump();

      expect(
        secondary.page.objects.single.transform.x,
        closeTo(original.x + 35, .01),
      );
      expect(owner.page.strokes, hasLength(1));
      await owner.flush();
    },
  );

  testWidgets('two-finger pinch never opens the empty-board long-press menu', (
    tester,
  ) async {
    var longPressCount = 0;
    final controller = await pumpBoard(
      tester,
      onEmptyLongPress: (_, _) => longPressCount++,
    );

    final first = await tester.startGesture(
      const Offset(260, 280),
      pointer: 3,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 120));
    final second = await tester.startGesture(
      const Offset(420, 280),
      pointer: 4,
      kind: PointerDeviceKind.touch,
    );
    await second.moveTo(const Offset(500, 280));
    await tester.pump(const Duration(milliseconds: 120));

    // Keep the original finger down past the long-press deadline after the
    // second finger leaves. The completed multi-touch gesture must stay
    // latched until every participating pointer is released.
    await second.up();
    await tester.pump(kLongPressTimeout);

    expect(longPressCount, 0);
    expect(controller.viewport.scale, greaterThan(1));

    await first.up();
    await tester.pump();
    expect(longPressCount, 0);
    await controller.flush();
  });

  testWidgets('one pinch move notifies the viewport only once', (tester) async {
    final controller = await pumpBoard(tester);
    final first = await tester.startGesture(
      const Offset(260, 280),
      pointer: 5,
      kind: PointerDeviceKind.touch,
    );
    final second = await tester.startGesture(
      const Offset(420, 280),
      pointer: 6,
      kind: PointerDeviceKind.touch,
    );
    var notifications = 0;
    controller.viewport.addListener(() => notifications++);

    await second.moveTo(const Offset(500, 280));

    expect(controller.viewport.scale, greaterThan(1));
    expect(notifications, 1);

    await second.up();
    await first.up();
    await tester.pump();
    await controller.flush();
  });

  testWidgets('one finger writes when explicitly enabled', (tester) async {
    final controller = await pumpBoard(tester, fingerDrawingEnabled: true);
    final gesture = await tester.startGesture(
      const Offset(180, 220),
      pointer: 11,
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveTo(const Offset(280, 260));
    await gesture.up();
    await tester.pump();

    expect(controller.page.strokes, hasLength(1));
    expect(controller.page.strokes.single.points.length, greaterThan(1));
    await controller.flush();
  });

  testWidgets('second finger cancels provisional ink and starts navigation', (
    tester,
  ) async {
    final controller = await pumpBoard(tester, fingerDrawingEnabled: true);
    final first = await tester.startGesture(
      const Offset(180, 260),
      pointer: 21,
      kind: PointerDeviceKind.touch,
    );
    await first.moveTo(const Offset(210, 260));
    expect(controller.inkSessions.sessions, hasLength(1));

    final second = await tester.startGesture(
      const Offset(420, 260),
      pointer: 22,
      kind: PointerDeviceKind.touch,
    );
    expect(controller.inkSessions.sessions, isEmpty);
    await first.moveTo(const Offset(130, 260));
    await second.moveTo(const Offset(480, 260));
    await first.up();
    await second.up();
    await tester.pump();

    expect(controller.page.strokes, isEmpty);
    expect(controller.viewport.scale, greaterThan(1));
    await controller.flush();
  });

  testWidgets('two-finger pinch scales the current selection', (tester) async {
    final controller = await pumpBoard(tester);
    controller.addShape(
      ShapeKind.rectangle,
      const Rect.fromLTWH(200, 180, 220, 140),
    );
    await tester.pump();
    final before = controller.page.objects.single.transform;

    final first = await tester.startGesture(
      const Offset(240, 250),
      pointer: 31,
      kind: PointerDeviceKind.touch,
    );
    final second = await tester.startGesture(
      const Offset(380, 250),
      pointer: 32,
      kind: PointerDeviceKind.touch,
    );
    await second.moveTo(const Offset(470, 250));
    await tester.pump();
    await second.up();
    await first.up();
    await tester.pump();

    final after = controller.page.objects.single.transform;
    expect(after.width, greaterThan(before.width));
    expect(after.height, greaterThan(before.height));
    expect(
      after.width / after.height,
      closeTo(before.width / before.height, .02),
    );
    await controller.flush();
  });

  testWidgets('stylus eraser uses pen thickness and removes only its path', (
    tester,
  ) async {
    final controller = await pumpBoard(tester);
    final pen = await tester.startGesture(
      const Offset(120, 280),
      pointer: 41,
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveTo(const Offset(520, 280));
    await pen.up();
    await tester.pump();
    expect(controller.page.strokes, hasLength(1));

    controller
      ..updatePen(width: 24)
      ..setTool(BoardTool.eraser);
    final eraser = await tester.startGesture(
      const Offset(320, 230),
      pointer: 42,
      kind: PointerDeviceKind.stylus,
    );
    await eraser.moveTo(const Offset(320, 330));
    await eraser.up();
    await tester.pump();

    expect(controller.page.strokes, hasLength(2));
    final left = controller.page.strokes
        .expand((stroke) => stroke.points)
        .where((point) => point.x < 320)
        .toList();
    final right = controller.page.strokes
        .expand((stroke) => stroke.points)
        .where((point) => point.x > 320)
        .toList();
    expect(left, isNotEmpty);
    expect(right, isNotEmpty);
    final corridorPoints = controller.page.strokes
        .expand((stroke) => stroke.points)
        .where((point) => point.x > 309 && point.x < 331);
    expect(corridorPoints, isEmpty);
    await controller.flush();
  });

  testWidgets(
    'tool indicator follows active stylus for ink eraser and selection',
    (tester) async {
      final controller = await pumpBoard(tester);
      controller.updatePen(width: 24);

      BoardPointerIndicatorPainter painter() {
        final paint = tester.widget<CustomPaint>(
          find.byKey(const ValueKey<String>('board-pointer-indicator')),
        );
        return paint.painter! as BoardPointerIndicatorPainter;
      }

      for (final testCase
          in const <(BoardTool, BoardPointerIndicatorKind, int)>[
            (BoardTool.pen, BoardPointerIndicatorKind.ink, 71),
            (BoardTool.eraser, BoardPointerIndicatorKind.eraser, 72),
            (
              BoardTool.selectRectangle,
              BoardPointerIndicatorKind.selection,
              73,
            ),
          ]) {
        controller.setTool(testCase.$1);
        await tester.pump();
        const start = Offset(160, 180);
        const end = Offset(520, 360);
        final gesture = await tester.startGesture(
          start,
          pointer: testCase.$3,
          kind: PointerDeviceKind.stylus,
        );
        await tester.pump();

        expect(painter().indicators, hasLength(1));
        expect(painter().indicators.single.position, start);
        expect(painter().indicators.single.kind, testCase.$2);

        await gesture.moveTo(end);
        await tester.pump();

        expect(painter().indicators, hasLength(1));
        expect(painter().indicators.single.position, end);
        expect(painter().indicators.single.position, isNot(start));

        await gesture.up();
        await tester.pump();
        expect(painter().indicators, isEmpty);
        expect(painter().hoverPosition, isNull);
      }

      await controller.flush();
    },
  );

  testWidgets('broad-touch eraser indicator contains its real footprint', (
    tester,
  ) async {
    final controller = await pumpBoard(tester);
    const center = Offset(360, 260);
    const down = PointerDownEvent(
      pointer: 91,
      device: 91,
      kind: PointerDeviceKind.touch,
      position: center,
      radiusMajor: 36,
      radiusMinor: 14,
      size: .34,
    );
    await tester.sendEventToBinding(down);
    await tester.pump();

    final paint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey<String>('board-pointer-indicator')),
    );
    final painter = paint.painter! as BoardPointerIndicatorPainter;
    final indicator = painter.indicators.single;
    final footprint = controller.pointerPolicy.eraserFootprintFor(
      down,
      center: center,
    );
    final expected = footprint
        .map((stamp) => (stamp.center - center).distance + stamp.radius)
        .reduce(math.max);

    expect(indicator.kind, BoardPointerIndicatorKind.eraser);
    expect(indicator.position, center);
    expect(indicator.radius, closeTo(expected, 1e-9));

    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 91,
        device: 91,
        kind: PointerDeviceKind.touch,
        position: center,
        radiusMajor: 36,
        radiusMinor: 14,
        size: .34,
      ),
    );
    await tester.pump();
    await controller.flush();
  });
}

final class _MemoryRepository implements DocumentRepository {
  WhiteboardDocument? value;

  @override
  Future<Directory> assetDirectory(String documentId) async =>
      Directory.current;

  @override
  Future<void> delete(String documentId) async => value = null;

  @override
  Future<List<DocumentSummary>> list() async => const <DocumentSummary>[];

  @override
  Future<WhiteboardDocument?> load(String documentId) async => value;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => value;

  @override
  Future<void> save(WhiteboardDocument document) async => value = document;
}
