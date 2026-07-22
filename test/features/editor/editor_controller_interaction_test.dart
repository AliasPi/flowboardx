import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/domain/serialization/document_codec.dart';
import 'package:flowboard_x/src/features/board/engine/input_policy.dart';
import 'package:flowboard_x/src/features/board/presentation/board_surface.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flowboard_x/src/features/templates/templates.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'recent custom colors are persistent, deduplicated and capped',
    () async {
      final controller = EditorController(
        document: WhiteboardDocument.create(id: 'recent-colors-document'),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      for (var index = 0; index < 12; index++) {
        controller.rememberCustomPenColor(0xFF000000 | index);
      }
      controller.rememberCustomPenColor(0xFF000007);

      expect(controller.recentCustomPenColors, hasLength(10));
      expect(controller.recentCustomPenColors.first, 0xFF000007);
      expect(controller.recentCustomPenColors.toSet(), hasLength(10));
      expect(
        controller.document.metadata.custom[EditorController
            .recentPenColorsMetadataKey],
        startsWith('FF000007,'),
      );

      // An ordinary board command and Undo must not roll back UI preferences.
      controller.addPage();
      controller.undo();
      expect(controller.recentCustomPenColors.first, 0xFF000007);
    },
  );

  test('page navigation loops in both directions', () async {
    final base = WhiteboardDocument.create(id: 'loop-pages');
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage,
          BoardPage.empty(id: 'page-2', name: 'Seite 2'),
          BoardPage.empty(id: 'page-3', name: 'Seite 3'),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });

    expect(controller.document.currentPageIndex, 0);
    controller.previousPage();
    expect(controller.document.currentPageIndex, 2);
    controller.nextPage();
    expect(controller.document.currentPageIndex, 0);
    controller.goToPage(2);
    controller.nextPage();
    expect(controller.document.currentPageIndex, 0);
  });

  test(
    'switching from selection to ink clears selection before writing',
    () async {
      final controller = _controllerWithSelectedShape();
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      controller.setTool(BoardTool.selectRectangle);
      expect(controller.hasSelection, isTrue);

      controller.setTool(BoardTool.pen);
      expect(controller.hasSelection, isFalse);

      const down = PointerDownEvent(
        pointer: 7,
        device: 3,
        position: Offset(520, 520),
        kind: PointerDeviceKind.stylus,
      );
      const up = PointerUpEvent(
        pointer: 7,
        device: 3,
        position: Offset(560, 550),
        kind: PointerDeviceKind.stylus,
      );
      expect(controller.beginInk(down, down.position), isTrue);
      expect(() => controller.endInk(up, up.position), returnsNormally);
      expect(controller.page.strokes, hasLength(1));
    },
  );

  test(
    'table insertion selects the table and pen can resume immediately',
    () async {
      final controller = EditorController(
        document: WhiteboardDocument.create(id: 'table-tool-document'),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      controller.updatePen(type: InkToolType.marker, width: 12);
      controller.armShape(ShapeKind.rectangle);
      expect(controller.tool, BoardTool.shape);

      controller.addTable(rows: 3, columns: 4, at: const Offset(100, 100));

      expect(controller.page.objects.single, isA<TableObject>());
      expect(controller.tool, BoardTool.selectRectangle);
      expect(controller.selectedIds, <String>{
        controller.page.objects.single.id,
      });
      expect(controller.penStyle.type, InkToolType.marker);

      controller.resumeConfiguredInkTool();
      expect(controller.tool, BoardTool.marker);
      expect(controller.hasSelection, isFalse);

      const down = PointerDownEvent(
        pointer: 19,
        device: 4,
        position: Offset(180, 170),
        kind: PointerDeviceKind.stylus,
      );
      const move = PointerMoveEvent(
        pointer: 19,
        device: 4,
        position: Offset(260, 210),
        kind: PointerDeviceKind.stylus,
      );
      const up = PointerUpEvent(
        pointer: 19,
        device: 4,
        position: Offset(340, 250),
        kind: PointerDeviceKind.stylus,
      );
      expect(controller.beginInk(down, down.position), isTrue);
      controller.updateInk(move, move.position);
      controller.endInk(up, up.position);

      expect(controller.page.objects, hasLength(1));
      expect(controller.page.annotationLayers.single.strokes, hasLength(1));
    },
  );

  test(
    'cover insertion selects the cover while retaining the configured pen',
    () async {
      final controller = EditorController(
        document: WhiteboardDocument.create(id: 'cover-tool-document'),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      controller.updatePen(type: InkToolType.dashed, width: 9);
      controller.armShape(ShapeKind.rectangle);
      controller.addCover(
        at: const Offset(120, 160),
        direction: RevealDirection.leftToRight,
      );

      final persisted = controller.page.objects.single as CoverObject;
      expect(controller.tool, BoardTool.selectRectangle);
      expect(controller.selectedIds, <String>{persisted.id});
      expect(controller.selectedCover?.id, persisted.id);

      // Cover controls deliberately stay selected while the configured pen is
      // active, so a teacher can keep writing and still grab an edge handle.
      controller.resumeConfiguredInkTool(clearSelection: false);
      expect(controller.tool, BoardTool.dashedPen);
      expect(controller.selectedCover?.id, persisted.id);
      controller.updatePen(width: 14);
      expect(controller.selectedCover?.id, persisted.id);
      expect(controller.penStyle.width, 14);

      controller.previewMoveSelection(const Offset(70, 45));
      final rendered = controller.renderObjects.single as CoverObject;
      expect(rendered.transform.x, 190);
      expect(rendered.transform.y, 205);
      expect(controller.selectedCover?.transform, rendered.transform);
      expect(controller.page.objects.single.transform, persisted.transform);

      controller.commitSelectionTransform();
      expect(controller.page.objects.single.transform, rendered.transform);
      controller.undo();
      expect(controller.page.objects.single.transform, persisted.transform);
    },
  );

  test(
    'an empty tap after insertion returns to the configured ink tool',
    () async {
      final controller = EditorController(
        document: WhiteboardDocument.create(id: 'insert-selection-document'),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });
      controller.updatePen(type: InkToolType.marker, width: 11);
      controller.addCover(at: const Offset(100, 100));
      expect(controller.tool, BoardTool.selectRectangle);
      expect(controller.hasSelection, isTrue);

      controller.selectAt(const Offset(1600, 900));

      expect(controller.hasSelection, isFalse);
      expect(controller.tool, BoardTool.marker);
      expect(controller.penStyle.width, 11);

      controller.addCover(at: const Offset(100, 100));
      controller.setTool(BoardTool.selectRectangle);
      controller.selectAt(const Offset(1600, 900));
      expect(controller.tool, BoardTool.selectRectangle);
    },
  );

  test(
    'selection can be resized on one axis without preserving aspect ratio',
    () async {
      final controller = _controllerWithSelectedShape();
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });
      final before = controller.page.objects.single.transform;
      final bounds = controller.selectionBounds;

      controller.previewResizeSelection(
        scaleX: 1,
        scaleY: .5,
        anchor: Offset(bounds.left, bounds.top),
      );

      final preview = controller.renderObjects.single.transform;
      expect(preview.width, closeTo(before.width, .001));
      expect(preview.height, closeTo(before.height * .5, .001));
      controller.commitSelectionTransform();
      expect(controller.page.objects.single.transform, preview);
      controller.undo();
      expect(controller.page.objects.single.transform, before);
    },
  );

  testWidgets('selection transform handles have one shared gesture owner', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final controller = _controllerWithSelectedShape();
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BoardSurface(controller: controller)),
      ),
    );
    await tester.pump();

    final diagonal = find.bySemanticsLabel('Auswahl skalieren');
    final rightEdge = find.bySemanticsLabel('Auswahl rechts frei skalieren');
    final diagonalGesture = await tester.startGesture(
      tester.getCenter(diagonal),
      kind: PointerDeviceKind.stylus,
    );
    await diagonalGesture.moveBy(const Offset(30, 30));
    await tester.pump();
    final afterDiagonal = controller.renderObjects.single.transform;

    final competingEdge = await tester.startGesture(
      tester.getCenter(rightEdge),
      pointer: 77,
      kind: PointerDeviceKind.stylus,
    );
    await competingEdge.moveBy(const Offset(120, 0));
    await tester.pump();
    expect(controller.renderObjects.single.transform, afterDiagonal);
    await competingEdge.up();

    final competingPen = await tester.startGesture(
      const Offset(760, 580),
      pointer: 78,
      kind: PointerDeviceKind.stylus,
    );
    await competingPen.moveBy(const Offset(40, 20));
    await competingPen.up();
    await tester.pump();
    expect(controller.page.strokes, isEmpty);
    expect(controller.inkSessions.sessions, isEmpty);

    await diagonalGesture.moveBy(const Offset(20, 20));
    await tester.pump();
    expect(
      controller.renderObjects.single.transform.width,
      greaterThan(afterDiagonal.width),
    );
    await diagonalGesture.up();
    await tester.pump();
    expect(
      controller.page.objects.single.transform,
      controller.renderObjects.single.transform,
    );
    await controller.flush();
    await tester.pump();
  });

  testWidgets(
    'selected cover handles and body take precedence over an active pen',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final base = WhiteboardDocument.create(id: 'cover-surface-document');
      final cover = CoverObject(
        id: 'cover',
        transform: const ObjectTransform(
          x: 120,
          y: 160,
          width: 600,
          height: 360,
        ),
        direction: RevealDirection.leftToRight,
        reveal: 0,
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              objects: <BoardObject>[cover],
              selection: SelectionState(
                selectedItemIds: const <String>['cover'],
              ),
            ),
          ],
        ),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BoardSurface(controller: controller)),
        ),
      );
      await tester.pump();

      final handle = find.bySemanticsLabel('Abdeckung freilegen');
      expect(handle, findsOneWidget);
      expect(find.bySemanticsLabel('Auswahl skalieren'), findsNothing);
      expect(
        find.bySemanticsLabel(
          RegExp(r'^Abdeckung (links|oben|rechts|unten) skalieren$'),
        ),
        findsNWidgets(4),
      );
      final rightResize = find.bySemanticsLabel('Abdeckung rechts skalieren');
      expect(rightResize, findsOneWidget);
      final leftResize = find.bySemanticsLabel('Abdeckung links skalieren');
      expect(leftResize, findsOneWidget);
      expect(find.bySemanticsLabel('Abdeckung oben skalieren'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Abdeckung unten skalieren'),
        findsOneWidget,
      );
      final resizeGesture = await tester.startGesture(
        tester.getCenter(rightResize),
        kind: PointerDeviceKind.stylus,
      );
      await resizeGesture.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(controller.renderObjects.single.transform.width, closeTo(630, 1));
      final competingResizeGesture = await tester.startGesture(
        tester.getCenter(leftResize),
        pointer: 42,
        kind: PointerDeviceKind.stylus,
      );
      await competingResizeGesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(controller.renderObjects.single.transform.width, closeTo(630, 1));
      await competingResizeGesture.up();
      await resizeGesture.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(controller.renderObjects.single.transform.width, closeTo(660, 1));
      expect(controller.page.objects.single.transform.width, 600);
      await resizeGesture.up();
      await tester.pump();
      expect(controller.page.objects.single.transform.width, closeTo(660, 1));
      controller.undo();
      await tester.pump();
      expect(controller.renderObjects.single.transform.width, 600);

      // The reveal boundary is draggable along its full length. Grab it away
      // from the centred resize handle, which deliberately has hit priority at
      // the edge centre.
      final revealTarget = tester.getRect(handle);
      final handleGesture = await tester.startGesture(
        Offset(revealTarget.center.dx, revealTarget.top + 72),
        kind: PointerDeviceKind.stylus,
      );
      await handleGesture.moveBy(const Offset(90, 0));
      await tester.pump();
      expect(
        controller.coverRevealValue(cover.id, cover.reveal),
        greaterThan(0),
      );
      expect(controller.inkSessions.sessions, isEmpty);
      await handleGesture.up();
      await tester.pump();
      final committedReveal =
          (controller.page.objectById(cover.id)! as CoverObject).reveal;
      expect(committedReveal, greaterThan(cover.reveal));

      final handleBeforeMove = tester.getCenter(handle);
      final moveGesture = await tester.startGesture(
        const Offset(280, 240),
        kind: PointerDeviceKind.stylus,
      );
      await moveGesture.moveBy(const Offset(55, 35));
      await tester.pump();
      expect(controller.renderObjects.single.transform.x, 175);
      expect(controller.renderObjects.single.transform.y, 195);
      expect(controller.selectedCover?.transform.x, 175);
      expect(tester.getCenter(handle), handleBeforeMove + const Offset(55, 35));
      expect(controller.inkSessions.sessions, isEmpty);
      controller.cancelSelectionTransform();
      await moveGesture.cancel();
      await tester.pump();
      expect(controller.renderObjects.single.transform, cover.transform);

      final inkGesture = await tester.startGesture(
        const Offset(760, 610),
        kind: PointerDeviceKind.stylus,
      );
      await inkGesture.moveBy(const Offset(60, 20));
      await tester.pump();
      expect(controller.hasSelection, isFalse);
      expect(controller.tool, BoardTool.pen);
      expect(controller.inkSessions.sessions, hasLength(1));
      await inkGesture.cancel();
      await tester.pump();
      expect(controller.page.strokes, isEmpty);

      controller.undo();
      expect(
        (controller.page.objectById(cover.id)! as CoverObject).reveal,
        cover.reveal,
      );
      controller.redo();
      expect(
        (controller.page.objectById(cover.id)! as CoverObject).reveal,
        committedReveal,
      );
      await controller.flush();
    },
  );

  testWidgets(
    'vertical covers expose four size handles and a draggable guide only',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final base = WhiteboardDocument.create(id: 'vertical-cover-document');
      final cover = CoverObject(
        id: 'vertical-cover',
        transform: const ObjectTransform(
          x: 120,
          y: 160,
          width: 600,
          height: 360,
        ),
        direction: RevealDirection.topToBottom,
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              objects: <BoardObject>[cover],
              selection: SelectionState(
                selectedItemIds: const <String>['vertical-cover'],
              ),
            ),
          ],
        ),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BoardSurface(controller: controller)),
        ),
      );
      await tester.pump();

      expect(
        find.bySemanticsLabel(
          RegExp(r'^Abdeckung (links|oben|rechts|unten) skalieren$'),
        ),
        findsNWidgets(4),
      );
      expect(find.bySemanticsLabel('Auswahl skalieren'), findsNothing);
      final guide = find.bySemanticsLabel('Abdeckung freilegen');
      expect(guide, findsOneWidget);
      final target = tester.getRect(guide);
      final gesture = await tester.startGesture(
        Offset(target.left + 72, target.center.dy),
        kind: PointerDeviceKind.stylus,
      );
      await gesture.moveBy(const Offset(0, 90));
      await tester.pump();
      expect(controller.coverRevealValue(cover.id, 0), greaterThan(0));
      expect(controller.inkSessions.sessions, isEmpty);
      await gesture.up();
      await tester.pump();
      expect(
        (controller.page.objectById(cover.id)! as CoverObject).reveal,
        greaterThan(0),
      );
      await controller.flush();
      await tester.pump();
    },
  );

  for (final entry in <String, BoardObject>{
    'table': TableObject(
      id: 'target-table',
      transform: const ObjectTransform(x: 100, y: 200, width: 400, height: 200),
      rows: 3,
      columns: 4,
    ),
    'image': ImageObject(
      id: 'target-image',
      transform: const ObjectTransform(x: 100, y: 200, width: 400, height: 200),
      assetId: 'image-asset',
    ),
    'pdf': PdfObject(
      id: 'target-pdf',
      transform: const ObjectTransform(x: 100, y: 200, width: 400, height: 200),
      assetId: 'pdf-asset',
      pageIndices: const <int>[0],
    ),
  }.entries) {
    test(
      '${entry.key} receives full object-bound ink instead of a dot',
      () async {
        final base = WhiteboardDocument.create(id: '${entry.key}-ink-document');
        final document = base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(objects: <BoardObject>[entry.value]),
          ],
        );
        final controller = EditorController(
          document: document,
          repository: _MemoryRepository(),
          assetDirectory: Directory.current,
        );
        addTearDown(() async {
          await controller.close();
          controller.dispose();
        });
        controller.updatePen(
          colorArgb: 0xFF1565C0,
          width: 8,
          type: InkToolType.normal,
        );

        const down = PointerDownEvent(
          pointer: 41,
          device: 8,
          position: Offset(200, 250),
          kind: PointerDeviceKind.stylus,
        );
        const move = PointerMoveEvent(
          pointer: 41,
          device: 8,
          position: Offset(300, 300),
          kind: PointerDeviceKind.stylus,
        );
        const up = PointerUpEvent(
          pointer: 41,
          device: 8,
          position: Offset(400, 350),
          kind: PointerDeviceKind.stylus,
        );

        expect(controller.beginInk(down, down.position), isTrue);
        controller.updateInk(move, move.position);
        final preview = controller.renderInkPreviews.single;
        expect(preview.points, hasLength(2));
        expect(preview.points.first.x, 200);
        expect(preview.points.last.x, 300);
        expect(preview.width, 8);

        controller.endInk(up, up.position);

        expect(controller.page.strokes, isEmpty);
        final layer = controller.page.annotationFor(entry.value.id);
        expect(layer, isNotNull);
        final stored = layer!.strokes.single;
        expect(stored.points, hasLength(3));
        expect(stored.points.first.x, closeTo(.25, .00001));
        expect(stored.points.first.y, closeTo(.25, .00001));
        expect(stored.points.last.x, closeTo(.75, .00001));
        expect(stored.points.last.y, closeTo(.75, .00001));
        expect(stored.width, closeTo(.04, .00001));

        controller.selectAt(const Offset(250, 275));
        controller.moveSelection(const Offset(50, 30));
        expect(controller.page.annotationFor(entry.value.id), same(layer));
        expect(
          controller.page.objectById(entry.value.id)!.transform,
          const ObjectTransform(x: 150, y: 230, width: 400, height: 200),
        );
        expect(
          controller.page.annotationFor(entry.value.id)!.strokes.single.points,
          stored.points,
        );

        controller.scaleSelection(1.5, anchor: const Offset(150, 230));
        expect(
          controller.page.objectById(entry.value.id)!.transform,
          const ObjectTransform(x: 150, y: 230, width: 600, height: 300),
        );
        expect(
          controller.page.annotationFor(entry.value.id)!.strokes.single.points,
          stored.points,
        );

        const codec = DocumentCodec();
        final restored = codec.decode(codec.encode(controller.document));
        final restoredStroke = restored.currentPage
            .annotationFor(entry.value.id)!
            .strokes
            .single;
        expect(restoredStroke.points, hasLength(3));
        expect(restoredStroke.width, closeTo(.04, .00001));
      },
    );
  }

  test(
    'selection translation previews real content and commits once',
    () async {
      final controller = _controllerWithSelectedShape();
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      final persistedBefore = controller.page.objects.single.transform;
      controller.previewMoveSelection(const Offset(80, 45));

      expect(controller.page.objects.single.transform, persistedBefore);
      expect(controller.renderObjects.single.transform.x, 180);
      expect(controller.renderObjects.single.transform.y, 145);
      expect(controller.selectionBounds.left, 180);
      expect(controller.selectionBounds.top, 145);

      controller.commitSelectionTransform();
      expect(controller.page.objects.single.transform.x, 180);
      expect(controller.page.objects.single.transform.y, 145);
      expect(controller.canUndo, isTrue);

      controller.undo();
      expect(controller.page.objects.single.transform, persistedBefore);
    },
  );

  test('mixed layer arrangement is undoable and redoable', () async {
    final base = WhiteboardDocument.create(
      id: 'layer-document',
      now: DateTime.utc(2026, 7, 22),
    );
    final backInk = InkStroke(
      id: 'back-ink',
      points: const <InkPoint>[InkPoint(x: 0, y: 0)],
      zIndex: 0,
    );
    final selectedObject = ShapeObject(
      id: 'selected-object',
      transform: const ObjectTransform(x: 0, y: 0, width: 40, height: 40),
      zIndex: 1,
    );
    final frontInk = InkStroke(
      id: 'front-ink',
      points: const <InkPoint>[InkPoint(x: 1, y: 1)],
      zIndex: 2,
    );
    final document = base.copyWith(
      pages: <BoardPage>[
        base.currentPage.copyWith(
          strokes: <InkStroke>[backInk, frontInk],
          objects: <BoardObject>[selectedObject],
          selection: SelectionState(
            selectedItemIds: const <String>['selected-object'],
          ),
        ),
      ],
    );
    final controller = EditorController(
      document: document,
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });

    controller.arrangeSelection(LayerArrangement.oneForward);
    expect(controller.page.objectById('selected-object')!.zIndex, 2);
    expect(controller.page.strokeById('front-ink')!.zIndex, 1);

    controller.undo();
    expect(controller.page.objectById('selected-object')!.zIndex, 1);
    expect(controller.page.strokeById('front-ink')!.zIndex, 2);

    controller.redo();
    expect(controller.page.objectById('selected-object')!.zIndex, 2);
    expect(controller.page.strokeById('front-ink')!.zIndex, 1);
  });

  test(
    'user template imports media and annotations in one undoable command',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'flowboard-template-controller-',
      );
      final sourceDirectory = Directory('${temporary.path}/source')
        ..createSync();
      final targetDirectory = Directory('${temporary.path}/target')
        ..createSync();
      await File('${sourceDirectory.path}/photo.png').writeAsBytes([1, 2, 3]);
      await File('${sourceDirectory.path}/lesson.pdf').writeAsBytes([4, 5, 6]);
      final generatedIds = <String>[
        'template-media',
        'target-image',
        'target-pdf',
      ].iterator;
      final store = UserTemplateStore(
        directory: Directory('${temporary.path}/templates'),
        uuid: () {
          generatedIds.moveNext();
          return generatedIds.current;
        },
        useBackgroundIsolate: false,
      );
      final template = await store.save(
        name: 'Medienvorlage',
        page: BoardPage(
          id: 'source-page',
          name: 'Quelle',
          objects: <BoardObject>[
            ImageObject(
              id: 'image',
              transform: const ObjectTransform(
                x: 20,
                y: 30,
                width: 180,
                height: 100,
              ),
              assetId: 'source-image',
            ),
            PdfObject(
              id: 'pdf',
              transform: const ObjectTransform(
                x: 240,
                y: 30,
                width: 180,
                height: 240,
              ),
              assetId: 'source-pdf',
              pageIndices: const <int>[0],
            ),
          ],
          annotationLayers: <ObjectInkLayer>[
            ObjectInkLayer(
              id: 'image-annotations',
              objectId: 'image',
              strokes: <InkStroke>[
                InkStroke(
                  id: 'image-ink',
                  points: const <InkPoint>[
                    InkPoint(x: .1, y: .2),
                    InkPoint(x: .8, y: .7),
                  ],
                ),
              ],
            ),
            ObjectInkLayer(
              id: 'pdf-annotations',
              objectId: 'pdf',
              strokes: <InkStroke>[
                InkStroke(
                  id: 'pdf-ink',
                  points: const <InkPoint>[
                    InkPoint(x: .2, y: .2),
                    InkPoint(x: .6, y: .8),
                  ],
                ),
              ],
            ),
          ],
        ),
        sourceAssetDirectory: sourceDirectory,
        sourceAssets: <DocumentAsset>[
          DocumentAsset(
            id: 'source-image',
            type: DocumentAssetType.image,
            relativePath: 'photo.png',
            mimeType: 'image/png',
          ),
          DocumentAsset(
            id: 'source-pdf',
            type: DocumentAssetType.pdf,
            relativePath: 'lesson.pdf',
            mimeType: 'application/pdf',
          ),
        ],
      );
      final controller = EditorController(
        document: WhiteboardDocument.create(id: 'target-document'),
        repository: _MemoryRepository(),
        assetDirectory: targetDirectory,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });

      await controller.addUserTemplate(store, template);

      expect(controller.document.pages, hasLength(2));
      expect(controller.document.assets, hasLength(2));
      expect(
        controller.page.objects.whereType<ImageObject>().single.assetId,
        'target-image',
      );
      expect(
        controller.page.objects.whereType<PdfObject>().single.assetId,
        'target-pdf',
      );
      expect(controller.page.annotationFor('image')!.strokes, hasLength(1));
      expect(controller.page.annotationFor('pdf')!.strokes, hasLength(1));
      expect(
        await targetDirectory.list().where((entry) => entry is File).length,
        2,
      );

      controller.undo();
      expect(controller.document.pages, hasLength(1));
      expect(controller.document.assets, isEmpty);

      controller.redo();
      expect(controller.document.pages, hasLength(2));
      expect(controller.document.assets, hasLength(2));
      final restoredTemplatePage = controller.document.pages.firstWhere(
        (page) => page.objectById('image') != null,
      );
      expect(restoredTemplatePage.annotationFor('image'), isNotNull);
      expect(restoredTemplatePage.annotationFor('pdf'), isNotNull);
    },
  );

  test('duplicating a persistent group preserves a separate group', () async {
    final base = WhiteboardDocument.create(id: 'duplicate-group');
    final first = ShapeObject(
      id: 'a',
      transform: const ObjectTransform(x: 40, y: 40, width: 40, height: 40),
    );
    final second = ShapeObject(
      id: 'b',
      transform: const ObjectTransform(x: 100, y: 40, width: 40, height: 40),
    );
    final group = ContentGroup(
      id: 'group',
      memberIds: const <String>['a', 'b'],
      bounds: first.transform.bounds.union(second.transform.bounds),
    );
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(
            objects: <BoardObject>[first, second],
            contentGroups: <ContentGroup>[group],
            selection: SelectionState(selectedItemIds: const <String>['group']),
          ),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });

    controller.duplicateSelection();

    expect(controller.page.objects, hasLength(4));
    expect(controller.page.contentGroups, hasLength(2));
    final copy = controller.page.contentGroups.last;
    expect(copy.id, isNot(group.id));
    expect(copy.memberIds, hasLength(2));
    expect(controller.selectedIds, <String>{copy.id});

    controller.undo();
    expect(controller.page.objects, hasLength(2));
    expect(controller.page.contentGroups.single.id, group.id);
  });

  test('slow image import stays on the page that initiated it', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'flowboard-import-target-',
    );
    final repository = _DelayedAssetRepository();
    final base = WhiteboardDocument.create(id: 'slow-image-import');
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage,
          BoardPage.empty(id: 'second-page', name: 'Seite 2'),
        ],
      ),
      repository: repository,
      assetDirectory: temporary,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });

    final import = controller.importImageBytes(
      _tinyPngBytes(),
      fileName: 'board.png',
      mimeType: 'image/png',
    );
    await repository.assetDirectoryRequested.future;
    controller.goToPage(1);
    repository.assetDirectoryResult.complete(temporary);
    await import;

    expect(controller.document.currentPageIndex, 1);
    expect(controller.document.pages.first.objects, hasLength(1));
    expect(controller.document.pages.last.objects, isEmpty);
    expect(controller.selectedIds, isEmpty);
    expect(controller.document.assets, hasLength(1));
  });

  test('closing during an image import rolls its copied asset back', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'flowboard-import-rollback-',
    );
    final repository = _DelayedAssetRepository();
    final controller = EditorController(
      document: WhiteboardDocument.create(id: 'closing-image-import'),
      repository: repository,
      assetDirectory: temporary,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });

    final import = controller.importImageBytes(
      _tinyPngBytes(),
      fileName: 'pending.png',
      mimeType: 'image/png',
    );
    await repository.assetDirectoryRequested.future;
    await controller.close();
    repository.assetDirectoryResult.complete(temporary);
    await import;

    expect(await temporary.list().toList(), isEmpty);
    expect(controller.document.assets, isEmpty);
  });

  test(
    'slow PDF page import preserves an active stroke on its source page',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'flowboard-pdf-active-ink-',
      );
      final source = File(
        '${temporary.path}${Platform.pathSeparator}source.pdf',
      );
      await source.writeAsBytes('%PDF-1.7\nfixture'.codeUnits, flush: true);
      final repository = _DelayedAssetRepository();
      final base = WhiteboardDocument.create(id: 'pdf-active-ink');
      final sourcePageId = base.currentPage.id;
      final controller = EditorController(
        document: base,
        repository: repository,
        assetDirectory: temporary,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });

      final import = controller.importPdf(
        source.path,
        placement: PdfPlacementMode.newWhiteboardPages,
        pageIndices: const <int>[0],
      );
      await repository.assetDirectoryRequested.future;
      const down = PointerDownEvent(
        pointer: 91,
        device: 12,
        position: Offset(300, 260),
        kind: PointerDeviceKind.stylus,
      );
      const move = PointerMoveEvent(
        pointer: 91,
        device: 12,
        position: Offset(390, 305),
        kind: PointerDeviceKind.stylus,
      );
      const up = PointerUpEvent(
        pointer: 91,
        device: 12,
        position: Offset(470, 345),
        kind: PointerDeviceKind.stylus,
      );
      expect(controller.beginInk(down, down.position), isTrue);
      controller.updateInk(move, move.position);
      expect(controller.inkSessions.isWriting, isTrue);

      repository.assetDirectoryResult.complete(temporary);
      await import;

      expect(controller.page.id, sourcePageId);
      expect(controller.inkSessions.isWriting, isTrue);
      expect(controller.document.pages, hasLength(2));
      controller.endInk(up, up.position);

      expect(controller.document.pageById(sourcePageId)!.strokes, hasLength(1));
      final importedPage = controller.document.pages.singleWhere(
        (page) => page.id != sourcePageId,
      );
      expect(importedPage.strokes, isEmpty);
      expect(importedPage.objects.whereType<PdfObject>(), hasLength(1));
    },
  );
}

Uint8List _tinyPngBytes() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

EditorController _controllerWithSelectedShape() {
  final base = WhiteboardDocument.create(
    id: 'interaction-document',
    now: DateTime.utc(2026, 7, 22),
  );
  final shape = ShapeObject(
    id: 'selected-shape',
    transform: const ObjectTransform(x: 100, y: 100, width: 240, height: 160),
    shape: ShapeKind.rectangle,
  );
  final page = base.currentPage.copyWith(
    objects: <BoardObject>[shape],
    selection: SelectionState(selectedItemIds: <String>['selected-shape']),
  );
  final document = base.copyWith(pages: <BoardPage>[page]);
  return EditorController(
    document: document,
    repository: _MemoryRepository(),
    assetDirectory: Directory.current,
  );
}

final class _MemoryRepository implements DocumentRepository {
  WhiteboardDocument? document;

  @override
  Future<void> save(WhiteboardDocument document) async {
    this.document = document;
  }

  @override
  Future<WhiteboardDocument?> load(String documentId) async => document;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => document;

  @override
  Future<List<DocumentSummary>> list() async => const <DocumentSummary>[];

  @override
  Future<void> delete(String documentId) async {
    document = null;
  }

  @override
  Future<Directory> assetDirectory(String documentId) async =>
      Directory.current;
}

final class _DelayedAssetRepository implements DocumentRepository {
  final Completer<void> assetDirectoryRequested = Completer<void>();
  final Completer<Directory> assetDirectoryResult = Completer<Directory>();

  @override
  Future<Directory> assetDirectory(String documentId) {
    if (!assetDirectoryRequested.isCompleted) {
      assetDirectoryRequested.complete();
    }
    return assetDirectoryResult.future;
  }

  @override
  Future<void> delete(String documentId) async {}

  @override
  Future<List<DocumentSummary>> list() async => const <DocumentSummary>[];

  @override
  Future<WhiteboardDocument?> load(String documentId) async => null;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => null;

  @override
  Future<void> save(WhiteboardDocument document) async {}
}
