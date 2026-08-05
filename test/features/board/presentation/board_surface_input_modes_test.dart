import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/commands/document_commands.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/engine/input_policy.dart';
import 'package:flowboard_x/src/features/board/presentation/board_background.dart';
import 'package:flowboard_x/src/features/board/presentation/board_pointer_indicator.dart';
import 'package:flowboard_x/src/features/board/presentation/board_scene_layer.dart';
import 'package:flowboard_x/src/features/board/presentation/board_surface.dart';
import 'package:flowboard_x/src/features/editor/board_participant_controller.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'participant surface ignores document events for an invisible page',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      final document = WhiteboardDocument.create(id: 'off-page-notification')
          .copyWith(
            pages: <BoardPage>[
              BoardPage.empty(id: 'visible', name: 'Visible'),
              BoardPage.empty(id: 'other', name: 'Other'),
            ],
            currentPageIndex: 0,
          );
      final owner = EditorController(
        document: document,
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      final participant = EditorController.participantView(
        owner,
        participantId: 'passive',
      );
      addTearDown(() async {
        await participant.close();
        participant.dispose();
        await owner.close();
        owner.dispose();
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BoardSurface(controller: participant)),
        ),
      );
      await tester.pump();
      final before = tester.widget<BoardSceneLayer>(
        find.byType(BoardSceneLayer),
      );

      owner.execute(
        AddStrokeCommand(
          'other',
          InkStroke(
            id: 'off-page-stroke',
            points: const <InkPoint>[
              InkPoint(x: 10, y: 10),
              InkPoint(x: 20, y: 20),
            ],
          ),
        ),
      );
      await tester.pump();

      final afterInvisibleChange = tester.widget<BoardSceneLayer>(
        find.byType(BoardSceneLayer),
      );
      expect(identical(afterInvisibleChange, before), isTrue);

      owner.execute(
        AddStrokeCommand(
          'visible',
          InkStroke(
            id: 'visible-stroke',
            points: const <InkPoint>[
              InkPoint(x: 30, y: 30),
              InkPoint(x: 40, y: 40),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(
        identical(
          tester.widget<BoardSceneLayer>(find.byType(BoardSceneLayer)),
          before,
        ),
        isFalse,
      );
      await owner.flush();
    },
  );

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
    'finger can drag from empty space inside the visible selection frame',
    (tester) async {
      final controller = await pumpBoard(
        tester,
        withParticipantController: true,
      );
      controller.addShape(
        ShapeKind.rectangle,
        const Rect.fromLTWH(140, 180, 80, 80),
      );
      controller.addShape(
        ShapeKind.rectangle,
        const Rect.fromLTWH(500, 180, 80, 80),
      );
      controller.selectAll();
      await tester.pump();
      final before = controller.page.objects
          .map((object) => object.transform)
          .toList(growable: false);

      // This point is inside the aggregate selection frame but deliberately
      // outside either rectangle.
      final drag = await tester.startGesture(
        const Offset(360, 220),
        pointer: 74,
        kind: PointerDeviceKind.touch,
      );
      await drag.moveTo(const Offset(405, 250));
      await tester.pump();

      expect(controller.renderObjects[0].transform.x, closeTo(185, .01));
      expect(controller.renderObjects[0].transform.y, closeTo(210, .01));
      expect(controller.renderObjects[1].transform.x, closeTo(545, .01));
      expect(controller.renderObjects[1].transform.y, closeTo(210, .01));

      await drag.up();
      await tester.pump();
      expect(controller.page.objects[0].transform.x, closeTo(185, .01));
      expect(controller.page.objects[1].transform.x, closeTo(545, .01));

      controller.undo();
      expect(controller.page.objects[0].transform, before[0]);
      expect(controller.page.objects[1].transform, before[1]);

      // The frame is a drag target, but a stationary tap on genuinely empty
      // space still follows the board's explicit deselection rule.
      controller.selectAll();
      await tester.pump();
      expect(controller.selectedIds, hasLength(2));
      final emptyGapTap = await tester.startGesture(
        const Offset(360, 220),
        pointer: 76,
        kind: PointerDeviceKind.touch,
      );
      await emptyGapTap.up();
      await tester.pump();
      expect(controller.selectedIds, isEmpty);
      await controller.flush();
    },
  );

  testWidgets('finger tap on empty space clears the current selection', (
    tester,
  ) async {
    final controller = await pumpBoard(tester, withParticipantController: true);
    controller.addShape(
      ShapeKind.rectangle,
      const Rect.fromLTWH(180, 160, 160, 110),
    );
    await tester.pump();
    expect(controller.selectedIds, isNotEmpty);

    final tap = await tester.startGesture(
      const Offset(680, 480),
      pointer: 75,
      kind: PointerDeviceKind.touch,
    );
    await tap.up();
    await tester.pump();

    expect(controller.selectedIds, isEmpty);
    await controller.flush();
  });

  testWidgets(
    'even very broad single-finger packets keep selection ownership',
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
        pointer: 720,
        kind: PointerDeviceKind.touch,
      );
      await select.up();
      await tester.pump();
      expect(controller.selectedIds, <String>{objectId});

      final before = controller.page.objects.single.transform;

      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 721,
          device: 721,
          kind: PointerDeviceKind.touch,
          position: Offset(300, 240),
          radiusMajor: 7,
          radiusMinor: 5,
          size: .1,
          buttons: kPrimaryButton,
        ),
      );
      await tester.pump();
      expect(controller.selectedIds, <String>{objectId});

      // SMART-class panels can report an ordinary selecting finger with contact
      // axes this large. Even repeated packets must never steal destructive
      // ownership from the selection gesture.
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 721,
          device: 721,
          kind: PointerDeviceKind.touch,
          position: Offset(340, 265),
          delta: Offset(40, 25),
          radiusMajor: 60,
          radiusMinor: 35,
          size: 1,
          buttons: kPrimaryButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 721,
          device: 721,
          kind: PointerDeviceKind.touch,
          position: Offset(360, 280),
          delta: Offset(20, 15),
          radiusMajor: 60,
          radiusMinor: 35,
          size: 1,
          buttons: kPrimaryButton,
        ),
      );
      await tester.pump();

      expect(
        controller.renderObjects.single.transform.x,
        closeTo(before.x + 60, .01),
      );
      expect(
        controller.renderObjects.single.transform.y,
        closeTo(before.y + 40, .01),
      );
      expect(controller.page.strokes, isEmpty);

      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 721,
          device: 721,
          kind: PointerDeviceKind.touch,
          position: Offset(360, 280),
          radiusMajor: 60,
          radiusMinor: 35,
          size: 1,
        ),
      );
      await tester.pump();

      expect(
        controller.page.objects.single.transform.x,
        closeTo(before.x + 60, .01),
      );
      expect(
        controller.page.objects.single.transform.y,
        closeTo(before.y + 40, .01),
      );
      await controller.flush();
    },
  );

  testWidgets(
    'first finger drag pans without selecting or moving an unselected item',
    (tester) async {
      final controller = await pumpBoard(
        tester,
        withParticipantController: true,
      );
      controller.addShape(
        ShapeKind.rectangle,
        const Rect.fromLTWH(200, 180, 220, 140),
      );
      controller.clearSelection();
      await tester.pump();
      final before = controller.page.objects.single.transform;
      final historyBeforeMove = controller.history.undoDepth;

      final drag = await tester.startGesture(
        const Offset(300, 240),
        pointer: 73,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      expect(controller.selectedIds, isEmpty);

      await drag.moveTo(const Offset(350, 270));
      await tester.pump();
      expect(controller.page.objects.single.transform, before);
      expect(controller.renderObjects.single.transform, before);

      await drag.up();
      await tester.pump();
      expect(controller.page.objects.single.transform, before);
      expect(controller.selectedIds, isEmpty);
      expect(controller.history.undoDepth, historyBeforeMove);
      expect(controller.viewport.offset, isNot(Offset.zero));
      await controller.flush();
    },
  );

  testWidgets('finger pans over an unselected item with shape tool active', (
    tester,
  ) async {
    final controller = await pumpBoard(tester);
    controller.addShape(
      ShapeKind.rectangle,
      const Rect.fromLTWH(200, 180, 220, 140),
    );
    controller.clearSelection();
    controller.armShape(ShapeKind.ellipse);
    await tester.pump();
    final before = controller.page.objects.single.transform;

    final drag = await tester.startGesture(
      const Offset(300, 240),
      pointer: 76,
      kind: PointerDeviceKind.touch,
    );
    await drag.moveTo(const Offset(345, 265));
    await tester.pump();

    expect(controller.selectedIds, isEmpty);
    expect(controller.renderObjects.single.transform, before);
    expect(controller.page.objects, hasLength(1));

    await drag.up();
    await tester.pump();
    expect(controller.page.objects.single.transform, before);
    expect(controller.selectedIds, isEmpty);
    expect(controller.viewport.offset, isNot(Offset.zero));
    expect(controller.page.objects, hasLength(1));
    await controller.flush();
  });

  testWidgets(
    'finger drag on empty space pans instead of drawing with shape tool',
    (tester) async {
      final controller = await pumpBoard(tester);
      controller.armShape(ShapeKind.rectangle);
      await tester.pump();

      final drag = await tester.startGesture(
        const Offset(180, 220),
        pointer: 77,
        kind: PointerDeviceKind.touch,
      );
      await drag.moveTo(const Offset(260, 270));
      await drag.up();
      await tester.pump();

      expect(controller.viewport.offset, isNot(Offset.zero));
      expect(controller.page.objects, isEmpty);
      expect(controller.page.strokes, isEmpty);
      await controller.flush();
    },
  );

  testWidgets('pressed normal finger is never routed to the eraser', (
    tester,
  ) async {
    final controller = await pumpBoard(tester);
    final viewportBefore = controller.viewport.offset;

    // 20x13 is intentionally a broad low-level contact for compatibility
    // with unusual panels, but is not strong enough to destructively take
    // over the complete BoardSurface.
    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: 771,
        device: 771,
        kind: PointerDeviceKind.touch,
        position: Offset(180, 220),
        radiusMajor: 20,
        radiusMinor: 13,
        size: .25,
        buttons: kPrimaryButton,
      ),
    );
    await tester.sendEventToBinding(
      const PointerMoveEvent(
        pointer: 771,
        device: 771,
        kind: PointerDeviceKind.touch,
        position: Offset(260, 270),
        delta: Offset(80, 50),
        radiusMajor: 20,
        radiusMinor: 13,
        size: .25,
        buttons: kPrimaryButton,
      ),
    );
    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 771,
        device: 771,
        kind: PointerDeviceKind.touch,
        position: Offset(260, 270),
        radiusMajor: 20,
        radiusMinor: 13,
        size: .25,
      ),
    );
    await tester.pump();

    expect(controller.viewport.offset, isNot(viewportBefore));
    expect(controller.page.strokes, isEmpty);
    await controller.flush();
  });

  for (final tool in <BoardTool>[
    BoardTool.selectRectangle,
    BoardTool.selectLasso,
  ]) {
    testWidgets('${tool.name} keeps one-finger empty-space drag as selection', (
      tester,
    ) async {
      final controller = await pumpBoard(tester);
      controller.addShape(
        ShapeKind.rectangle,
        const Rect.fromLTWH(300, 240, 50, 50),
      );
      final objectId = controller.page.objects.single.id;
      controller.clearSelection();
      controller.setTool(tool);
      await tester.pump();
      final viewportBefore = controller.viewport.offset;

      final gesture = await tester.startGesture(
        const Offset(250, 200),
        pointer: tool == BoardTool.selectRectangle ? 74 : 75,
        kind: PointerDeviceKind.touch,
      );
      if (tool == BoardTool.selectRectangle) {
        await gesture.moveTo(const Offset(400, 350));
      } else {
        await gesture.moveTo(const Offset(400, 200));
        await gesture.moveTo(const Offset(400, 350));
        await gesture.moveTo(const Offset(250, 350));
        await gesture.moveTo(const Offset(250, 240));
      }
      await gesture.up();
      await tester.pump();

      expect(controller.selectedIds, <String>{objectId});
      expect(controller.viewport.offset, viewportBefore);
      await controller.flush();
    });
  }

  testWidgets(
    'participant pinch over unselected content only zooms when finger ink is off',
    (tester) async {
      final controller = await pumpBoard(
        tester,
        withParticipantController: true,
      );
      controller.addShape(
        ShapeKind.rectangle,
        const Rect.fromLTWH(180, 200, 300, 160),
      );
      controller.clearSelection();
      await tester.pump();
      final original = controller.page.objects.single.transform;
      final scaleBefore = controller.viewport.scale;

      final first = await tester.startGesture(
        const Offset(260, 280),
        pointer: 82,
        kind: PointerDeviceKind.touch,
      );
      await first.moveTo(const Offset(250, 280));
      expect(controller.inkSessions.sessions, isEmpty);
      expect(controller.selectedIds, isEmpty);

      final second = await tester.startGesture(
        const Offset(420, 280),
        pointer: 83,
        kind: PointerDeviceKind.touch,
      );
      await first.moveTo(const Offset(210, 280));
      await second.moveTo(const Offset(500, 280));
      await tester.pump();

      expect(controller.viewport.scale, greaterThan(scaleBefore));
      expect(controller.inkSessions.sessions, isEmpty);
      expect(controller.page.strokes, isEmpty);
      expect(controller.selectedIds, isEmpty);
      expect(controller.renderObjects.single.transform, original);

      await second.up();
      await first.up();
      await tester.pump();

      expect(controller.page.strokes, isEmpty);
      expect(controller.selectedIds, isEmpty);
      expect(controller.page.objects.single.transform, original);
      await controller.flush();
    },
  );

  testWidgets('two broad-looking fingertips remain a pinch gesture', (
    tester,
  ) async {
    final controller = await pumpBoard(tester);
    final scaleBefore = controller.viewport.scale;

    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: 821,
        device: 821,
        kind: PointerDeviceKind.touch,
        position: Offset(220, 260),
        radiusMajor: 20,
        radiusMinor: 13,
        size: .25,
        buttons: kPrimaryButton,
      ),
    );
    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: 822,
        device: 822,
        kind: PointerDeviceKind.touch,
        position: Offset(420, 260),
        radiusMajor: 26,
        radiusMinor: 10,
        size: .31,
        buttons: kPrimaryButton,
      ),
    );
    await tester.sendEventToBinding(
      const PointerMoveEvent(
        pointer: 822,
        device: 822,
        kind: PointerDeviceKind.touch,
        position: Offset(540, 260),
        delta: Offset(120, 0),
        radiusMajor: 26,
        radiusMinor: 10,
        size: .31,
        buttons: kPrimaryButton,
      ),
    );
    await tester.pump();
    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 822,
        device: 822,
        kind: PointerDeviceKind.touch,
        position: Offset(540, 260),
        radiusMajor: 26,
        radiusMinor: 10,
        size: .31,
      ),
    );
    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 821,
        device: 821,
        kind: PointerDeviceKind.touch,
        position: Offset(220, 260),
        radiusMajor: 20,
        radiusMinor: 13,
        size: .25,
      ),
    );
    await tester.pump();

    expect(controller.viewport.scale, greaterThan(scaleBefore));
    expect(controller.page.strokes, isEmpty);
    await controller.flush();
  });

  for (final tool in <BoardTool>[
    BoardTool.pen,
    BoardTool.eraser,
    BoardTool.selectRectangle,
    BoardTool.selectLasso,
    BoardTool.shape,
  ]) {
    testWidgets('two-finger pinch zooms with ${tool.name} active', (
      tester,
    ) async {
      final controller = await pumpBoard(tester);
      if (tool == BoardTool.shape) {
        controller.armShape(ShapeKind.rectangle);
      } else {
        controller.setTool(tool);
      }
      await tester.pump();
      final scaleBefore = controller.viewport.scale;

      final first = await tester.startGesture(
        const Offset(220, 260),
        pointer: 80,
        kind: PointerDeviceKind.touch,
      );
      final second = await tester.startGesture(
        const Offset(420, 260),
        pointer: 81,
        kind: PointerDeviceKind.touch,
      );
      await second.moveTo(const Offset(540, 260));
      await tester.pump();
      await second.up();
      await first.up();
      await tester.pump();

      expect(controller.viewport.scale, greaterThan(scaleBefore));
      expect(controller.page.objects, isEmpty);
      expect(controller.page.strokes, isEmpty);
      await controller.flush();
    });
  }

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
    'latched resting palm does not rebuild the board for every move packet',
    (tester) async {
      final controller = await pumpBoard(tester);
      final pen = await tester.startGesture(
        const Offset(160, 140),
        pointer: 113,
        kind: PointerDeviceKind.stylus,
      );
      final palm = await tester.startGesture(
        const Offset(360, 360),
        pointer: 114,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();

      BoardBackgroundPainter backgroundPainter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .whereType<BoardBackgroundPainter>()
          .single;

      final beforePalmMoves = backgroundPainter();
      await palm.moveTo(const Offset(362, 361));
      await tester.pump();
      expect(backgroundPainter(), same(beforePalmMoves));

      await palm.moveTo(const Offset(364, 363));
      await tester.pump();
      expect(backgroundPainter(), same(beforePalmMoves));
      expect(controller.inkSessions.hasActiveStylus, isTrue);

      await palm.up();
      await pen.moveTo(const Offset(220, 180));
      await pen.up();
      await tester.pump();

      expect(controller.page.strokes, hasLength(1));
      await controller.flush();
    },
  );

  testWidgets(
    'palm rejected by a pen stays inert until lift after the pen ends',
    (tester) async {
      final controller = await pumpBoard(tester);
      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 115,
          device: 115,
          kind: PointerDeviceKind.stylus,
          position: Offset(160, 140),
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 115,
          device: 115,
          kind: PointerDeviceKind.stylus,
          position: Offset(220, 180),
          delta: Offset(60, 40),
          buttons: kPrimaryButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 116,
          device: 116,
          kind: PointerDeviceKind.touch,
          position: Offset(360, 360),
          radiusMajor: 36,
          radiusMinor: 20,
          size: .36,
        ),
      );
      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 115,
          device: 115,
          kind: PointerDeviceKind.stylus,
          position: Offset(240, 200),
        ),
      );
      expect(controller.page.strokes, hasLength(1));

      // Even a broad packet over the just-finished line must not turn the
      // already rejected resting hand into an eraser after the pen lifts.
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 116,
          device: 116,
          kind: PointerDeviceKind.touch,
          position: Offset(200, 170),
          delta: Offset(-160, -190),
          radiusMajor: 36,
          radiusMinor: 20,
          size: .36,
          buttons: kPrimaryButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 116,
          device: 116,
          kind: PointerDeviceKind.touch,
          position: Offset(200, 170),
          radiusMajor: 36,
          radiusMinor: 20,
          size: .36,
        ),
      );
      await tester.pump();

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

  testWidgets('starting ink removes the expensive transient navigator', (
    tester,
  ) async {
    final controller = await pumpBoard(tester);
    final first = await tester.startGesture(
      const Offset(280, 300),
      pointer: 91,
      kind: PointerDeviceKind.touch,
    );
    final second = await tester.startGesture(
      const Offset(520, 300),
      pointer: 92,
      kind: PointerDeviceKind.touch,
    );
    await second.moveTo(const Offset(590, 300));
    await tester.pump();
    expect(find.byKey(const ValueKey('board-navigator')), findsOneWidget);

    final pen = await tester.startGesture(
      const Offset(360, 220),
      pointer: 93,
      kind: PointerDeviceKind.stylus,
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('board-navigator')), findsNothing);

    await pen.up();
    await first.up();
    await second.up();
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
    final viewportScaleBefore = controller.viewport.scale;

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
    expect(controller.viewport.scale, viewportScaleBefore);
    await controller.flush();
  });

  testWidgets('two-finger pinch zooms while rectangle selection is active', (
    tester,
  ) async {
    final controller = await pumpBoard(tester);
    controller.setTool(BoardTool.selectRectangle);
    await tester.pump();
    final scaleBefore = controller.viewport.scale;

    final first = await tester.startGesture(
      const Offset(220, 260),
      pointer: 33,
      kind: PointerDeviceKind.touch,
    );
    final second = await tester.startGesture(
      const Offset(420, 260),
      pointer: 34,
      kind: PointerDeviceKind.touch,
    );
    await second.moveTo(const Offset(540, 260));
    await tester.pump();
    await second.up();
    await first.up();
    await tester.pump();

    expect(controller.viewport.scale, greaterThan(scaleBefore));
    expect(controller.selectedIds, isEmpty);
    expect(controller.page.objects, isEmpty);
    await controller.flush();
  });

  testWidgets(
    'pinch outside selected content zooms without transforming the selection',
    (tester) async {
      final controller = await pumpBoard(tester);
      controller.addShape(
        ShapeKind.rectangle,
        const Rect.fromLTWH(200, 160, 220, 140),
      );
      await tester.pump();
      final objectBefore = controller.page.objects.single.transform;
      final scaleBefore = controller.viewport.scale;

      final first = await tester.startGesture(
        const Offset(500, 420),
        pointer: 35,
        kind: PointerDeviceKind.touch,
      );
      final second = await tester.startGesture(
        const Offset(660, 420),
        pointer: 36,
        kind: PointerDeviceKind.touch,
      );
      await second.moveTo(const Offset(760, 420));
      await tester.pump();
      await second.up();
      await first.up();
      await tester.pump();

      expect(controller.viewport.scale, greaterThan(scaleBefore));
      expect(controller.page.objects.single.transform, objectBefore);
      await controller.flush();
    },
  );

  testWidgets('automatic stylus eraser removes only its own path', (
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
        final indicatorPaintSize = tester.getSize(
          find.byKey(const ValueKey<String>('board-pointer-indicator')),
        );
        expect(indicatorPaintSize.width, lessThan(350));
        expect(indicatorPaintSize.height, lessThan(350));

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

  testWidgets('single broad touch never displays a destructive indicator', (
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
    expect(painter.indicators, isEmpty);

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

  testWidgets('repeated broad single-touch moves remain non-destructive', (
    tester,
  ) async {
    final controller = await pumpBoard(tester);
    const center = Offset(360, 260);
    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: 92,
        device: 92,
        kind: PointerDeviceKind.touch,
        position: center,
        radiusMajor: 60,
        radiusMinor: 35,
        size: 1,
      ),
    );
    for (var frame = 1; frame <= 3; frame++) {
      await tester.sendEventToBinding(
        PointerMoveEvent(
          pointer: 92,
          device: 92,
          kind: PointerDeviceKind.touch,
          position: center + Offset(frame * 20, 0),
          delta: const Offset(20, 0),
          radiusMajor: 60,
          radiusMinor: 35,
          size: 1,
          buttons: kPrimaryButton,
        ),
      );
    }
    await tester.pump();
    final paint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey<String>('board-pointer-indicator')),
    );
    expect(
      (paint.painter! as BoardPointerIndicatorPainter).indicators,
      isEmpty,
    );
    expect(controller.page.strokes, isEmpty);

    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 92,
        device: 92,
        kind: PointerDeviceKind.touch,
        position: Offset(420, 260),
        radiusMajor: 60,
        radiusMinor: 35,
        size: 1,
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
