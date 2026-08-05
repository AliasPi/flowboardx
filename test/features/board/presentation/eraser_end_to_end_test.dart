import 'dart:async';
import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/commands/document_commands.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/engine/ink_session_manager.dart';
import 'package:flowboard_x/src/features/board/engine/input_policy.dart';
import 'package:flowboard_x/src/features/board/presentation/board_pointer_indicator.dart';
import 'package:flowboard_x/src/features/board/presentation/board_surface.dart';
import 'package:flowboard_x/src/features/editor/board_participant_controller.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flowboard_x/src/features/input/eraser_contact_geometry.dart';
import 'package:flowboard_x/src/platform/android_palm_input.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  InkStroke horizontalStroke({
    String id = 'ink',
    double start = 100,
    double end = 700,
    double y = 300,
    double width = 4,
  }) => InkStroke(
    id: id,
    points: <InkPoint>[
      InkPoint(x: start, y: y),
      InkPoint(x: end, y: y),
    ],
    width: width,
  );

  WhiteboardDocument withPage(
    String id, {
    required BoardPage Function(BoardPage page) update,
  }) {
    final base = WhiteboardDocument.create(id: id);
    return base.copyWith(pages: <BoardPage>[update(base.currentPage)]);
  }

  Future<EditorController> pumpBoard(
    WidgetTester tester,
    WhiteboardDocument document, {
    BoardParticipantController? participant,
    PalmInputSource? palmInputSource,
    EdgeInsets boardPadding = EdgeInsets.zero,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    final controller = EditorController(
      document: document,
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: boardPadding,
            child: BoardSurface(
              controller: controller,
              participant: participant,
              participantId: participant?.id ?? 'primary',
              palmInputSource: palmInputSource,
            ),
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

  testWidgets('participant stylus eraser is automatic and fully undoable', (
    tester,
  ) async {
    final document = withPage(
      'stylus-eraser-e2e',
      update: (page) => page.copyWith(strokes: <InkStroke>[horizontalStroke()]),
    );
    final participant = BoardParticipantController(
      id: 'student',
      tool: BoardTool.eraser,
      penStyle: const ActivePenStyle(colorArgb: 0xFF000000, width: 30),
    );
    final controller = await pumpBoard(
      tester,
      document,
      participant: participant,
    );

    final eraser = await tester.startGesture(
      const Offset(400, 250),
      pointer: 101,
      kind: PointerDeviceKind.stylus,
    );
    await eraser.moveTo(const Offset(400, 350));
    await eraser.up();
    await tester.pump();

    expect(controller.page.strokes, hasLength(2));
    final fragments = controller.page.strokes.toList(growable: false)
      ..sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
    // Automatic 16 px screen radius plus the original stroke half-width.
    expect(fragments.first.points.last.x, closeTo(382, .01));
    expect(fragments.last.points.first.x, closeTo(418, .01));
    expect(participant.tool, BoardTool.eraser);
    expect(participant.penStyle.width, 30);

    controller.undo();
    expect(controller.page.strokes, hasLength(1));
    expect(controller.page.strokes.single.points.first.x, 100);
    expect(controller.page.strokes.single.points.last.x, 700);
    controller.redo();
    expect(controller.page.strokes, hasLength(2));
    await controller.flush();
  });

  testWidgets('participant ink thickness does not resize the eraser', (
    tester,
  ) async {
    final document = withPage(
      'stylus-eraser-width-e2e',
      update: (page) => page.copyWith(strokes: <InkStroke>[horizontalStroke()]),
    );
    final participant = BoardParticipantController(
      id: 'student',
      tool: BoardTool.eraser,
      penStyle: const ActivePenStyle(colorArgb: 0xFF000000, width: 2),
    );
    final controller = await pumpBoard(
      tester,
      document,
      participant: participant,
    );

    final fine = await tester.startGesture(
      const Offset(300, 250),
      pointer: 111,
      kind: PointerDeviceKind.stylus,
    );
    await fine.moveTo(const Offset(300, 350));
    await fine.up();
    await tester.pump();
    final fineFragments = controller.page.strokes.toList(growable: false)
      ..sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
    expect(fineFragments, hasLength(2));
    final fineGap =
        fineFragments.last.points.first.x - fineFragments.first.points.last.x;
    expect(fineGap, closeTo(36, .01));

    participant.updatePen(width: 32);
    participant.selectEraser();
    final broad = await tester.startGesture(
      const Offset(500, 250),
      pointer: 112,
      kind: PointerDeviceKind.stylus,
    );
    await broad.moveTo(const Offset(500, 350));
    await broad.up();
    await tester.pump();

    final broadFragments = controller.page.strokes.toList(growable: false)
      ..sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
    expect(broadFragments, hasLength(3));
    final broadGap =
        broadFragments.last.points.first.x -
        broadFragments[broadFragments.length - 2].points.last.x;
    expect(broadGap, closeTo(fineGap, .01));
    await controller.flush();
  });

  testWidgets(
    'stylus eraser wins over selection and splits object-bound annotation',
    (tester) async {
      const transform = ObjectTransform(
        x: 100,
        y: 100,
        width: 400,
        height: 300,
      );
      final image = ImageObject(
        id: 'image',
        assetId: 'asset',
        transform: transform,
      );
      final annotation = InkStroke(
        id: 'image-ink',
        points: const <InkPoint>[
          InkPoint(x: .1, y: .5),
          InkPoint(x: .9, y: .5),
        ],
        width: .01,
      );
      final document = withPage(
        'annotation-stylus-eraser',
        update: (page) => page.copyWith(
          objects: <BoardObject>[image],
          annotationLayers: <ObjectInkLayer>[
            ObjectInkLayer(
              id: 'image.annotations',
              objectId: image.id,
              strokes: <InkStroke>[annotation],
            ),
          ],
          selection: SelectionState(selectedItemIds: const <String>['image']),
        ),
      );
      final participant = BoardParticipantController(
        id: 'student',
        tool: BoardTool.eraser,
        penStyle: const ActivePenStyle(colorArgb: 0xFF000000, width: 20),
      );
      final controller = await pumpBoard(
        tester,
        document,
        participant: participant,
      );

      final eraser = await tester.startGesture(
        const Offset(300, 210),
        pointer: 201,
        kind: PointerDeviceKind.stylus,
      );
      await eraser.moveTo(const Offset(300, 290));
      await eraser.up();
      await tester.pump();

      expect(controller.page.objects.single.transform, transform);
      expect(controller.selectedIds, <String>{'image'});
      expect(controller.page.annotationFor('image')!.strokes, hasLength(2));
      final fragments = controller.page.annotationFor('image')!.strokes;
      expect(fragments.first.points.last.x, lessThan(.5));
      expect(fragments.last.points.first.x, greaterThan(.5));

      controller.undo();
      expect(controller.page.annotationFor('image')!.strokes, hasLength(1));
      controller.redo();
      expect(controller.page.annotationFor('image')!.strokes, hasLength(2));
      await controller.flush();
    },
  );

  testWidgets('broad single finger selects handwriting and never erases it', (
    tester,
  ) async {
    final document = withPage(
      'palm-partial-e2e',
      update: (page) => page.copyWith(strokes: <InkStroke>[horizontalStroke()]),
    );
    final controller = await pumpBoard(tester, document)
      ..setTool(BoardTool.shape);

    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: 301,
        device: 301,
        kind: PointerDeviceKind.touch,
        position: Offset(400, 300),
        radiusMajor: 60,
        radiusMinor: 35,
        size: 1,
      ),
    );
    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 301,
        device: 301,
        kind: PointerDeviceKind.touch,
        position: Offset(400, 300),
        radiusMajor: 60,
        radiusMinor: 35,
        size: 1,
      ),
    );
    await tester.pump();

    expect(controller.tool, BoardTool.shape);
    expect(controller.page.strokes, hasLength(1));
    expect(controller.selectedIds, isNotEmpty);
    expect(_strokeCrossesX(controller.page.strokes, 400), isTrue);
    expect(_strokeCrossesX(controller.page.strokes, 200), isTrue);
    expect(_strokeCrossesX(controller.page.strokes, 600), isTrue);
    await controller.flush();
  });

  testWidgets(
    'confirmed fist circle exactly matches erasing at minimum board zoom',
    (tester) async {
      final source = _PalmInputSource();
      addTearDown(source.dispose);
      final controller = await pumpBoard(
        tester,
        WhiteboardDocument.create(id: 'zoomed-fist-geometry-e2e'),
        palmInputSource: source,
      );
      controller.viewport.restore(scale: .25, offset: Offset.zero);
      const center = Offset(400, 300);
      final worldCenter = controller.viewport.screenToWorld(center);
      const strokeWidth = 4.0;
      controller.execute(
        AddStrokeCommand(
          controller.page.id,
          horizontalStroke(
            id: 'zoomed-ink',
            start: worldCenter.dx - 800,
            end: worldCenter.dx + 800,
            y: worldCenter.dy,
            width: strokeWidth,
          ),
        ),
      );
      await tester.pump();

      source.add(
        const NativePalmStroke(
          sessionId: 'zoomed-explicit-palm',
          points: <Offset>[center],
          radius: 30,
          contactCount: 1,
          source: 'tool_type_palm',
          samples: <NativePalmSample>[
            NativePalmSample(
              position: center,
              radiusMajor: 30,
              radiusMinor: 14,
              orientation: 0,
              normalizedSize: .34,
            ),
          ],
        ),
      );
      await tester.pump();

      final paint = tester.widget<CustomPaint>(
        find.byKey(const ValueKey<String>('board-pointer-indicator')),
      );
      final indicator =
          (paint.painter! as BoardPointerIndicatorPainter).indicators.single;
      expect(indicator.kind, BoardPointerIndicatorKind.eraser);
      expect(indicator.position, center);
      expect(
        indicator.radius,
        EraserContactGeometry.minimumRecognizedFistScreenRadius,
      );

      final fragments = controller.renderStrokes.toList(growable: false)
        ..sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      expect(fragments, hasLength(2));
      final worldGap =
          fragments.last.points.first.x - fragments.first.points.last.x;
      final visibleGap = worldGap * controller.viewport.scale;
      // Stroke hit testing adds half the ink width on both sides. Apart from
      // that known term, the displayed automatic circle and destructive radius
      // are identical even when world units are enlarged by a 0.25x zoom.
      expect(
        visibleGap,
        closeTo(
          indicator.radius * 2 + strokeWidth * controller.viewport.scale,
          .05,
        ),
      );

      await tester.pump(const Duration(milliseconds: 220));
      await controller.flush();
    },
  );

  testWidgets(
    'late broad single-finger metadata cannot take over handwriting selection',
    (tester) async {
      final document = withPage(
        'late-broad-fist-e2e',
        update: (page) =>
            page.copyWith(strokes: <InkStroke>[horizontalStroke()]),
      );
      final controller = await pumpBoard(tester, document)
        ..setTool(BoardTool.selectRectangle);

      // Some panels inflate the contact axes only after the selecting finger
      // settles. No later single-pointer packet may reinterpret that gesture
      // destructively.
      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 311,
          device: 311,
          kind: PointerDeviceKind.touch,
          position: Offset(320, 300),
          radiusMajor: 7,
          radiusMinor: 5,
          size: .1,
          buttons: kPrimaryButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 311,
          device: 311,
          kind: PointerDeviceKind.touch,
          position: Offset(360, 300),
          delta: Offset(40, 0),
          radiusMajor: 30,
          radiusMinor: 14,
          size: .34,
          buttons: kPrimaryButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 311,
          device: 311,
          kind: PointerDeviceKind.touch,
          position: Offset(400, 300),
          delta: Offset(40, 0),
          radiusMajor: 30,
          radiusMinor: 14,
          size: .34,
          buttons: kPrimaryButton,
        ),
      );
      await tester.pump();

      BoardPointerIndicator indicator() {
        final paint = tester.widget<CustomPaint>(
          find.byKey(const ValueKey<String>('board-pointer-indicator')),
        );
        return (paint.painter! as BoardPointerIndicatorPainter)
            .indicators
            .single;
      }

      expect(indicator().kind, BoardPointerIndicatorKind.selection);
      expect(indicator().position, const Offset(400, 300));

      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 311,
          device: 311,
          kind: PointerDeviceKind.touch,
          position: Offset(460, 300),
          delta: Offset(60, 0),
          radiusMajor: 42,
          radiusMinor: 22,
          size: .72,
          buttons: kPrimaryButton,
        ),
      );
      await tester.pump();

      expect(indicator().position, const Offset(460, 300));
      expect(indicator().kind, BoardPointerIndicatorKind.selection);

      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 311,
          device: 311,
          kind: PointerDeviceKind.touch,
          position: Offset(460, 300),
          radiusMajor: 42,
          radiusMinor: 22,
          size: .72,
        ),
      );
      await tester.pump();

      expect(controller.tool, BoardTool.selectRectangle);
      expect(controller.page.strokes, hasLength(1));
      expect(controller.selectedIds, isNotEmpty);
      expect(controller.page.strokes.single.points.first.x, closeTo(100, .01));
      expect(controller.page.strokes.single.points.last.x, closeTo(700, .01));
      await controller.flush();
    },
  );

  testWidgets(
    'shrinking fist sweep tapers to the live cursor instead of retaining its peak',
    (tester) async {
      final document = withPage(
        'tapered-fist-sweep',
        update: (page) => page.copyWith(
          strokes: <InkStroke>[
            horizontalStroke(
              id: 'inside-current',
              start: 397,
              end: 403,
              y: 340,
            ),
            horizontalStroke(
              id: 'outside-current',
              start: 397,
              end: 403,
              y: 372,
            ),
          ],
        ),
      );
      final source = _PalmInputSource();
      addTearDown(source.dispose);
      final controller = await pumpBoard(
        tester,
        document,
        palmInputSource: source,
      );

      source.add(
        const NativePalmStroke(
          sessionId: 'shrinking-explicit-palm',
          points: <Offset>[Offset(200, 300), Offset(400, 300)],
          radius: 48,
          contactCount: 1,
          source: 'tool_type_palm',
          samples: <NativePalmSample>[
            NativePalmSample(
              position: Offset(200, 300),
              radiusMajor: 48,
              radiusMinor: 24,
              orientation: 0,
              timeStamp: Duration(milliseconds: 1),
              normalizedSize: 1,
              normalizedPressure: 1,
            ),
            NativePalmSample(
              position: Offset(400, 300),
              radiusMajor: 30,
              radiusMinor: 14,
              orientation: 0,
              timeStamp: Duration(milliseconds: 201),
              normalizedSize: 1,
              normalizedPressure: 1,
            ),
          ],
        ),
      );
      await tester.pump();

      final paint = tester.widget<CustomPaint>(
        find.byKey(const ValueKey<String>('board-pointer-indicator')),
      );
      final indicator =
          (paint.painter! as BoardPointerIndicatorPainter).indicators.single;
      expect(indicator.radius, lessThan(66));

      await tester.pump(const Duration(milliseconds: 220));

      expect(controller.page.strokeById('inside-current'), isNull);
      expect(
        controller.page.strokes.map((stroke) => stroke.id),
        contains('outside-current'),
      );
      await controller.flush();
    },
  );

  testWidgets(
    'broad palm cannot erase while this participant stylus is writing',
    (tester) async {
      final document = withPage(
        'stylus-palm-rejection-e2e',
        update: (page) =>
            page.copyWith(strokes: <InkStroke>[horizontalStroke()]),
      );
      final source = _PalmInputSource();
      addTearDown(source.dispose);
      final controller = await pumpBoard(
        tester,
        document,
        palmInputSource: source,
      );
      final stylus = await tester.startGesture(
        const Offset(120, 120),
        pointer: 401,
        kind: PointerDeviceKind.stylus,
      );
      await stylus.moveTo(const Offset(180, 130));

      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 402,
          device: 402,
          kind: PointerDeviceKind.touch,
          position: Offset(380, 300),
          radiusMajor: 34,
          radiusMinor: 20,
          size: .36,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 402,
          device: 402,
          kind: PointerDeviceKind.touch,
          position: Offset(430, 300),
          delta: Offset(50, 0),
          radiusMajor: 34,
          radiusMinor: 20,
          size: .36,
        ),
      );
      source.add(
        const NativePalmStroke(
          sessionId: 'stylus-native-palm',
          points: <Offset>[Offset(380, 300), Offset(430, 300)],
          radius: 34,
          contactCount: 1,
          source: 'tool_type_palm',
        ),
      );
      // The supporting hand commonly remains on the board slightly longer
      // than the pen. Its UP must not be reinterpreted as an eraser after the
      // stylus session has already ended.
      await stylus.up();
      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 402,
          device: 402,
          kind: PointerDeviceKind.touch,
          position: Offset(430, 300),
          radiusMajor: 34,
          radiusMinor: 20,
          size: .36,
        ),
      );
      await tester.pump();

      final original = controller.page.strokes.singleWhere(
        (stroke) => stroke.id == 'ink',
      );
      expect(original.points.first.x, 100);
      expect(original.points.last.x, 700);
      expect(_strokeCrossesX(<InkStroke>[original], 400), isTrue);
      await controller.flush();
    },
  );

  testWidgets(
    'stylus cancels a broad palm preview which started just before it',
    (tester) async {
      final document = withPage(
        'palm-before-stylus-e2e',
        update: (page) =>
            page.copyWith(strokes: <InkStroke>[horizontalStroke()]),
      );
      final controller = await pumpBoard(tester, document);

      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 411,
          device: 411,
          kind: PointerDeviceKind.touch,
          position: Offset(380, 300),
          radiusMajor: 34,
          radiusMinor: 20,
          size: .36,
        ),
      );
      final stylus = await tester.startGesture(
        const Offset(120, 120),
        pointer: 412,
        kind: PointerDeviceKind.stylus,
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 411,
          device: 411,
          kind: PointerDeviceKind.touch,
          position: Offset(430, 300),
          delta: Offset(50, 0),
          radiusMajor: 34,
          radiusMinor: 20,
          size: .36,
        ),
      );
      await stylus.up();
      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 411,
          device: 411,
          kind: PointerDeviceKind.touch,
          position: Offset(430, 300),
          radiusMajor: 34,
          radiusMinor: 20,
          size: .36,
        ),
      );
      await tester.pump();

      final original = controller.page.strokes.singleWhere(
        (stroke) => stroke.id == 'ink',
      );
      expect(original.points.first.x, 100);
      expect(original.points.last.x, 700);
      expect(_strokeCrossesX(<InkStroke>[original], 400), isTrue);
      await controller.flush();
    },
  );

  testWidgets('canceled native single-finger trace cannot erase selected ink', (
    tester,
  ) async {
    final document = withPage(
      'native-single-finger-safety',
      update: (page) => page.copyWith(strokes: <InkStroke>[horizontalStroke()]),
    );
    final source = _PalmInputSource();
    addTearDown(source.dispose);
    final controller = await pumpBoard(
      tester,
      document,
      palmInputSource: source,
    );

    source.add(
      const NativePalmStroke(
        sessionId: 'canceled-finger:1',
        points: <Offset>[Offset(300, 300), Offset(500, 300)],
        radius: 100,
        contactCount: 1,
        source: 'system_canceled',
        samples: <NativePalmSample>[
          NativePalmSample(
            position: Offset(300, 300),
            radiusMajor: 100,
            radiusMinor: 60,
            orientation: 0,
            normalizedSize: 1,
            normalizedPressure: 1,
          ),
          NativePalmSample(
            position: Offset(500, 300),
            radiusMajor: 100,
            radiusMinor: 60,
            orientation: 0,
            normalizedSize: 1,
            normalizedPressure: 1,
          ),
        ],
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(controller.page.strokes, hasLength(1));
    expect(controller.page.strokes.single.id, 'ink');
    final indicatorPaint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey<String>('board-pointer-indicator')),
    );
    expect(
      (indicatorPaint.painter! as BoardPointerIndicatorPainter).indicators,
      isEmpty,
    );
    await controller.flush();
  });

  testWidgets(
    'late native palm replay cannot erase a touch-selected or moved item',
    (tester) async {
      final document = withPage(
        'native-selection-ownership',
        update: (page) =>
            page.copyWith(strokes: <InkStroke>[horizontalStroke(y: 250)]),
      );
      final source = _PalmInputSource();
      addTearDown(source.dispose);
      final controller = await pumpBoard(
        tester,
        document,
        palmInputSource: source,
      );
      controller.addShape(
        ShapeKind.rectangle,
        const Rect.fromLTWH(200, 180, 220, 140),
      );
      final objectId = controller.page.objects.single.id;
      final before = controller.page.objects.single.transform;
      controller.clearSelection();
      await tester.pump();

      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 879,
          device: 879,
          kind: PointerDeviceKind.touch,
          position: Offset(280, 250),
          timeStamp: Duration(milliseconds: 800),
          buttons: kPrimaryButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 879,
          device: 879,
          kind: PointerDeviceKind.touch,
          position: Offset(280, 250),
          timeStamp: Duration(milliseconds: 900),
        ),
      );
      await tester.pump();
      expect(controller.selectedIds, <String>{objectId});

      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 880,
          device: 880,
          kind: PointerDeviceKind.touch,
          position: Offset(280, 250),
          timeStamp: Duration(milliseconds: 1000),
          buttons: kPrimaryButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 880,
          device: 880,
          kind: PointerDeviceKind.touch,
          position: Offset(340, 250),
          delta: Offset(60, 0),
          timeStamp: Duration(milliseconds: 1100),
          buttons: kPrimaryButton,
        ),
      );
      await tester.pump();
      expect(controller.selectedIds, <String>{objectId});
      expect(
        controller.renderObjects.single.transform.x,
        closeTo(before.x + 60, .01),
      );

      // Reproduces SMART-class firmware reclassifying the already-owned
      // selecting finger as TOOL_TYPE_PALM before Flutter receives its UP.
      source.add(
        const NativePalmStroke(
          sessionId: 'selection-owned-active',
          points: <Offset>[Offset(280, 250), Offset(340, 250)],
          radius: 48,
          contactCount: 1,
          source: 'tool_type_palm',
          samples: <NativePalmSample>[
            NativePalmSample(
              position: Offset(280, 250),
              radiusMajor: 48,
              radiusMinor: 24,
              orientation: 0,
              timeStamp: Duration(milliseconds: 1000),
            ),
            NativePalmSample(
              position: Offset(340, 250),
              radiusMajor: 48,
              radiusMinor: 24,
              orientation: 0,
              timeStamp: Duration(milliseconds: 1100),
            ),
          ],
        ),
      );
      await tester.pump();
      expect(controller.renderStrokes, hasLength(1));

      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 880,
          device: 880,
          kind: PointerDeviceKind.touch,
          position: Offset(340, 250),
          timeStamp: Duration(milliseconds: 1200),
        ),
      );
      await tester.pump();

      // The platform callback can also be queued until after selection commit.
      source.add(
        const NativePalmStroke(
          sessionId: 'selection-owned-delayed',
          points: <Offset>[Offset(280, 250), Offset(340, 250)],
          radius: 48,
          contactCount: 1,
          source: 'tool_type_palm',
          samples: <NativePalmSample>[
            NativePalmSample(
              position: Offset(280, 250),
              radiusMajor: 48,
              radiusMinor: 24,
              orientation: 0,
              timeStamp: Duration(milliseconds: 1000),
            ),
            NativePalmSample(
              position: Offset(340, 250),
              radiusMajor: 48,
              radiusMinor: 24,
              orientation: 0,
              timeStamp: Duration(milliseconds: 1200),
            ),
          ],
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      expect(controller.page.strokes, hasLength(1));
      expect(controller.page.strokes.single.id, 'ink');
      expect(
        controller.page.objects.single.transform.x,
        closeTo(before.x + 60, .01),
      );
      await controller.flush();
    },
  );

  testWidgets('touch resize handle owns input against native palm replay', (
    tester,
  ) async {
    final document = withPage(
      'native-resize-ownership',
      update: (page) =>
          page.copyWith(strokes: <InkStroke>[horizontalStroke(y: 325)]),
    );
    final source = _PalmInputSource();
    addTearDown(source.dispose);
    final controller = await pumpBoard(
      tester,
      document,
      palmInputSource: source,
    );
    controller.addShape(
      ShapeKind.rectangle,
      const Rect.fromLTWH(200, 180, 220, 140),
    );
    await tester.pump();
    final before = controller.page.objects.single.transform;
    final resizeHandle = find.bySemanticsLabel('Auswahl skalieren');
    expect(resizeHandle, findsOneWidget);
    final start = tester.getCenter(resizeHandle);
    final resize = await tester.startGesture(
      start,
      pointer: 881,
      kind: PointerDeviceKind.touch,
    );
    await resize.moveBy(const Offset(45, 35));
    await tester.pump();

    source.add(
      NativePalmStroke(
        sessionId: 'resize-handle-owned',
        points: <Offset>[start, start + const Offset(45, 35)],
        radius: 54,
        contactCount: 1,
        source: 'tool_type_palm',
      ),
    );
    await tester.pump();
    expect(controller.renderStrokes, hasLength(1));

    await resize.up();
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.page.strokes, hasLength(1));
    expect(
      controller.page.objects.single.transform.width,
      greaterThan(before.width),
    );
    await controller.flush();
  });

  testWidgets('resize handle owns touch immediately before drag slop', (
    tester,
  ) async {
    final document = withPage(
      'native-resize-down-ownership',
      update: (page) =>
          page.copyWith(strokes: <InkStroke>[horizontalStroke(y: 325)]),
    );
    final source = _PalmInputSource();
    addTearDown(source.dispose);
    final controller = await pumpBoard(
      tester,
      document,
      palmInputSource: source,
    );
    controller.addShape(
      ShapeKind.rectangle,
      const Rect.fromLTWH(200, 180, 220, 140),
    );
    await tester.pump();
    final handle = find.bySemanticsLabel('Auswahl skalieren');
    final position = tester.getCenter(handle);
    final gesture = await tester.startGesture(
      position,
      pointer: 882,
      kind: PointerDeviceKind.touch,
    );

    // Android can publish the side channel before GestureDetector crosses its
    // pan slop. Pointer-down ownership must already make it non-destructive.
    source.add(
      NativePalmStroke(
        sessionId: 'resize-down-owned',
        points: <Offset>[position],
        radius: 54,
        contactCount: 1,
        source: 'tool_type_palm',
      ),
    );
    await tester.pump();
    expect(controller.renderStrokes, hasLength(1));

    await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 220));
    expect(controller.page.strokes, hasLength(1));
    await controller.flush();
  });

  testWidgets(
    'distant palm erases while an independently owned resize stays active',
    (tester) async {
      final document = withPage(
        'parallel-resize-and-palm',
        update: (page) =>
            page.copyWith(strokes: <InkStroke>[horizontalStroke(y: 325)]),
      );
      final source = _PalmInputSource();
      addTearDown(source.dispose);
      final controller = await pumpBoard(
        tester,
        document,
        palmInputSource: source,
      );
      controller.addShape(
        ShapeKind.rectangle,
        const Rect.fromLTWH(200, 180, 220, 140),
      );
      await tester.pump();
      final before = controller.page.objects.single.transform;
      final handle = find.bySemanticsLabel('Auswahl skalieren');
      final start = tester.getCenter(handle);
      final gesture = await tester.startGesture(
        start,
        pointer: 885,
        kind: PointerDeviceKind.touch,
      );
      await gesture.moveBy(const Offset(24, 20));
      await tester.pump();

      source.add(
        const NativePalmStroke(
          sessionId: 'spatially-independent-palm',
          points: <Offset>[Offset(650, 325)],
          radius: 48,
          contactCount: 1,
          source: 'tool_type_palm',
          samples: <NativePalmSample>[
            NativePalmSample(
              position: Offset(650, 325),
              radiusMajor: 48,
              radiusMinor: 24,
              orientation: 0,
              timeStamp: Duration(milliseconds: 5000),
            ),
          ],
        ),
      );
      await tester.pump();
      expect(_strokeCrossesX(controller.renderStrokes, 650), isFalse);

      await gesture.moveBy(const Offset(20, 16));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 220));

      expect(
        controller.page.objects.single.transform.width,
        greaterThan(before.width),
      );
      expect(_strokeCrossesX(controller.page.strokes, 650), isFalse);
      await controller.flush();
    },
  );

  testWidgets(
    'palm reported from DOWN overrides provisional touch navigation',
    (tester) async {
      final document = withPage(
        'initial-native-palm-dual-channel',
        update: (page) =>
            page.copyWith(strokes: <InkStroke>[horizontalStroke(y: 250)]),
      );
      final source = _PalmInputSource();
      addTearDown(source.dispose);
      final controller = await pumpBoard(
        tester,
        document,
        palmInputSource: source,
      );

      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 883,
          device: 883,
          kind: PointerDeviceKind.touch,
          position: Offset(380, 250),
          timeStamp: Duration(milliseconds: 1000),
          buttons: kPrimaryButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 883,
          device: 883,
          kind: PointerDeviceKind.touch,
          position: Offset(420, 250),
          delta: Offset(40, 0),
          timeStamp: Duration(milliseconds: 1100),
          buttons: kPrimaryButton,
        ),
      );
      await tester.pump();
      expect(controller.hasSelection, isFalse);

      source.add(
        const NativePalmStroke(
          sessionId: 'initial-palm-wins',
          points: <Offset>[Offset(380, 250), Offset(420, 250)],
          radius: 48,
          contactCount: 1,
          source: 'tool_type_palm',
          startedAsPalm: true,
          samples: <NativePalmSample>[
            NativePalmSample(
              position: Offset(380, 250),
              radiusMajor: 48,
              radiusMinor: 24,
              orientation: 0,
              timeStamp: Duration(milliseconds: 1000),
            ),
            NativePalmSample(
              position: Offset(420, 250),
              radiusMajor: 48,
              radiusMinor: 24,
              orientation: 0,
              timeStamp: Duration(milliseconds: 1100),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.sendEventToBinding(
        const PointerCancelEvent(
          pointer: 883,
          device: 883,
          kind: PointerDeviceKind.touch,
          position: Offset(420, 250),
          timeStamp: Duration(milliseconds: 1200),
        ),
      );
      await tester.pump(const Duration(milliseconds: 220));

      expect(controller.page.strokes, hasLength(2));
      expect(_strokeCrossesX(controller.page.strokes, 400), isFalse);
      await controller.flush();
    },
  );

  testWidgets('palm trace which began before a page switch is discarded', (
    tester,
  ) async {
    final source = _PalmInputSource();
    addTearDown(source.dispose);
    final controller = await pumpBoard(
      tester,
      WhiteboardDocument.create(id: 'stale-page-palm'),
      palmInputSource: source,
    );
    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: 884,
        device: 884,
        kind: PointerDeviceKind.touch,
        position: Offset(400, 300),
        timeStamp: Duration(milliseconds: 2000),
        buttons: kPrimaryButton,
      ),
    );
    controller.addPage();
    controller.execute(
      AddStrokeCommand(
        controller.page.id,
        horizontalStroke(id: 'new-page-ink'),
      ),
    );
    await tester.pump();

    source.add(
      const NativePalmStroke(
        sessionId: 'old-page-trace',
        points: <Offset>[Offset(400, 300)],
        radius: 48,
        contactCount: 1,
        source: 'tool_type_palm',
        startedAsPalm: true,
        samples: <NativePalmSample>[
          NativePalmSample(
            position: Offset(400, 300),
            radiusMajor: 48,
            radiusMinor: 24,
            orientation: 0,
            timeStamp: Duration(milliseconds: 2000),
          ),
        ],
      ),
    );
    await tester.pump(const Duration(milliseconds: 220));

    expect(controller.page.strokeById('new-page-ink'), isNotNull);
    await tester.sendEventToBinding(
      const PointerCancelEvent(
        pointer: 884,
        device: 884,
        kind: PointerDeviceKind.touch,
        position: Offset(400, 300),
        timeStamp: Duration(milliseconds: 2100),
      ),
    );
    await controller.flush();
  });

  testWidgets(
    'native palm coordinates are centred in the offset Flutter surface',
    (tester) async {
      final document = withPage(
        'native-palm-view-origin',
        update: (page) =>
            page.copyWith(strokes: <InkStroke>[horizontalStroke()]),
      );
      final source = _PalmInputSource();
      addTearDown(source.dispose);
      final controller = await pumpBoard(
        tester,
        document,
        palmInputSource: source,
        boardPadding: const EdgeInsets.only(left: 100, top: 50),
      );

      // Native coordinates are Flutter-view-global. The board begins at
      // (100, 50), so this contact is centred at local/world (400, 300).
      source.add(
        const NativePalmStroke(
          sessionId: 'view:100:1',
          points: <Offset>[Offset(500, 350)],
          radius: 20,
          contactCount: 1,
          source: 'tool_type_palm',
          samples: <NativePalmSample>[
            NativePalmSample(
              position: Offset(500, 350),
              radiusMajor: 28,
              radiusMinor: 14,
              orientation: 0,
            ),
          ],
        ),
      );
      await tester.pump();

      final indicatorPaint = tester.widget<CustomPaint>(
        find.byKey(const ValueKey<String>('board-pointer-indicator')),
      );
      final indicator =
          (indicatorPaint.painter! as BoardPointerIndicatorPainter)
              .indicators
              .single;
      expect(indicator.kind, BoardPointerIndicatorKind.eraser);
      expect(indicator.position, const Offset(400, 300));
      expect(
        indicator.radius,
        EraserContactGeometry.minimumRecognizedFistScreenRadius,
      );
      final liveFragments = controller.renderStrokes.toList(growable: false)
        ..sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      expect(liveFragments, hasLength(2));
      expect(
        liveFragments.last.points.first.x - liveFragments.first.points.last.x,
        closeTo(indicator.radius * 2 + 4, .01),
      );

      await tester.pump(const Duration(milliseconds: 220));

      expect(_strokeCrossesX(controller.page.strokes, 400), isFalse);
      expect(_strokeCrossesX(controller.page.strokes, 300), isTrue);
      expect(_strokeCrossesX(controller.page.strokes, 500), isTrue);
      await controller.flush();
    },
  );

  testWidgets(
    'compact three-touch fist rolls navigation back and erases only its path',
    (tester) async {
      final document = withPage(
        'cluster-partial-e2e',
        update: (page) =>
            page.copyWith(strokes: <InkStroke>[horizontalStroke()]),
      );
      final controller = await pumpBoard(tester, document)
        ..setTool(BoardTool.dashedPen);
      final initialOffset = controller.viewport.offset;

      for (final contact in const <(int, double)>[
        (401, 360),
        (402, 390),
        (403, 420),
      ]) {
        await tester.sendEventToBinding(
          PointerDownEvent(
            pointer: contact.$1,
            device: contact.$1,
            kind: PointerDeviceKind.touch,
            position: Offset(contact.$2, 300),
            radiusMajor: 7,
            radiusMinor: 5,
            size: .1,
          ),
        );
      }
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 401,
          device: 401,
          kind: PointerDeviceKind.touch,
          position: Offset(380, 300),
          delta: Offset(20, 0),
          radiusMajor: 7,
          radiusMinor: 5,
          size: .1,
          buttons: kPrimaryButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 402,
          device: 402,
          kind: PointerDeviceKind.touch,
          position: Offset(410, 300),
          delta: Offset(20, 0),
          radiusMajor: 7,
          radiusMinor: 5,
          size: .1,
          buttons: kPrimaryButton,
        ),
      );
      await tester.pump();

      List<BoardPointerIndicator> liveIndicators() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .whereType<BoardPointerIndicatorPainter>()
          .expand((painter) => painter.indicators)
          .toList(growable: false);

      expect(liveIndicators(), hasLength(1));
      expect(liveIndicators().single.position.dx, closeTo(403.33, .02));
      expect(
        liveIndicators().single.radius,
        EraserContactGeometry.minimumRecognizedFistScreenRadius,
      );

      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 401,
          device: 401,
          kind: PointerDeviceKind.touch,
          position: Offset(440, 300),
          delta: Offset(60, 0),
          radiusMajor: 60,
          radiusMinor: 30,
          size: .72,
          buttons: kPrimaryButton,
        ),
      );
      await tester.pump();

      final grown = liveIndicators().single;
      expect(grown.position.dx, closeTo(423.33, .02));
      expect(grown.position.dy, 300);
      expect(grown.radius, greaterThan(70));

      for (final contact in const <(int, double)>[
        (401, 440),
        (402, 410),
        (403, 420),
      ]) {
        await tester.sendEventToBinding(
          PointerUpEvent(
            pointer: contact.$1,
            device: contact.$1,
            kind: PointerDeviceKind.touch,
            position: Offset(contact.$2, 300),
          ),
        );
      }
      await tester.pump();

      expect(controller.viewport.offset, initialOffset);
      expect(controller.tool, BoardTool.dashedPen);
      expect(controller.page.strokes, hasLength(2));
      expect(_strokeCrossesX(controller.page.strokes, 400), isFalse);
      expect(_strokeCrossesX(controller.page.strokes, 200), isTrue);
      expect(_strokeCrossesX(controller.page.strokes, 600), isTrue);
      controller.undo();
      expect(controller.page.strokes, hasLength(1));
      await controller.flush();
    },
  );

  test(
    'simultaneous participant erasers replay against the latest document',
    () async {
      final document = withPage(
        'concurrent-partial-erase',
        update: (page) => page.copyWith(
          strokes: <InkStroke>[horizontalStroke(start: 0, end: 300, y: 100)],
        ),
      );
      final owner = EditorController(
        document: document,
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      final participant = EditorController.participantView(owner);
      addTearDown(() async {
        await participant.close();
        participant.dispose();
        await owner.close();
        owner.dispose();
      });

      owner.eraseAt(const Offset(75, 100), radius: 8);
      participant.eraseAt(const Offset(225, 100), radius: 8);
      expect(_strokeCrossesX(owner.renderStrokes, 75), isFalse);
      expect(_strokeCrossesX(participant.renderStrokes, 225), isFalse);

      owner.commitErase();
      // The second live preview is automatically rebased after the shared
      // history changes and therefore contains both users' gaps.
      expect(_strokeCrossesX(participant.renderStrokes, 75), isFalse);
      expect(_strokeCrossesX(participant.renderStrokes, 225), isFalse);
      participant.commitErase();

      expect(owner.page.strokes, hasLength(3));
      expect(_strokeCrossesX(owner.page.strokes, 75), isFalse);
      expect(_strokeCrossesX(owner.page.strokes, 225), isFalse);
      expect(_strokeCrossesX(owner.page.strokes, 25), isTrue);
      expect(_strokeCrossesX(owner.page.strokes, 150), isTrue);
      expect(_strokeCrossesX(owner.page.strokes, 275), isTrue);

      participant.undo();
      expect(owner.page.strokes, hasLength(2));
      expect(_strokeCrossesX(owner.page.strokes, 75), isFalse);
      expect(_strokeCrossesX(owner.page.strokes, 225), isTrue);
      owner.undo();
      expect(owner.page.strokes, hasLength(1));
      expect(_strokeCrossesX(owner.page.strokes, 75), isTrue);
      owner.redo();
      participant.redo();
      expect(owner.page.strokes, hasLength(3));
      expect(_strokeCrossesX(owner.page.strokes, 75), isFalse);
      expect(_strokeCrossesX(owner.page.strokes, 225), isFalse);
    },
  );

  test('replay never erases ink created after the eraser already passed', () {
    final document = withPage(
      'non-retroactive-partial-erase',
      update: (page) => page.copyWith(
        strokes: <InkStroke>[
          horizontalStroke(id: 'existing', start: 0, end: 300, y: 100),
        ],
      ),
    );
    final owner = EditorController(
      document: document,
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    final participant = EditorController.participantView(owner);
    addTearDown(() async {
      await participant.close();
      participant.dispose();
      await owner.close();
      owner.dispose();
    });

    owner.eraseAt(const Offset(150, 100), radius: 8);
    participant.execute(
      AddStrokeCommand(
        participant.page.id,
        horizontalStroke(id: 'written-after-pass', start: 0, end: 300, y: 100),
      ),
    );
    owner.commitErase();

    final lateStroke = owner.page.strokeById('written-after-pass');
    expect(lateStroke, isNotNull);
    expect(lateStroke!.points.first.x, 0);
    expect(lateStroke.points.last.x, 300);
    expect(
      owner.page.strokes.where((stroke) => stroke.id != lateStroke.id),
      hasLength(2),
    );
  });
}

bool _strokeCrossesX(Iterable<InkStroke> strokes, double x) {
  for (final stroke in strokes) {
    if (stroke.points.isEmpty) continue;
    var minimum = stroke.points.first.x;
    var maximum = minimum;
    for (final point in stroke.points.skip(1)) {
      if (point.x < minimum) minimum = point.x;
      if (point.x > maximum) maximum = point.x;
    }
    if (minimum <= x && maximum >= x) return true;
  }
  return false;
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

final class _PalmInputSource implements PalmInputSource {
  final StreamController<NativePalmStroke> _controller =
      StreamController<NativePalmStroke>.broadcast(sync: true);

  @override
  Stream<NativePalmStroke> get strokes => _controller.stream;

  void add(NativePalmStroke stroke) => _controller.add(stroke);

  Future<void> dispose() => _controller.close();
}
