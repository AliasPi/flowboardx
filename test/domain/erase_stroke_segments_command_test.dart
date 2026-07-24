import 'package:flowboard_x/src/domain/commands/command_history.dart';
import 'package:flowboard_x/src/domain/commands/erase_stroke_segments_command.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/domain/serialization/document_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  InkStroke stroke(String id, double start, double end) => InkStroke(
    id: id,
    points: <InkPoint>[
      InkPoint(x: start, y: 10),
      InkPoint(x: end, y: 10),
    ],
  );

  test('atomically replaces free and annotation ink in persisted order', () {
    final base = WhiteboardDocument.create(id: 'erase-command');
    final free = stroke('free', 0, 100);
    final annotation = stroke('annotation', 0, 1);
    final image = ImageObject(
      id: 'image',
      assetId: 'asset',
      transform: const ObjectTransform(x: 0, y: 0, width: 100, height: 100),
    );
    final page = base.currentPage.copyWith(
      strokes: <InkStroke>[free, stroke('untouched', 200, 300)],
      objects: <BoardObject>[image],
      annotationLayers: <ObjectInkLayer>[
        ObjectInkLayer(
          id: 'image.ink',
          objectId: image.id,
          strokes: <InkStroke>[annotation],
        ),
      ],
    );
    final document = base.copyWith(pages: <BoardPage>[page]);
    final freeLeft = stroke('free', 0, 40);
    final freeRight = stroke('free.fragment', 60, 100);

    final result = ReplaceErasedStrokeSegmentsCommand(
      pageId: page.id,
      replacements: <String, List<InkStroke>>{
        free.id: <InkStroke>[freeLeft, freeRight],
        annotation.id: const <InkStroke>[],
      },
    ).apply(document);

    expect(result.currentPage.strokes.map((value) => value.id), <String>[
      'free',
      'free.fragment',
      'untouched',
    ]);
    expect(result.currentPage.annotationLayers.single.strokes, isEmpty);
    expect(result.revision, greaterThan(document.revision));

    final restored = const DocumentCodec().decode(
      const DocumentCodec().encode(result),
    );
    expect(restored.currentPage.strokes.map((value) => value.id), <String>[
      'free',
      'free.fragment',
      'untouched',
    ]);
    expect(restored.currentPage.annotationLayers.single.strokes, isEmpty);
  });

  test('rebases heuristic groups, persistent groups, and direct selection', () {
    final base = WhiteboardDocument.create(id: 'erase-groups');
    final first = stroke('first', 0, 100);
    final second = stroke('second', 200, 300);
    final splitA = stroke('first', 0, 30);
    final splitB = stroke('first.fragment', 70, 100);
    final page = base.currentPage.copyWith(
      strokes: <InkStroke>[first, second],
      groups: <InkGroup>[
        InkGroup(
          id: 'word',
          kind: InkGroupKind.word,
          strokeIds: const <String>['first', 'second'],
          bounds: first.bounds.union(second.bounds),
        ),
      ],
      contentGroups: <ContentGroup>[
        ContentGroup(
          id: 'manual',
          memberIds: const <String>['first', 'second'],
          bounds: first.bounds.union(second.bounds),
        ),
      ],
      selection: SelectionState(
        selectedItemIds: const <String>['first', 'manual'],
      ),
    );
    final document = base.copyWith(pages: <BoardPage>[page]);

    final result = ReplaceErasedStrokeSegmentsCommand(
      pageId: page.id,
      replacements: <String, List<InkStroke>>{
        first.id: <InkStroke>[splitA, splitB],
      },
    ).apply(document);
    final next = result.currentPage;

    expect(next.groups.single.strokeIds, <String>[
      'first',
      'first.fragment',
      'second',
    ]);
    expect(next.contentGroups.single.memberIds, <String>[
      'first',
      'first.fragment',
      'second',
    ]);
    expect(next.selection.selectedItemIds.toSet(), <String>{
      'first',
      'first.fragment',
      'manual',
    });
    expect(next.contentGroups.single.bounds.right, second.bounds.right);
  });

  test('dissolves a persistent group and selects its surviving fragments', () {
    final base = WhiteboardDocument.create(id: 'erase-dissolve-group');
    final first = stroke('first', 0, 100);
    final second = stroke('second', 200, 300);
    final page = base.currentPage.copyWith(
      strokes: <InkStroke>[first, second],
      contentGroups: <ContentGroup>[
        ContentGroup(
          id: 'manual',
          memberIds: const <String>['first', 'second'],
          bounds: first.bounds.union(second.bounds),
        ),
      ],
      selection: SelectionState(selectedItemIds: const <String>['manual']),
    );
    final document = base.copyWith(pages: <BoardPage>[page]);

    final result = ReplaceErasedStrokeSegmentsCommand(
      pageId: page.id,
      replacements: <String, List<InkStroke>>{first.id: const <InkStroke>[]},
    ).apply(document);

    expect(result.currentPage.contentGroups, isEmpty);
    expect(result.currentPage.selection.selectedItemIds, <String>['second']);
  });

  test('rejects a fragment ID colliding with another page item', () {
    final base = WhiteboardDocument.create(id: 'erase-id-collision');
    final source = stroke('source', 0, 100);
    final page = base.currentPage.copyWith(
      strokes: <InkStroke>[source, stroke('occupied', 200, 300)],
    );

    expect(
      () => ReplaceErasedStrokeSegmentsCommand(
        pageId: page.id,
        replacements: <String, List<InkStroke>>{
          source.id: <InkStroke>[stroke('occupied', 0, 20)],
        },
      ).apply(base.copyWith(pages: <BoardPage>[page])),
      throwsStateError,
    );
  });

  test('one partial erase is one reversible Undo/Redo history entry', () async {
    final base = WhiteboardDocument.create(id: 'erase-history');
    final original = stroke('source', 0, 100);
    final page = base.currentPage.copyWith(strokes: <InkStroke>[original]);
    final history = CommandHistory(base.copyWith(pages: <BoardPage>[page]));
    addTearDown(history.dispose);

    history.execute(
      ReplaceErasedStrokeSegmentsCommand(
        pageId: page.id,
        replacements: <String, List<InkStroke>>{
          original.id: <InkStroke>[
            stroke('source', 0, 40),
            stroke('source.fragment', 60, 100),
          ],
        },
      ),
    );
    expect(history.undoDepth, 1);
    expect(history.document.currentPage.strokes, hasLength(2));

    history.undo();
    expect(history.document.currentPage.strokes, hasLength(1));
    expect(history.document.currentPage.strokes.single.points.last.x, 100);

    history.redo();
    expect(
      history.document.currentPage.strokes.map((value) => value.id),
      <String>['source', 'source.fragment'],
    );
  });
}
