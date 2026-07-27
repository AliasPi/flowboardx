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
import 'package:flowboard_x/src/features/board/engine/board_viewport.dart';
import 'package:flowboard_x/src/features/board/presentation/board_surface.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flowboard_x/src/features/templates/templates.dart';
import 'package:flowboard_x/src/platform/android_palm_input.dart';
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

  testWidgets(
    'external gesture suppression cancels and blocks transient board pointers',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final controller = EditorController(
        document: WhiteboardDocument.create(id: 'gesture-arbitration'),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      final suppression = ValueNotifier<bool>(false);
      addTearDown(suppression.dispose);
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BoardSurface(
              controller: controller,
              inputSuppression: suppression,
            ),
          ),
        ),
      );
      await tester.pump();

      final persistedOffset = Offset(
        controller.page.viewport.offsetX,
        controller.page.viewport.offsetY,
      );
      final persistedScale = controller.page.viewport.zoom;
      final firstGesture = await tester.startGesture(
        const Offset(350, 350),
        kind: PointerDeviceKind.touch,
      );
      final secondGesture = await tester.startGesture(
        const Offset(550, 350),
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );
      await firstGesture.moveTo(const Offset(300, 330));
      await secondGesture.moveTo(const Offset(620, 370));
      await tester.pump();
      expect(
        controller.viewport.offset != persistedOffset ||
            controller.viewport.scale != persistedScale,
        isTrue,
      );

      suppression.value = true;
      await tester.pump();
      expect(controller.viewport.offset, persistedOffset);
      expect(controller.viewport.scale, persistedScale);
      await firstGesture.moveBy(const Offset(-120, -60));
      await secondGesture.moveBy(const Offset(80, 30));
      await tester.pump();
      expect(controller.viewport.offset, persistedOffset);
      expect(controller.viewport.scale, persistedScale);
      expect(controller.inkSessions.sessions, isEmpty);
      await firstGesture.up();
      await secondGesture.up();

      suppression.value = false;
      await tester.pump();
      final ordinaryTouch = await tester.startGesture(
        const Offset(450, 350),
        pointer: 22,
        kind: PointerDeviceKind.touch,
      );
      await ordinaryTouch.moveBy(const Offset(-120, -60));
      await ordinaryTouch.up();
      await tester.pump();
      expect(controller.viewport.offset, isNot(persistedOffset));
      await controller.flush();
    },
  );

  testWidgets(
    'five-finger arbitration rolls an independent split viewport back',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final controller = EditorController(
        document: WhiteboardDocument.create(id: 'split-gesture-arbitration'),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      final viewport = BoardViewport(scale: 1.2, offset: const Offset(35, 25));
      final suppression = ValueNotifier<bool>(false);
      addTearDown(suppression.dispose);
      addTearDown(viewport.dispose);
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BoardSurface(
              controller: controller,
              viewport: viewport,
              inputSuppression: suppression,
            ),
          ),
        ),
      );
      final originalOffset = viewport.offset;
      final originalScale = viewport.scale;
      final first = await tester.startGesture(
        const Offset(350, 350),
        pointer: 901,
        kind: PointerDeviceKind.touch,
      );
      final second = await tester.startGesture(
        const Offset(550, 350),
        pointer: 902,
        kind: PointerDeviceKind.touch,
      );
      await first.moveTo(const Offset(300, 330));
      await second.moveTo(const Offset(620, 370));
      expect(
        viewport.offset != originalOffset || viewport.scale != originalScale,
        isTrue,
      );

      suppression.value = true;
      await tester.pump();
      expect(viewport.offset, originalOffset);
      expect(viewport.scale, originalScale);
      await first.up();
      await second.up();
      await controller.flush();
    },
  );

  testWidgets(
    'native Samsung palm trace rolls navigation back and commits one erase',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final source = _PalmInputSource();
      addTearDown(source.dispose);
      final base = WhiteboardDocument.create(id: 'native-samsung-palm');
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              strokes: <InkStroke>[
                InkStroke(
                  id: 'native-palm-target',
                  points: const <InkPoint>[
                    InkPoint(x: 430, y: 260),
                    InkPoint(x: 540, y: 360),
                  ],
                  width: 8,
                ),
              ],
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
          home: Scaffold(
            body: BoardSurface(controller: controller, palmInputSource: source),
          ),
        ),
      );
      final initialOffset = controller.viewport.offset;
      final initialScale = controller.viewport.scale;
      final first = await tester.startGesture(
        const Offset(300, 300),
        pointer: 401,
        kind: PointerDeviceKind.touch,
      );
      final second = await tester.startGesture(
        const Offset(600, 300),
        pointer: 402,
        kind: PointerDeviceKind.touch,
      );
      await first.moveBy(const Offset(35, 15));
      await second.moveBy(const Offset(55, -15));
      expect(
        controller.viewport.offset != initialOffset ||
            controller.viewport.scale != initialScale,
        isTrue,
      );

      source.add(
        const NativePalmStroke(
          sessionId: 'samsung:100:7',
          points: <Offset>[
            Offset(420, 260),
            Offset(480, 310),
            Offset(550, 370),
          ],
          radius: 34,
          contactCount: 2,
          source: 'system_canceled',
        ),
      );
      await tester.pump();
      expect(controller.viewport.offset, initialOffset);
      expect(controller.viewport.scale, initialScale);
      expect(controller.page.strokes, hasLength(1));
      expect(controller.renderStrokes, isEmpty);
      expect(controller.canUndo, isFalse);

      await first.up();
      await second.up();
      await tester.pump(const Duration(milliseconds: 220));
      expect(controller.page.strokes, isEmpty);
      expect(controller.canUndo, isTrue);
      controller.undo();
      expect(controller.page.strokes, hasLength(1));
      expect(controller.canUndo, isFalse);
      await controller.flush();
    },
  );

  test('swept eraser previews continuously and commits as one undo', () async {
    final base = WhiteboardDocument.create(id: 'swept-eraser');
    final crossed = InkStroke(
      id: 'crossed',
      points: const <InkPoint>[
        InkPoint(x: 300, y: 180),
        InkPoint(x: 300, y: 420),
      ],
      width: 8,
    );
    final untouched = InkStroke(
      id: 'untouched',
      points: const <InkPoint>[
        InkPoint(x: 700, y: 180),
        InkPoint(x: 700, y: 420),
      ],
      width: 8,
    );
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(strokes: <InkStroke>[crossed, untouched]),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });

    controller.eraseAlong(
      const Offset(120, 300),
      const Offset(480, 300),
      radius: 20,
    );

    // No document command has run yet, but only the covered middle disappears
    // live; the two untouched ends remain as separate render fragments.
    expect(controller.page.strokes, hasLength(2));
    expect(controller.renderStrokes, hasLength(3));
    expect(
      controller.renderStrokes.where((stroke) => stroke.id == 'untouched'),
      hasLength(1),
    );
    final previewFragments = controller.renderStrokes
        .where((stroke) => stroke.id != 'untouched')
        .toList(growable: false);
    expect(previewFragments, hasLength(2));
    expect(previewFragments.first.points.last.y, closeTo(276, .001));
    expect(previewFragments.last.points.first.y, closeTo(324, .001));
    expect(controller.canUndo, isFalse);

    controller.cancelErase();
    expect(controller.renderStrokes, hasLength(2));

    controller.eraseAlong(
      const Offset(120, 300),
      const Offset(480, 300),
      radius: 20,
    );
    controller.commitErase();
    expect(controller.page.strokes, hasLength(3));
    expect(controller.canUndo, isTrue);
    controller.undo();
    expect(controller.page.strokes.map((stroke) => stroke.id), [
      'crossed',
      'untouched',
    ]);
  });

  test('one compound eraser footprint publishes one preview frame', () async {
    final base = WhiteboardDocument.create(id: 'batched-eraser-preview');
    final stroke = InkStroke(
      id: 'wide-stroke',
      points: const <InkPoint>[
        InkPoint(x: 100, y: 200),
        InkPoint(x: 500, y: 200),
      ],
      width: 10,
    );
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(strokes: <InkStroke>[stroke]),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.eraseSweeps(const <InkEraserSweep>[
      (start: Offset(180, 200), end: Offset(200, 200), radius: 12),
      (start: Offset(200, 200), end: Offset(220, 200), radius: 12),
      (start: Offset(220, 200), end: Offset(240, 200), radius: 12),
      (start: Offset(240, 200), end: Offset(260, 200), radius: 12),
      (start: Offset(260, 200), end: Offset(280, 200), radius: 12),
    ]);

    expect(notifications, 1);
    expect(controller.renderStrokes.length, greaterThan(1));
  });

  test(
    'eraser rebases a dissolved selected group and removes dead selection ids',
    () async {
      final base = WhiteboardDocument.create(id: 'erase-selected-group');
      final left = InkStroke(
        id: 'left',
        points: const <InkPoint>[
          InkPoint(x: 300, y: 180),
          InkPoint(x: 300, y: 420),
        ],
      );
      final right = InkStroke(
        id: 'right',
        points: const <InkPoint>[
          InkPoint(x: 700, y: 180),
          InkPoint(x: 700, y: 420),
        ],
      );
      final group = ContentGroup(
        id: 'selected-group',
        memberIds: const <String>['left', 'right'],
        bounds: left.bounds.union(right.bounds),
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              strokes: <InkStroke>[left, right],
              contentGroups: <ContentGroup>[group],
              selection: SelectionState(
                selectedItemIds: const <String>['selected-group'],
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

      controller.eraseAt(const Offset(300, 300), radius: 200);
      controller.commitErase();
      expect(controller.page.contentGroups, isEmpty);
      expect(controller.selectedIds, <String>{'right'});
      expect(controller.hasSelection, isTrue);

      controller.eraseAt(const Offset(700, 300), radius: 200);
      controller.commitErase();
      expect(controller.page.strokes, isEmpty);
      expect(controller.selectedIds, isEmpty);
      expect(controller.hasSelection, isFalse);
    },
  );

  test('object-bound ink participates in the live eraser preview', () async {
    final base = WhiteboardDocument.create(id: 'annotation-eraser');
    final image = ImageObject(
      id: 'image',
      assetId: 'asset',
      transform: const ObjectTransform(x: 100, y: 100, width: 400, height: 300),
    );
    final annotation = InkStroke(
      id: 'annotation',
      points: const <InkPoint>[InkPoint(x: .5, y: .1), InkPoint(x: .5, y: .9)],
      width: .02,
    );
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(
            objects: <BoardObject>[image],
            annotationLayers: <ObjectInkLayer>[
              ObjectInkLayer(
                id: 'image-ink',
                objectId: image.id,
                strokes: <InkStroke>[annotation],
              ),
            ],
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

    controller.eraseAlong(
      const Offset(120, 250),
      const Offset(480, 250),
      radius: 18,
    );
    expect(controller.page.annotationLayers.single.strokes, hasLength(1));
    expect(controller.renderAnnotationLayers.single.strokes, hasLength(2));
    controller.commitErase();
    expect(controller.page.annotationLayers.single.strokes, hasLength(2));
    controller.undo();
    expect(controller.page.annotationLayers.single.strokes, hasLength(1));
  });

  test(
    'annotation eraser is anisotropic and only affects the rendered PDF layer',
    () async {
      final base = WhiteboardDocument.create(id: 'annotation-eraser-geometry');
      final pdf = PdfObject(
        id: 'wide-pdf',
        assetId: 'asset',
        pageIndices: const <int>[0, 1],
        activePageIndex: 0,
        transform: const ObjectTransform(
          x: 100,
          y: 100,
          width: 1000,
          height: 100,
        ),
      );
      InkStroke vertical(String id, double x) => InkStroke(
        id: id,
        points: <InkPoint>[
          InkPoint(x: x, y: .2),
          InkPoint(x: x, y: .8),
        ],
        width: .04,
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              objects: <BoardObject>[pdf],
              annotationLayers: <ObjectInkLayer>[
                ObjectInkLayer(
                  id: 'active-visible',
                  objectId: pdf.id,
                  pdfPageIndex: 0,
                  strokes: <InkStroke>[
                    vertical('near', .2),
                    vertical('far', .5),
                  ],
                ),
                ObjectInkLayer(
                  id: 'other-page',
                  objectId: pdf.id,
                  pdfPageIndex: 1,
                  strokes: <InkStroke>[vertical('other-page-ink', .2)],
                ),
                ObjectInkLayer(
                  id: 'hidden-active',
                  objectId: pdf.id,
                  pdfPageIndex: 0,
                  visible: false,
                  strokes: <InkStroke>[vertical('hidden-ink', .2)],
                ),
              ],
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

      controller.eraseAt(const Offset(300, 150), radius: 30);
      expect(
        controller.renderAnnotationLayers
            .firstWhere((layer) => layer.id == 'active-visible')
            .strokes
            .map((stroke) => stroke.id),
        <String>['far'],
      );
      controller.commitErase();

      expect(
        controller.page.annotationLayers
            .firstWhere((layer) => layer.id == 'active-visible')
            .strokes
            .map((stroke) => stroke.id),
        <String>['far'],
      );
      expect(
        controller.page.annotationLayers
            .firstWhere((layer) => layer.id == 'other-page')
            .strokes
            .map((stroke) => stroke.id),
        <String>['other-page-ink'],
      );
      expect(
        controller.page.annotationLayers
            .firstWhere((layer) => layer.id == 'hidden-active')
            .strokes
            .map((stroke) => stroke.id),
        <String>['hidden-ink'],
      );
    },
  );

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

  testWidgets(
    'clustered ordinary contacts roll navigation back and erase in one undo',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final base = WhiteboardDocument.create(id: 'clustered-fist-surface');
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              strokes: <InkStroke>[
                InkStroke(
                  id: 'cluster-left',
                  points: const <InkPoint>[
                    InkPoint(x: 440, y: 295),
                    InkPoint(x: 440, y: 305),
                  ],
                  width: 8,
                ),
                InkStroke(
                  id: 'cluster-right',
                  points: const <InkPoint>[
                    InkPoint(x: 480, y: 295),
                    InkPoint(x: 480, y: 305),
                  ],
                  width: 8,
                ),
              ],
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
      final persistedOffset = controller.viewport.offset;
      final persistedScale = controller.viewport.scale;

      for (final contact in const <(int, Offset)>[
        (101, Offset(420, 300)),
        (102, Offset(450, 320)),
        (103, Offset(480, 295)),
      ]) {
        await tester.sendEventToBinding(
          PointerDownEvent(
            pointer: contact.$1,
            device: contact.$1,
            kind: PointerDeviceKind.touch,
            position: contact.$2,
            radiusMajor: 7,
            radiusMinor: 5,
            size: .1,
          ),
        );
      }
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 101,
          device: 101,
          kind: PointerDeviceKind.touch,
          position: Offset(440, 310),
          delta: Offset(20, 10),
          buttons: kPrimaryButton,
          radiusMajor: 7,
          radiusMinor: 5,
          size: .1,
        ),
      );
      expect(
        controller.viewport.offset != persistedOffset ||
            controller.viewport.scale != persistedScale,
        isTrue,
      );

      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 102,
          device: 102,
          kind: PointerDeviceKind.touch,
          position: Offset(470, 330),
          delta: Offset(20, 10),
          buttons: kPrimaryButton,
          radiusMajor: 7,
          radiusMinor: 5,
          size: .1,
        ),
      );
      await tester.pump();

      expect(controller.viewport.offset, persistedOffset);
      expect(controller.viewport.scale, persistedScale);
      expect(controller.page.strokes, hasLength(2));
      expect(controller.renderStrokes, isEmpty);
      expect(controller.canUndo, isFalse);

      for (final contact in const <(int, Offset)>[
        (101, Offset(440, 310)),
        (102, Offset(470, 330)),
      ]) {
        await tester.sendEventToBinding(
          PointerUpEvent(
            pointer: contact.$1,
            device: contact.$1,
            kind: PointerDeviceKind.touch,
            position: contact.$2,
          ),
        );
      }
      expect(controller.page.strokes, hasLength(2));
      expect(controller.canUndo, isFalse);
      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 103,
          device: 103,
          kind: PointerDeviceKind.touch,
          position: Offset(480, 295),
        ),
      );
      await tester.pump();

      expect(controller.page.strokes, isEmpty);
      expect(controller.canUndo, isTrue);
      controller.undo();
      expect(controller.page.strokes, hasLength(2));
      expect(controller.canUndo, isFalse);
      expect(controller.canRedo, isTrue);
      await controller.flush();
    },
  );

  testWidgets(
    'broadness first reported on PointerCancel replays the buffered erase path',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final base = WhiteboardDocument.create(id: 'late-cancel-palm');
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              strokes: <InkStroke>[
                InkStroke(
                  id: 'cancel-path-target',
                  points: const <InkPoint>[
                    InkPoint(x: 390, y: 300),
                    InkPoint(x: 530, y: 300),
                  ],
                  width: 8,
                ),
              ],
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
      final initialOffset = controller.viewport.offset;
      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 451,
          device: 451,
          kind: PointerDeviceKind.touch,
          position: Offset(390, 300),
          radiusMajor: 8,
          radiusMinor: 6,
          size: .12,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 451,
          device: 451,
          kind: PointerDeviceKind.touch,
          position: Offset(500, 300),
          delta: Offset(110, 0),
          buttons: kPrimaryButton,
          radiusMajor: 8,
          radiusMinor: 6,
          size: .12,
        ),
      );
      expect(controller.viewport.offset, isNot(initialOffset));
      await tester.sendEventToBinding(
        const PointerCancelEvent(
          pointer: 451,
          device: 451,
          kind: PointerDeviceKind.touch,
          position: Offset(530, 300),
          radiusMajor: 20,
          radiusMinor: 13,
          size: .25,
        ),
      );
      await tester.pump();

      expect(controller.viewport.offset, initialOffset);
      expect(controller.page.strokes, hasLength(1));
      expect(controller.renderStrokes, isEmpty);
      await tester.pump(const Duration(milliseconds: 220));
      expect(controller.page.strokes, isEmpty);
      controller.undo();
      expect(controller.page.strokes, hasLength(1));
      expect(controller.canUndo, isFalse);
      await controller.flush();
    },
  );

  testWidgets(
    'late palm footprint cancels shape preview and erases continuously',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final base = WhiteboardDocument.create(id: 'late-palm-surface');
      final crossed = InkStroke(
        id: 'crossed',
        points: const <InkPoint>[
          InkPoint(x: 560, y: 295),
          InkPoint(x: 560, y: 305),
        ],
        width: 8,
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(strokes: <InkStroke>[crossed]),
          ],
        ),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      )..setTool(BoardTool.shape);
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BoardSurface(controller: controller)),
        ),
      );

      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 31,
          device: 31,
          kind: PointerDeviceKind.touch,
          position: Offset(180, 300),
          radiusMajor: 8,
          radiusMinor: 6,
          size: .12,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 31,
          device: 31,
          kind: PointerDeviceKind.touch,
          position: Offset(380, 300),
          delta: Offset(200, 0),
          radiusMajor: 30,
          radiusMinor: 18,
          size: .34,
          buttons: kPrimaryButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 31,
          device: 31,
          kind: PointerDeviceKind.touch,
          position: Offset(720, 300),
          delta: Offset(340, 0),
          radiusMajor: 30,
          radiusMinor: 18,
          size: .34,
          buttons: kPrimaryButton,
        ),
      );
      await tester.pump();

      expect(controller.page.strokes, hasLength(1));
      expect(controller.renderStrokes, isEmpty);
      expect(controller.page.objects, isEmpty);

      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 31,
          device: 31,
          kind: PointerDeviceKind.touch,
          position: Offset(720, 300),
        ),
      );
      await tester.pump();
      expect(controller.page.strokes, isEmpty);
      expect(controller.page.objects, isEmpty);
      expect(controller.canUndo, isTrue);
      await controller.flush();
    },
  );

  testWidgets(
    'late strong palm takes over multi-touch and rolls viewport back',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final base = WhiteboardDocument.create(id: 'late-multi-palm');
      final crossed = InkStroke(
        id: 'crossed',
        points: const <InkPoint>[
          InkPoint(x: 500, y: 295),
          InkPoint(x: 500, y: 305),
        ],
        width: 8,
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(strokes: <InkStroke>[crossed]),
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
      final persistedOffset = Offset(
        controller.page.viewport.offsetX,
        controller.page.viewport.offsetY,
      );
      final persistedScale = controller.page.viewport.zoom;

      for (final contact in const <(int, double)>[(61, 200), (62, 700)]) {
        await tester.sendEventToBinding(
          PointerDownEvent(
            pointer: contact.$1,
            device: contact.$1,
            kind: PointerDeviceKind.touch,
            position: Offset(contact.$2, 300),
            radiusMajor: 8,
            radiusMinor: 6,
            size: .12,
          ),
        );
      }
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 61,
          device: 61,
          kind: PointerDeviceKind.touch,
          position: Offset(240, 280),
          delta: Offset(40, -20),
          radiusMajor: 8,
          radiusMinor: 6,
          size: .12,
          buttons: kPrimaryButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 62,
          device: 62,
          kind: PointerDeviceKind.touch,
          position: Offset(760, 320),
          delta: Offset(60, 20),
          radiusMajor: 8,
          radiusMinor: 6,
          size: .12,
          buttons: kPrimaryButton,
        ),
      );
      expect(
        controller.viewport.offset != persistedOffset ||
            controller.viewport.scale != persistedScale,
        isTrue,
      );

      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 61,
          device: 61,
          kind: PointerDeviceKind.touch,
          position: Offset(430, 300),
          delta: Offset(190, 20),
          radiusMajor: 26,
          radiusMinor: 10,
          size: .31,
          buttons: kPrimaryButton,
        ),
      );
      expect(controller.viewport.offset, persistedOffset);
      expect(controller.viewport.scale, persistedScale);
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 61,
          device: 61,
          kind: PointerDeviceKind.touch,
          position: Offset(560, 300),
          delta: Offset(130, 0),
          radiusMajor: 26,
          radiusMinor: 10,
          size: .31,
          buttons: kPrimaryButton,
        ),
      );
      await tester.pump();
      expect(controller.renderStrokes, isEmpty);

      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 61,
          device: 61,
          kind: PointerDeviceKind.touch,
          position: Offset(560, 300),
        ),
      );
      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 62,
          device: 62,
          kind: PointerDeviceKind.touch,
          position: Offset(760, 320),
        ),
      );
      await tester.pump();
      expect(controller.page.strokes, isEmpty);
      expect(controller.canUndo, isTrue);
      await controller.flush();
    },
  );

  testWidgets('broad palm down cancels existing provisional navigation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final controller = EditorController(
      document: WhiteboardDocument.create(id: 'palm-down-over-navigation'),
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
    final persistedOffset = controller.viewport.offset;

    final first = await tester.startGesture(
      const Offset(250, 300),
      pointer: 71,
      kind: PointerDeviceKind.touch,
    );
    final second = await tester.startGesture(
      const Offset(650, 300),
      pointer: 72,
      kind: PointerDeviceKind.touch,
    );
    await first.moveBy(const Offset(50, 20));
    await second.moveBy(const Offset(70, 20));
    expect(controller.viewport.offset, isNot(persistedOffset));

    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: 73,
        device: 73,
        kind: PointerDeviceKind.touch,
        position: Offset(500, 300),
        radiusMajor: 30,
        radiusMinor: 16,
        size: .34,
      ),
    );
    expect(controller.viewport.offset, persistedOffset);
    await first.moveBy(const Offset(80, 30));
    await second.moveBy(const Offset(-80, -30));
    expect(controller.viewport.offset, persistedOffset);

    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 73,
        device: 73,
        kind: PointerDeviceKind.touch,
        position: Offset(500, 300),
      ),
    );
    await first.up();
    await second.up();
    await controller.flush();
  });

  testWidgets(
    'broad fist contact rolls back an owned selection move before erasing',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final base = WhiteboardDocument.create(id: 'palm-over-selection');
      final shape = ShapeObject(
        id: 'selected-shape',
        transform: const ObjectTransform(
          x: 100,
          y: 100,
          width: 200,
          height: 200,
        ),
      );
      final stroke = InkStroke(
        id: 'erasable-stroke',
        points: const <InkPoint>[
          InkPoint(x: 500, y: 295),
          InkPoint(x: 500, y: 305),
        ],
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              objects: <BoardObject>[shape],
              strokes: <InkStroke>[stroke],
              selection: SelectionState(
                selectedItemIds: const <String>['selected-shape'],
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

      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 81,
          device: 81,
          kind: PointerDeviceKind.touch,
          position: Offset(150, 150),
          radiusMajor: 7,
          radiusMinor: 5,
          size: .12,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 81,
          device: 81,
          kind: PointerDeviceKind.touch,
          position: Offset(250, 180),
          delta: Offset(100, 30),
          radiusMajor: 7,
          radiusMinor: 5,
          size: .12,
          buttons: kPrimaryButton,
        ),
      );
      expect(controller.renderObjects.single.transform.x, 200);

      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 82,
          device: 82,
          kind: PointerDeviceKind.touch,
          position: Offset(500, 300),
          radiusMajor: 30,
          radiusMinor: 16,
          size: .34,
        ),
      );
      await tester.pump();
      expect(controller.renderObjects.single.transform.x, 100);
      expect(controller.page.objects.single.transform.x, 100);
      expect(controller.renderStrokes, isEmpty);

      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 82,
          device: 82,
          kind: PointerDeviceKind.touch,
          position: Offset(500, 300),
        ),
      );
      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 81,
          device: 81,
          kind: PointerDeviceKind.touch,
          position: Offset(250, 180),
        ),
      );
      await tester.pump();
      expect(controller.page.strokes, isEmpty);
      expect(controller.page.objects.single.transform.x, 100);
      await controller.flush();
    },
  );

  testWidgets(
    'broad palm over a selection handle wins before the resize recognizer',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final base = WhiteboardDocument.create(id: 'palm-over-resize-handle');
      const originalTransform = ObjectTransform(
        x: 200,
        y: 180,
        width: 200,
        height: 160,
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              objects: <BoardObject>[
                ShapeObject(id: 'selected-shape', transform: originalTransform),
              ],
              strokes: <InkStroke>[
                InkStroke(
                  id: 'behind-resize-handle',
                  points: const <InkPoint>[
                    InkPoint(x: 380, y: 340),
                    InkPoint(x: 520, y: 340),
                  ],
                  width: 8,
                ),
              ],
              selection: SelectionState(
                selectedItemIds: const <String>['selected-shape'],
              ),
            ),
          ],
        ),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      )..setTool(BoardTool.selectRectangle);
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
      final handle = tester.getCenter(
        find.bySemanticsLabel('Auswahl skalieren'),
      );

      await tester.sendEventToBinding(
        PointerDownEvent(
          pointer: 490,
          device: 490,
          kind: PointerDeviceKind.touch,
          position: handle,
          radiusMajor: 31,
          radiusMinor: 18,
          size: .34,
        ),
      );
      await tester.sendEventToBinding(
        PointerMoveEvent(
          pointer: 490,
          device: 490,
          kind: PointerDeviceKind.touch,
          position: handle + const Offset(110, 0),
          delta: const Offset(110, 0),
          buttons: kPrimaryButton,
          radiusMajor: 31,
          radiusMinor: 18,
          size: .34,
        ),
      );
      await tester.sendEventToBinding(
        PointerUpEvent(
          pointer: 490,
          device: 490,
          kind: PointerDeviceKind.touch,
          position: handle + const Offset(110, 0),
          radiusMajor: 31,
          radiusMinor: 18,
          size: .34,
        ),
      );
      await tester.pump();

      expect(controller.page.objects.single.transform, originalTransform);
      // The accurately centred palm footprint no longer expands the major
      // axis into an oversized circle. It still wins arbitration and removes
      // the swept section beneath the hand without resizing the selection.
      expect(_strokesCrossX(controller.page.strokes, 450), isFalse);
      controller.undo();
      expect(controller.page.strokes, hasLength(1));
      expect(controller.page.objects.single.transform, originalTransform);
      await controller.flush();
    },
  );

  testWidgets('broad palm over the navigator cannot move the camera', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final controller = EditorController(
      document: WhiteboardDocument.create(id: 'palm-over-navigator'),
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
    final first = await tester.startGesture(
      const Offset(250, 250),
      pointer: 501,
      kind: PointerDeviceKind.touch,
    );
    final second = await tester.startGesture(
      const Offset(650, 250),
      pointer: 502,
      kind: PointerDeviceKind.touch,
    );
    await first.moveBy(const Offset(40, 20));
    await second.moveBy(const Offset(80, -20));
    await first.up();
    await second.up();
    await tester.pump();
    final navigator = find.byKey(const ValueKey('board-navigator'));
    expect(navigator, findsOneWidget);
    final center = tester.getCenter(navigator);
    final beforeScale = controller.viewport.scale;
    final beforeOffset = controller.viewport.offset;

    await tester.sendEventToBinding(
      PointerDownEvent(
        pointer: 503,
        device: 503,
        kind: PointerDeviceKind.touch,
        position: center,
        radiusMajor: 30,
        radiusMinor: 17,
        size: .33,
      ),
    );
    await tester.sendEventToBinding(
      PointerMoveEvent(
        pointer: 503,
        device: 503,
        kind: PointerDeviceKind.touch,
        position: center + const Offset(-90, -35),
        delta: const Offset(-90, -35),
        buttons: kPrimaryButton,
        radiusMajor: 30,
        radiusMinor: 17,
        size: .33,
      ),
    );
    await tester.sendEventToBinding(
      PointerUpEvent(
        pointer: 503,
        device: 503,
        kind: PointerDeviceKind.touch,
        position: center + const Offset(-90, -35),
        radiusMajor: 30,
        radiusMinor: 17,
        size: .33,
      ),
    );
    await tester.pump();
    expect(controller.viewport.scale, beforeScale);
    expect(controller.viewport.offset, beforeOffset);
    await controller.flush();
  });

  testWidgets(
    'broad palm rests without erasing or interrupting active stylus',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final base = WhiteboardDocument.create(id: 'pen-and-palm-surface');
      final existing = InkStroke(
        id: 'existing',
        points: const <InkPoint>[
          InkPoint(x: 500, y: 295),
          InkPoint(x: 500, y: 305),
        ],
        width: 8,
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(strokes: <InkStroke>[existing]),
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

      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 41,
          device: 11,
          kind: PointerDeviceKind.stylus,
          position: Offset(100, 100),
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 41,
          device: 11,
          kind: PointerDeviceKind.stylus,
          position: Offset(170, 140),
          delta: Offset(70, 40),
          buttons: kPrimaryButton,
        ),
      );
      expect(controller.inkSessions.hasActiveStylus, isTrue);

      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 42,
          device: 22,
          kind: PointerDeviceKind.touch,
          position: Offset(420, 300),
          radiusMajor: 32,
          radiusMinor: 20,
          size: .36,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 42,
          device: 22,
          kind: PointerDeviceKind.touch,
          position: Offset(580, 300),
          delta: Offset(160, 0),
          radiusMajor: 32,
          radiusMinor: 20,
          size: .36,
          buttons: kPrimaryButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 42,
          device: 22,
          kind: PointerDeviceKind.touch,
          position: Offset(580, 300),
        ),
      );
      await tester.pump();
      expect(controller.inkSessions.hasActiveStylus, isTrue);
      expect(controller.page.strokeById('existing'), isNotNull);

      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 41,
          device: 11,
          kind: PointerDeviceKind.stylus,
          position: Offset(210, 170),
        ),
      );
      await tester.pump();
      expect(controller.inkSessions.isWriting, isFalse);
      expect(controller.page.strokes, hasLength(2));
      expect(
        controller.page.strokes
            .where((stroke) => stroke.id != 'existing')
            .single
            .authorId,
        'pointer-11',
      );
      await controller.flush();
    },
  );

  testWidgets('multiple fist contacts commit one combined undo operation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final base = WhiteboardDocument.create(id: 'multi-contact-eraser');
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(
            strokes: <InkStroke>[
              InkStroke(
                id: 'left',
                points: const [
                  InkPoint(x: 300, y: 295),
                  InkPoint(x: 300, y: 305),
                ],
              ),
              InkStroke(
                id: 'right',
                points: const [
                  InkPoint(x: 600, y: 295),
                  InkPoint(x: 600, y: 305),
                ],
              ),
            ],
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
    for (final contact in const [(51, 300.0), (52, 600.0)]) {
      await tester.sendEventToBinding(
        PointerDownEvent(
          pointer: contact.$1,
          device: contact.$1,
          kind: PointerDeviceKind.touch,
          position: Offset(contact.$2, 300),
          radiusMajor: 30,
          radiusMinor: 18,
          size: .34,
        ),
      );
    }
    await tester.pump();
    expect(controller.page.strokes, hasLength(2));
    expect(controller.renderStrokes, isEmpty);
    expect(controller.canUndo, isFalse);

    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 51,
        device: 51,
        kind: PointerDeviceKind.touch,
        position: Offset(300, 300),
      ),
    );
    expect(controller.page.strokes, hasLength(2));
    expect(controller.canUndo, isFalse);
    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 52,
        device: 52,
        kind: PointerDeviceKind.touch,
        position: Offset(600, 300),
      ),
    );
    await tester.pump();
    expect(controller.page.strokes, isEmpty);
    expect(controller.canUndo, isTrue);
    controller.undo();
    expect(controller.page.strokes, hasLength(2));
    await controller.flush();
  });

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
    'already-satisfied layer arrangement creates no history entry',
    () async {
      final base = WhiteboardDocument.create(
        id: 'layer-noop',
        now: DateTime.utc(2026, 7, 22),
      );
      final selected = ShapeObject(
        id: 'selected',
        transform: const ObjectTransform(x: 0, y: 0, width: 40, height: 40),
        zIndex: 7,
      );
      final document = base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(
            objects: <BoardObject>[selected],
            selection: SelectionState(
              selectedItemIds: const <String>['selected'],
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
      final revision = controller.document.revision;

      controller.arrangeSelection(LayerArrangement.toFront);

      expect(controller.document.revision, revision);
      expect(controller.canUndo, isFalse);
      expect(controller.page.objectById('selected'), same(selected));
    },
  );

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

final class _PalmInputSource implements PalmInputSource {
  final StreamController<NativePalmStroke> _controller =
      StreamController<NativePalmStroke>.broadcast(sync: true);

  @override
  Stream<NativePalmStroke> get strokes => _controller.stream;

  void add(NativePalmStroke stroke) => _controller.add(stroke);

  Future<void> dispose() => _controller.close();
}

bool _strokesCrossX(Iterable<InkStroke> strokes, double x) {
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
