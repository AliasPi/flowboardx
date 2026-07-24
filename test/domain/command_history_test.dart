import 'package:flutter_test/flutter_test.dart';
import 'package:flowboard_x/src/domain/domain.dart';
import 'package:flowboard_x/src/features/editor/editor_commands.dart';

void main() {
  final now = DateTime.utc(2026, 7, 21);

  InkStroke stroke(String id, double x) => InkStroke(
    id: id,
    points: [
      InkPoint(x: x, y: 10, timestampMicros: 10),
      InkPoint(x: x + 10, y: 30, timestampMicros: 20),
    ],
    createdAt: now,
  );

  group('CommandHistory', () {
    test('participant undo and redo preserve interleaved foreign ink', () {
      final initial = WhiteboardDocument.create(id: 'scoped', now: now);
      final pageId = initial.currentPage.id;
      final history = CommandHistory(initial);

      history.execute(
        AddStrokeCommand(pageId, stroke('left-1', 0), now: now),
        ownerId: 'left',
      );
      history.execute(
        AddStrokeCommand(pageId, stroke('right-1', 20), now: now),
        ownerId: 'right',
      );
      expect(history.canUndoFor('left'), isTrue);
      expect(history.canUndoFor('right'), isTrue);

      history.undo(ownerId: 'left');
      expect(history.document.currentPage.strokes.map((item) => item.id), [
        'right-1',
      ]);
      expect(history.canRedoFor('left'), isTrue);
      expect(history.canRedoFor('right'), isFalse);

      history.redo(ownerId: 'left');
      expect(history.document.currentPage.strokes.map((item) => item.id), [
        'left-1',
        'right-1',
      ]);

      history.undo(ownerId: 'right');
      expect(history.document.currentPage.strokes.map((item) => item.id), [
        'left-1',
      ]);
    });

    test('one participant action does not clear the other redo branch', () {
      final initial = WhiteboardDocument.create(id: 'redo-scope', now: now);
      final pageId = initial.currentPage.id;
      final history = CommandHistory(initial);

      history.execute(
        AddStrokeCommand(pageId, stroke('left', 0), now: now),
        ownerId: 'left',
      );
      history.undo(ownerId: 'left');
      history.execute(
        AddStrokeCommand(pageId, stroke('right', 20), now: now),
        ownerId: 'right',
      );

      expect(history.canRedoFor('left'), isTrue);
      history.redo(ownerId: 'left');
      expect(history.document.currentPage.strokes.map((item) => item.id), [
        'left',
        'right',
      ]);
    });

    test('later foreign edits win when both participants touched one item', () {
      var initial = WhiteboardDocument.create(id: 'shared-item', now: now);
      final pageId = initial.currentPage.id;
      initial = AddObjectCommand(
        pageId,
        ShapeObject(
          id: 'shape',
          transform: const ObjectTransform(x: 0, y: 0, width: 100, height: 80),
          createdAt: now,
        ),
        now: now,
      ).apply(initial);
      final history = CommandHistory(initial);
      history.execute(
        TransformItemsCommand(
          pageId,
          const ['shape'],
          const TransformDelta(dx: 10),
          now: now,
        ),
        ownerId: 'left',
      );
      history.execute(
        TransformItemsCommand(
          pageId,
          const ['shape'],
          const TransformDelta(dx: 20),
          now: now,
        ),
        ownerId: 'right',
      );
      expect(history.document.currentPage.objectById('shape')!.transform.x, 30);

      history.undo(ownerId: 'left');

      expect(
        history.document.currentPage.objectById('shape')!.transform.x,
        20,
        reason:
            'selective undo removes the left delta but retains the later '
            'right delta',
      );
      expect(history.canUndoFor('right'), isTrue);
      history.undo(ownerId: 'right');
      expect(history.document.currentPage.objectById('shape')!.transform.x, 0);
    });

    test('undoes and redoes stroke changes and clears redo branches', () {
      final history = CommandHistory(
        WhiteboardDocument.create(id: 'doc', now: now),
      );
      final pageId = history.document.currentPage.id;

      history.execute(AddStrokeCommand(pageId, stroke('s1', 0), now: now));
      history.execute(AddStrokeCommand(pageId, stroke('s2', 20), now: now));
      expect(history.document.currentPage.strokes.length, 2);
      final beforeUndoRevision = history.document.revision;
      expect(history.undo().currentPage.strokes.map((item) => item.id), ['s1']);
      expect(history.document.revision, greaterThan(beforeUndoRevision));
      final beforeRedoRevision = history.document.revision;
      expect(history.redo().currentPage.strokes.length, 2);
      expect(history.document.revision, greaterThan(beforeRedoRevision));
      history.undo();
      history.execute(AddStrokeCommand(pageId, stroke('s3', 40), now: now));

      expect(history.canRedo, isFalse);
      expect(history.document.currentPage.strokes.map((item) => item.id), [
        's1',
        's3',
      ]);
    });

    test('keeps object-local annotation unchanged when object moves', () {
      var document = WhiteboardDocument.create(id: 'doc', now: now);
      final pageId = document.currentPage.id;
      final image = ImageObject(
        id: 'image',
        transform: const ObjectTransform(x: 10, y: 20, width: 100, height: 80),
        assetId: 'image-asset',
        createdAt: now,
      );
      document = AddObjectCommand(pageId, image, now: now).apply(document);
      document = AddStrokeCommand(
        pageId,
        stroke('annotation', 0),
        objectId: 'image',
        now: now,
      ).apply(document);
      final localBefore = document.currentPage
          .annotationFor('image')!
          .strokes
          .single
          .points
          .first;

      document = TransformItemsCommand(
        pageId,
        const ['image'],
        const TransformDelta(dx: 25, dy: -5, scaleX: 2, scaleY: 1.5),
        now: now,
      ).apply(document);

      final moved = document.currentPage.objectById('image')!;
      final localAfter = document.currentPage
          .annotationFor('image')!
          .strokes
          .single
          .points
          .first;
      expect(
        moved.transform,
        const ObjectTransform(x: 45, y: 25, width: 200, height: 120),
      );
      expect(localAfter.x, localBefore.x);
      expect(localAfter.y, localBefore.y);
    });

    test('scales text font size with its bounds and undo restores both', () {
      var document = WhiteboardDocument.create(id: 'doc', now: now);
      final pageId = document.currentPage.id;
      const originalTransform = ObjectTransform(
        x: 120,
        y: 80,
        width: 320,
        height: 72,
      );
      document = AddObjectCommand(
        pageId,
        TextObject(
          id: 'text',
          transform: originalTransform,
          text: 'Skalierbarer Text',
          fontSize: 32,
          createdAt: now,
        ),
        now: now,
      ).apply(document);
      final history = CommandHistory(document);

      history.execute(
        TransformItemsCommand(
          pageId,
          const ['text'],
          const TransformDelta(dx: 15, dy: -10, scaleX: 1.5, scaleY: 1.5),
          now: now,
        ),
      );

      final scaled = history.document.currentPage.objectById('text')!;
      expect(scaled, isA<TextObject>());
      expect(scaled.transform.width, 480);
      expect(scaled.transform.height, 108);
      expect((scaled as TextObject).fontSize, 48);

      history.undo();

      final restored = history.document.currentPage.objectById('text')!;
      expect(restored.transform, originalTransform);
      expect((restored as TextObject).fontSize, 32);
      expect(restored.text, 'Skalierbarer Text');
    });

    test('deleting an object also deletes its annotation layer', () {
      var document = WhiteboardDocument.create(id: 'doc', now: now);
      final pageId = document.currentPage.id;
      document = AddObjectCommand(
        pageId,
        ImageObject(
          id: 'image',
          transform: const ObjectTransform(x: 0, y: 0, width: 100, height: 100),
          assetId: 'asset',
          createdAt: now,
        ),
        now: now,
      ).apply(document);
      document = AddStrokeCommand(
        pageId,
        stroke('a1', 0),
        objectId: 'image',
        now: now,
      ).apply(document);

      document = DeleteItemsCommand(pageId, const [
        'image',
      ], now: now).apply(document);

      expect(document.currentPage.objects, isEmpty);
      expect(document.currentPage.annotationLayers, isEmpty);
    });

    test(
      'clear handwriting preserves objects while clear all resets content',
      () {
        var document = WhiteboardDocument.create(id: 'doc', now: now);
        final pageId = document.currentPage.id;
        document = AddObjectCommand(
          pageId,
          ShapeObject(
            id: 'shape',
            transform: const ObjectTransform(x: 0, y: 0, width: 50, height: 50),
            createdAt: now,
          ),
          now: now,
        ).apply(document);
        document = AddStrokeCommand(
          pageId,
          stroke('s1', 0),
          now: now,
        ).apply(document);

        final withoutInk = ClearPageCommand(
          pageId,
          scope: ClearPageScope.handwriting,
          now: now,
        ).apply(document);
        expect(withoutInk.currentPage.strokes, isEmpty);
        expect(withoutInk.currentPage.objects.single.id, 'shape');

        final empty = ClearPageCommand(pageId, now: now).apply(document);
        expect(empty.currentPage.strokes, isEmpty);
        expect(empty.currentPage.objects, isEmpty);
      },
    );

    test('adds, selects and removes real pages', () {
      var document = WhiteboardDocument.create(id: 'doc', now: now);
      document = AddPageCommand(
        BoardPage.empty(id: 'p2'),
        now: now,
      ).apply(document);
      expect(document.pages.length, 2);
      expect(document.currentPage.id, 'p2');

      document = SelectPageCommand('doc_page_1', now: now).apply(document);
      expect(document.currentPageIndex, 0);
      document = RemovePageCommand('p2', now: now).apply(document);
      expect(document.pages.single.id, 'doc_page_1');
      expect(
        () => RemovePageCommand('doc_page_1').apply(document),
        throwsStateError,
      );
    });

    test('groups mixed content and transforms it as one selection', () {
      var document = WhiteboardDocument.create(id: 'doc', now: now);
      final pageId = document.currentPage.id;
      document = AddStrokeCommand(
        pageId,
        stroke('s1', 0),
        now: now,
      ).apply(document);
      document = AddObjectCommand(
        pageId,
        ShapeObject(
          id: 'shape',
          transform: const ObjectTransform(x: 50, y: 10, width: 40, height: 40),
          createdAt: now,
        ),
        now: now,
      ).apply(document);
      document = GroupItemsCommand(pageId, 'group', const [
        's1',
        'shape',
      ], now: now).apply(document);

      expect(document.currentPage.contentGroups.single.memberIds, [
        's1',
        'shape',
      ]);
      document = TransformItemsCommand(
        pageId,
        const ['group'],
        const TransformDelta(dx: 100),
        now: now,
      ).apply(document);
      expect(document.currentPage.strokeById('s1')!.points.first.x, 100);
      expect(document.currentPage.objectById('shape')!.transform.x, 150);
      expect(
        document.currentPage.contentGroups.single.bounds.left,
        closeTo(98, 0.001),
      );

      document = UngroupItemsCommand(pageId, 'group', now: now).apply(document);
      expect(document.currentPage.contentGroups, isEmpty);
      expect(document.currentPage.selection.selectedItemIds, ['s1', 'shape']);
    });

    test('untracked navigation survives content undo and redo', () {
      var initial = WhiteboardDocument.create(id: 'doc', now: now);
      initial = AddPageCommand(
        BoardPage.empty(id: 'p2'),
        selectNewPage: false,
        now: now,
      ).apply(initial);
      final history = CommandHistory(initial);
      final firstPageId = initial.pages.first.id;
      history.execute(
        AddStrokeCommand(firstPageId, stroke('content', 0), now: now),
      );
      history.executeUntracked(SelectPageCommand('p2', now: now));
      history.executeUntracked(
        const UpdateViewportCommand(
          'p2',
          ViewportState(offsetX: 40, offsetY: -20, zoom: 1.4),
        ),
      );

      history.undo();
      expect(history.document.currentPage.id, 'p2');
      expect(history.document.currentPage.viewport.zoom, 1.4);
      expect(history.document.pageById(firstPageId)!.strokes, isEmpty);

      history.redo();
      expect(history.document.currentPage.id, 'p2');
      expect(
        history.document.pageById(firstPageId)!.strokes.single.id,
        'content',
      );
    });

    test('menu position is independent from content undo and redo', () {
      final initial = WhiteboardDocument.create(id: 'doc', now: now);
      final history = CommandHistory(initial);
      final pageId = initial.currentPage.id;
      history.execute(AddStrokeCommand(pageId, stroke('content', 0), now: now));
      history.executeUntracked(
        ReplaceDocumentCommand(
          history.document.copyWith(
            metadata: history.document.metadata.copyWith(
              custom: const {'radialMenuX': '.27', 'radialMenuY': '.73'},
            ),
          ),
          'Menüposition speichern',
        ),
      );

      history.undo();
      expect(history.document.metadata.custom['radialMenuX'], '.27');
      expect(history.document.metadata.custom['radialMenuY'], '.73');
      history.redo();
      expect(history.document.metadata.custom['radialMenuX'], '.27');
      expect(history.document.metadata.custom['radialMenuY'], '.73');
    });
  });
}
