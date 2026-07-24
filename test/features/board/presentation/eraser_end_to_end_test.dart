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
import 'package:flowboard_x/src/features/board/presentation/board_surface.dart';
import 'package:flowboard_x/src/features/editor/board_participant_controller.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
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

  testWidgets(
    'participant stylus eraser uses shared thickness and is fully undoable',
    (tester) async {
      final document = withPage(
        'stylus-eraser-e2e',
        update: (page) =>
            page.copyWith(strokes: <InkStroke>[horizontalStroke()]),
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
      // 30 px eraser diameter plus the original stroke's two half-widths.
      expect(fragments.first.points.last.x, closeTo(383, .01));
      expect(fragments.last.points.first.x, closeTo(417, .01));
      expect(participant.tool, BoardTool.eraser);
      expect(participant.penStyle.width, 30);

      controller.undo();
      expect(controller.page.strokes, hasLength(1));
      expect(controller.page.strokes.single.points.first.x, 100);
      expect(controller.page.strokes.single.points.last.x, 700);
      controller.redo();
      expect(controller.page.strokes, hasLength(2));
      await controller.flush();
    },
  );

  testWidgets('participant thickness changes the real stylus eraser diameter', (
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
    expect(fineGap, closeTo(6, .01));

    participant.updateEraserWidth(32);
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
    expect(broadGap, closeTo(36, .01));
    expect(broadGap, greaterThan(fineGap * 5));
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

  testWidgets(
    'broad palm partially erases regardless of the selected shape tool',
    (tester) async {
      final document = withPage(
        'palm-partial-e2e',
        update: (page) =>
            page.copyWith(strokes: <InkStroke>[horizontalStroke()]),
      );
      final controller = await pumpBoard(tester, document)
        ..setTool(BoardTool.shape);

      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 301,
          device: 301,
          kind: PointerDeviceKind.touch,
          position: Offset(400, 300),
          radiusMajor: 30,
          radiusMinor: 18,
          size: .34,
        ),
      );
      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 301,
          device: 301,
          kind: PointerDeviceKind.touch,
          position: Offset(400, 300),
          radiusMajor: 30,
          radiusMinor: 18,
          size: .34,
        ),
      );
      await tester.pump();

      expect(controller.tool, BoardTool.shape);
      expect(controller.page.strokes, hasLength(2));
      expect(_strokeCrossesX(controller.page.strokes, 400), isFalse);
      expect(_strokeCrossesX(controller.page.strokes, 200), isTrue);
      expect(_strokeCrossesX(controller.page.strokes, 600), isTrue);
      controller.undo();
      expect(controller.page.strokes, hasLength(1));
      await controller.flush();
    },
  );

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
          source: 'system_canceled',
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
      for (final contact in const <(int, double)>[
        (401, 380),
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
