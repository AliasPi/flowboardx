import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/engine/board_viewport.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';

const _dividerX = 960.0;

void main() {
  group('two-person content partition', () {
    test('left object stops at divider in preview and commit', () async {
      final controller = _controllerWithObjects(
        <BoardObject>[_shape('left', x: 820, width: 100)],
        selectedIds: const <String>['left'],
      );
      addTearDown(() => _disposeController(controller));
      controller.setContentHorizontalConstraint(
        const BoardViewportHorizontalConstraint(
          side: BoardViewportPartitionSide.left,
          worldBoundaryX: _dividerX,
        ),
      );

      controller.previewMoveSelection(const Offset(500, 0));

      expect(
        controller.renderObjects.single.transform.bounds.right,
        closeTo(_dividerX, 0.0001),
      );
      // A preview must not mutate the durable document.
      expect(controller.page.objects.single.transform.x, 820);

      controller.commitSelectionTransform();

      expect(
        controller.page.objects.single.transform.bounds.right,
        closeTo(_dividerX, 0.0001),
      );
    });

    test('right object stops at divider in preview and commit', () async {
      final controller = _controllerWithObjects(
        <BoardObject>[_shape('right', x: 1020, width: 100)],
        selectedIds: const <String>['right'],
      );
      addTearDown(() => _disposeController(controller));
      controller.setContentHorizontalConstraint(
        const BoardViewportHorizontalConstraint(
          side: BoardViewportPartitionSide.right,
          worldBoundaryX: _dividerX,
        ),
      );

      controller.previewMoveSelection(const Offset(-500, 0));

      expect(
        controller.renderObjects.single.transform.bounds.left,
        closeTo(_dividerX, 0.0001),
      );
      expect(controller.page.objects.single.transform.x, 1020);

      controller.commitSelectionTransform();

      expect(
        controller.page.objects.single.transform.bounds.left,
        closeTo(_dividerX, 0.0001),
      );
    });

    test('select all only selects objects owned by participant half', () async {
      final controller = _controllerWithObjects(<BoardObject>[
        _shape('left', x: 700, width: 100),
        _shape('right', x: 1100, width: 100),
      ]);
      addTearDown(() => _disposeController(controller));

      controller.setContentHorizontalConstraint(
        const BoardViewportHorizontalConstraint(
          side: BoardViewportPartitionSide.left,
          worldBoundaryX: _dividerX,
        ),
      );
      controller.selectAll();
      expect(controller.selectedIds, const <String>{'left'});

      controller.setContentHorizontalConstraint(
        const BoardViewportHorizontalConstraint(
          side: BoardViewportPartitionSide.right,
          worldBoundaryX: _dividerX,
        ),
      );
      controller.selectAll();
      expect(controller.selectedIds, const <String>{'right'});
    });

    test('removing the partition permits moving across the divider', () async {
      final controller = _controllerWithObjects(
        <BoardObject>[_shape('left', x: 820, width: 100)],
        selectedIds: const <String>['left'],
      );
      addTearDown(() => _disposeController(controller));
      controller.setContentHorizontalConstraint(
        const BoardViewportHorizontalConstraint(
          side: BoardViewportPartitionSide.left,
          worldBoundaryX: _dividerX,
        ),
      );

      controller.moveSelection(const Offset(500, 0));
      expect(
        controller.page.objects.single.transform.bounds.right,
        closeTo(_dividerX, 0.0001),
      );

      controller.setContentHorizontalConstraint(null);
      controller.moveSelection(const Offset(200, 0));

      expect(
        controller.page.objects.single.transform.bounds.left,
        greaterThan(_dividerX),
      );
    });

    test('free ink is clamped including its visible stroke width', () async {
      final base = WhiteboardDocument.create(id: 'partition-ink-test');
      final stroke = InkStroke(
        id: 'left-ink',
        width: 20,
        points: const <InkPoint>[
          InkPoint(x: 850, y: 300, timestampMicros: 1),
          InkPoint(x: 900, y: 330, timestampMicros: 2),
        ],
      );
      final page = base.currentPage.copyWith(
        strokes: <InkStroke>[stroke],
        selection: SelectionState(selectedItemIds: const <String>['left-ink']),
      );
      final controller = EditorController(
        document: base.copyWith(pages: <BoardPage>[page]),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      addTearDown(() => _disposeController(controller));
      controller.setContentHorizontalConstraint(
        const BoardViewportHorizontalConstraint(
          side: BoardViewportPartitionSide.left,
          worldBoundaryX: _dividerX,
        ),
      );

      controller.previewMoveSelection(const Offset(500, 0));
      expect(
        controller.renderStrokes.single.bounds.right,
        closeTo(_dividerX, 0.0001),
      );

      controller.commitSelectionTransform();
      expect(
        controller.page.strokes.single.bounds.right,
        closeTo(_dividerX, 0.0001),
      );
    });

    test('a persistent group remains atomic at the divider', () async {
      final base = WhiteboardDocument.create(id: 'partition-group-test');
      final first = _shape('first', x: 720, width: 80);
      final second = _shape('second', x: 840, width: 80);
      final group = ContentGroup(
        id: 'group',
        memberIds: const <String>['first', 'second'],
        bounds: first.transform.bounds.union(second.transform.bounds),
      );
      final page = base.currentPage.copyWith(
        objects: <BoardObject>[first, second],
        contentGroups: <ContentGroup>[group],
        selection: SelectionState(selectedItemIds: const <String>['group']),
      );
      final controller = EditorController(
        document: base.copyWith(pages: <BoardPage>[page]),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      addTearDown(() => _disposeController(controller));
      controller.setContentHorizontalConstraint(
        const BoardViewportHorizontalConstraint(
          side: BoardViewportPartitionSide.left,
          worldBoundaryX: _dividerX,
        ),
      );

      controller.previewMoveSelection(const Offset(500, 0));
      expect(controller.selectionBounds.right, closeTo(_dividerX, 0.0001));
      expect(
        controller.renderObjects
            .map((object) => object.transform.bounds.right)
            .reduce((left, right) => left > right ? left : right),
        closeTo(_dividerX, 0.0001),
      );

      controller.commitSelectionTransform();
      expect(controller.page.contentGroups.single.id, 'group');
      expect(
        controller.page.contentGroups.single.bounds.right,
        closeTo(_dividerX, 0.0001),
      );
      expect(controller.selectedIds, const <String>{'group'});
    });

    test('left eraser cannot alter ink owned by the right half', () async {
      final base = WhiteboardDocument.create(id: 'partition-eraser-test');
      final page = base.currentPage.copyWith(
        strokes: <InkStroke>[
          InkStroke(
            id: 'left-ink',
            points: const <InkPoint>[
              InkPoint(x: 920, y: 300),
              InkPoint(x: 945, y: 300),
            ],
          ),
          InkStroke(
            id: 'right-ink',
            points: const <InkPoint>[
              InkPoint(x: 975, y: 300),
              InkPoint(x: 1000, y: 300),
            ],
          ),
        ],
      );
      final controller = EditorController(
        document: base.copyWith(pages: <BoardPage>[page]),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      addTearDown(() => _disposeController(controller));
      controller.setContentHorizontalConstraint(
        const BoardViewportHorizontalConstraint(
          side: BoardViewportPartitionSide.left,
          worldBoundaryX: _dividerX,
        ),
      );

      controller.eraseAt(const Offset(950, 300), radius: 60);
      controller.commitErase();

      expect(controller.page.strokeById('left-ink'), isNull);
      expect(controller.page.strokeById('right-ink'), isNotNull);
      controller.undo();
      expect(controller.page.strokes.map((stroke) => stroke.id), <String>[
        'left-ink',
        'right-ink',
      ]);
    });
  });

  test(
    'large-page selection previews reuse selected members and sparse lists',
    () async {
      final base = WhiteboardDocument.create(id: 'selection-preview-cache');
      final strokes = List<InkStroke>.generate(1200, (index) {
        final x = 100.0 + index * 1.5;
        final y = 180.0 + (index % 40) * 8;
        return InkStroke(
          id: 'stroke-$index',
          points: <InkPoint>[
            InkPoint(x: x, y: y, timestampMicros: index * 2),
            InkPoint(x: x + 12, y: y + 5, timestampMicros: index * 2 + 1),
          ],
        );
      });
      const selectedIndex = 777;
      final page = base.currentPage.copyWith(
        strokes: strokes,
        objects: <BoardObject>[_shape('unrelated-object', x: 300, width: 120)],
        selection: SelectionState(
          selectedItemIds: const <String>['stroke-777'],
        ),
      );
      final controller = EditorController(
        document: base.copyWith(pages: <BoardPage>[page]),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
      );
      addTearDown(() => _disposeController(controller));
      final sourceBounds = strokes[selectedIndex].bounds;

      expect(
        controller.selectionContains(
          Offset(
            strokes[selectedIndex].points.first.x,
            strokes[selectedIndex].points.first.y,
          ),
        ),
        isTrue,
      );
      expect(controller.selectionContains(const Offset(40, 40)), isFalse);
      controller.previewMoveSelection(const Offset(25, 10));
      final firstPreview = controller.renderStrokes;
      final repeatedPreview = controller.renderStrokes;

      expect(controller.debugSelectionMemberRefreshCount, 1);
      expect(repeatedPreview, same(firstPreview));
      expect(firstPreview, hasLength(strokes.length));
      expect(firstPreview.first, same(strokes.first));
      expect(firstPreview.last, same(strokes.last));
      expect(firstPreview[selectedIndex], isNot(same(strokes[selectedIndex])));
      expect(
        firstPreview[selectedIndex].bounds.left,
        closeTo(sourceBounds.left + 25, .0001),
      );
      expect(controller.renderObjects, same(controller.page.objects));
      expect(
        controller.selectionBounds.left,
        closeTo(sourceBounds.left + 25, .0001),
      );

      controller.previewMoveSelection(const Offset(40, 15));
      final nextPreview = controller.renderStrokes;
      expect(controller.debugSelectionMemberRefreshCount, 1);
      expect(nextPreview.first, same(strokes.first));
      expect(
        nextPreview[selectedIndex].bounds.left,
        closeTo(sourceBounds.left + 40, .0001),
      );
    },
  );

  test('active page lookup is cached across repeated hot-path reads', () async {
    final initial = WhiteboardDocument.create(id: 'page-resolution-cache');
    final pages = List<BoardPage>.generate(
      100,
      (index) => BoardPage.empty(id: 'page-$index', name: 'Seite ${index + 1}'),
      growable: false,
    );
    final controller = EditorController(
      document: initial.copyWith(pages: pages, currentPageIndex: 73),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    addTearDown(() => _disposeController(controller));

    for (var index = 0; index < 2000; index++) {
      expect(controller.page.id, 'page-73');
      expect(controller.currentPageIndex, 73);
    }

    expect(
      controller.debugPageResolutionCount,
      1,
      reason:
          'pointer and render getters must not scan all document pages again',
    );
  });

  test('asset resolver survives content-only document revisions', () async {
    final controller = _controllerWithObjects(<BoardObject>[
      _shape('shape', x: 200, width: 100),
    ]);
    addTearDown(() => _disposeController(controller));
    final initialResolver = controller.assetResolver;

    controller.rename('Neuer Titel');

    expect(controller.assetResolver, same(initialResolver));
  });
}

ShapeObject _shape(String id, {required double x, required double width}) =>
    ShapeObject(
      id: id,
      transform: ObjectTransform(x: x, y: 300, width: width, height: 100),
    );

EditorController _controllerWithObjects(
  List<BoardObject> objects, {
  Iterable<String> selectedIds = const <String>[],
}) {
  final base = WhiteboardDocument.create(id: 'partition-test');
  final page = base.currentPage.copyWith(
    objects: objects,
    selection: SelectionState(selectedItemIds: selectedIds),
  );
  return EditorController(
    document: base.copyWith(pages: <BoardPage>[page]),
    repository: _MemoryRepository(),
    assetDirectory: Directory.current,
  );
}

Future<void> _disposeController(EditorController controller) async {
  await controller.close();
  controller.dispose();
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
