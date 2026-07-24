import 'dart:io';
import 'dart:math' as math;

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/features/board/presentation/board_surface.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('lower-left handle previews, commits and undoes free rotation', (
    tester,
  ) async {
    final controller = _selectedShapeController();
    await _pumpBoard(tester, controller);
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });

    final handle = find.byKey(const ValueKey('selection-rotation-handle'));
    expect(handle, findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveBy(const Offset(-85, -70));
    await gesture.moveBy(const Offset(-40, 35));
    await tester.pump();

    expect(
      controller.renderObjects.single.transform.rotationRadians.abs(),
      greaterThan(.1),
    );
    expect(controller.page.objects.single.transform.rotationRadians, 0);

    await gesture.up();
    await tester.pump();
    final committed = controller.page.objects.single.transform.rotationRadians;
    expect(committed.abs(), greaterThan(.1));
    expect(controller.canUndo, isTrue);

    controller.undo();
    expect(controller.page.objects.single.transform.rotationRadians, 0);
    await controller.flush();
  });

  testWidgets(
    'holding rotation handle offers presets, mirror and manual mode',
    (tester) async {
      final controller = _selectedShapeController();
      await _pumpBoard(tester, controller);
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      final handle = find.byKey(const ValueKey('selection-rotation-handle'));
      await tester.longPress(handle);
      await tester.pumpAndSettle();

      expect(find.text('30°'), findsOneWidget);
      expect(find.text('45°'), findsOneWidget);
      expect(find.text('60°'), findsOneWidget);
      expect(find.text('90°'), findsOneWidget);
      expect(find.text('Horizontal spiegeln'), findsOneWidget);
      expect(find.text('Winkel manuell festlegen'), findsOneWidget);

      await tester.tap(find.text('45°'));
      await tester.pumpAndSettle();
      expect(
        controller.page.objects.single.transform.rotationRadians,
        closeTo(math.pi / 4, .0001),
      );
    },
  );

  testWidgets('cover selection exposes the complete object action bar', (
    tester,
  ) async {
    final base = WhiteboardDocument.create(id: 'selected-cover');
    final cover = CoverObject(
      id: 'cover',
      transform: const ObjectTransform(x: 140, y: 160, width: 420, height: 260),
    );
    final controller = EditorController(
      document: base.copyWith(
        pages: [
          base.currentPage.copyWith(
            objects: [cover],
            selection: SelectionState(selectedItemIds: const ['cover']),
          ),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    await _pumpBoard(tester, controller);
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });

    expect(find.byIcon(Icons.copy_all_rounded), findsOneWidget);
    expect(find.byIcon(Icons.content_copy_rounded), findsOneWidget);
    expect(find.byIcon(Icons.content_cut_rounded), findsOneWidget);
    expect(find.byIcon(Icons.layers_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.copy_all_rounded));
    await tester.pump();
    expect(controller.page.objects.whereType<CoverObject>(), hasLength(2));
    expect(controller.selectedCover, isNotNull);
    await controller.flush();
  });

  test('new covers are inserted above every existing scene item', () async {
    final base = WhiteboardDocument.create(id: 'cover-front');
    final existing = ShapeObject(
      id: 'existing',
      transform: const ObjectTransform(x: 20, y: 20, width: 80, height: 80),
      zIndex: 41,
    );
    final controller = EditorController(
      document: base.copyWith(
        pages: [
          base.currentPage.copyWith(objects: [existing]),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });

    controller.addCover(at: const Offset(200, 200));

    final cover = controller.page.objects.whereType<CoverObject>().single;
    expect(cover.zIndex, greaterThan(existing.zIndex));
  });

  test(
    'a second rotation previews the exact bounds of the rotated object',
    () async {
      final base = WhiteboardDocument.create(id: 'second-rotation-bounds');
      final shape = ShapeObject(
        id: 'shape',
        transform: const ObjectTransform(
          x: 300,
          y: 220,
          width: 260,
          height: 80,
          rotationRadians: math.pi / 6,
        ),
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: [
            base.currentPage.copyWith(
              objects: [shape],
              selection: SelectionState(selectedItemIds: const ['shape']),
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

      controller.rotateSelectionBy(math.pi / 6);
      final onceRotated = controller.page.objects.single.transform;
      expect(onceRotated.rotationRadians, closeTo(math.pi / 3, .0001));

      final center = onceRotated.center;
      const secondDelta = math.pi / 12;
      controller.previewRotateSelection(
        secondDelta,
        anchor: Offset(center.x, center.y),
      );

      final rendered = controller.renderObjects.single.transform;
      final exact = rendered.bounds;
      final previewBounds = controller.selectionBounds;
      expect(rendered.rotationRadians, closeTo(math.pi * 5 / 12, .0001));
      _expectRectClose(previewBounds, exact);

      // This was the regression: rotating the old axis-aligned bounding box
      // produces a materially larger frame than uniting transformed content.
      final oversized = onceRotated.bounds.transformed(
        TransformDelta(anchor: center, rotationRadians: secondDelta),
      );
      expect(
        (oversized.width - previewBounds.width).abs() +
            (oversized.height - previewBounds.height).abs(),
        greaterThan(10),
      );

      controller.commitSelectionTransform();
      _expectRectClose(controller.selectionBounds, exact);
      await controller.flush();
    },
  );

  const rotatedCoverCases =
      <
        ({
          String edge,
          Offset localHandle,
          Offset opposite,
          Offset outwardDrag,
          bool changesWidth,
        })
      >[
        (
          edge: 'links',
          localHandle: Offset(0, 80),
          opposite: Offset(300, 80),
          outwardDrag: Offset(0, -40),
          changesWidth: true,
        ),
        (
          edge: 'oben',
          localHandle: Offset(150, 0),
          opposite: Offset(150, 160),
          outwardDrag: Offset(40, 0),
          changesWidth: false,
        ),
        (
          edge: 'rechts',
          localHandle: Offset(300, 80),
          opposite: Offset(0, 80),
          outwardDrag: Offset(0, 40),
          changesWidth: true,
        ),
        (
          edge: 'unten',
          localHandle: Offset(150, 160),
          opposite: Offset(150, 0),
          outwardDrag: Offset(-40, 0),
          changesWidth: false,
        ),
      ];
  for (final scenario in rotatedCoverCases) {
    testWidgets(
      'rotated cover ${scenario.edge} handle is positioned and resizes in its local axis',
      (tester) async {
        final controller = _selectedRotatedCoverController();
        await _pumpBoard(tester, controller);
        addTearDown(() async {
          await controller.close();
          controller.dispose();
        });

        final before = controller.selectedCover!.transform;
        final handle = find.bySemanticsLabel(
          'Abdeckung ${scenario.edge} skalieren',
        );
        expect(handle, findsOneWidget);
        final expectedHandle = before.localToWorld(
          Vec2(scenario.localHandle.dx, scenario.localHandle.dy),
        );
        final handleCenter = tester.getCenter(handle);
        expect(handleCenter.dx, closeTo(expectedHandle.x, .01));
        expect(handleCenter.dy, closeTo(expectedHandle.y, .01));

        final fixedBefore = before.localToWorld(
          Vec2(scenario.opposite.dx, scenario.opposite.dy),
        );
        final gesture = await tester.startGesture(
          handleCenter,
          kind: PointerDeviceKind.stylus,
        );
        await gesture.moveBy(scenario.outwardDrag / 2);
        await gesture.moveBy(scenario.outwardDrag / 2);
        await tester.pump();

        final preview = controller.renderObjects.single.transform;
        expect(preview.rotationRadians, closeTo(before.rotationRadians, .0001));
        if (scenario.changesWidth) {
          expect(preview.width, closeTo(before.width + 40, .01));
          expect(preview.height, closeTo(before.height, .01));
        } else {
          expect(preview.width, closeTo(before.width, .01));
          expect(preview.height, closeTo(before.height + 40, .01));
        }
        expect(controller.page.objects.single.transform, before);

        await gesture.up();
        await tester.pump();
        final committed = controller.selectedCover!.transform;
        final fixedAfter = committed.localToWorld(
          Vec2(
            scenario.changesWidth
                ? (scenario.opposite.dx == 0 ? 0 : committed.width)
                : committed.width / 2,
            scenario.changesWidth
                ? committed.height / 2
                : (scenario.opposite.dy == 0 ? 0 : committed.height),
          ),
        );
        expect(fixedAfter.x, closeTo(fixedBefore.x, .01));
        expect(fixedAfter.y, closeTo(fixedBefore.y, .01));

        final movedLocal = switch (scenario.edge) {
          'links' => Offset(0, committed.height / 2),
          'oben' => Offset(committed.width / 2, 0),
          'rechts' => Offset(committed.width, committed.height / 2),
          _ => Offset(committed.width / 2, committed.height),
        };
        final movedAfter = committed.localToWorld(
          Vec2(movedLocal.dx, movedLocal.dy),
        );
        expect(
          movedAfter.x,
          closeTo(expectedHandle.x + scenario.outwardDrag.dx, .01),
        );
        expect(
          movedAfter.y,
          closeTo(expectedHandle.y + scenario.outwardDrag.dy, .01),
        );
        await controller.flush();
      },
    );
  }
}

void _expectRectClose(Rect2 actual, Rect2 expected) {
  expect(actual.left, closeTo(expected.left, .0001));
  expect(actual.top, closeTo(expected.top, .0001));
  expect(actual.width, closeTo(expected.width, .0001));
  expect(actual.height, closeTo(expected.height, .0001));
}

Future<void> _pumpBoard(
  WidgetTester tester,
  EditorController controller,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 700);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: BoardSurface(controller: controller)),
    ),
  );
  await tester.pump();
}

EditorController _selectedShapeController() {
  final base = WhiteboardDocument.create(id: 'selected-shape-rotation');
  final shape = ShapeObject(
    id: 'shape',
    transform: const ObjectTransform(x: 180, y: 180, width: 260, height: 160),
  );
  return EditorController(
    document: base.copyWith(
      pages: [
        base.currentPage.copyWith(
          objects: [shape],
          selection: SelectionState(selectedItemIds: const ['shape']),
        ),
      ],
    ),
    repository: _MemoryRepository(),
    assetDirectory: Directory.current,
  );
}

EditorController _selectedRotatedCoverController() {
  final base = WhiteboardDocument.create(id: 'rotated-cover-handles');
  final cover = CoverObject(
    id: 'cover',
    transform: const ObjectTransform(
      x: 200,
      y: 180,
      width: 300,
      height: 160,
      rotationRadians: math.pi / 2,
    ),
  );
  return EditorController(
    document: base.copyWith(
      pages: [
        base.currentPage.copyWith(
          objects: [cover],
          selection: SelectionState(selectedItemIds: const ['cover']),
        ),
      ],
    ),
    repository: _MemoryRepository(),
    assetDirectory: Directory.current,
  );
}

final class _MemoryRepository implements DocumentRepository {
  WhiteboardDocument? value;

  @override
  Future<Directory> assetDirectory(String documentId) async =>
      Directory.current;

  @override
  Future<void> delete(String documentId) async => value = null;

  @override
  Future<List<DocumentSummary>> list() async => const [];

  @override
  Future<WhiteboardDocument?> load(String documentId) async => value;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => value;

  @override
  Future<void> save(WhiteboardDocument document) async => value = document;
}
