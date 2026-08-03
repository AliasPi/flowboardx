import 'package:flowboard_x/src/domain/grouping/ink_grouping_engine.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/domain/model/scene_order.dart';
import 'package:flowboard_x/src/features/editor/editor_commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  InkStroke stroke(String id, int zIndex) => InkStroke(
    id: id,
    points: <InkPoint>[
      InkPoint(x: zIndex.toDouble(), y: 0),
      InkPoint(x: zIndex.toDouble() + 1, y: 1),
    ],
    zIndex: zIndex,
    createdAt: DateTime.utc(2026, 7, 28),
  );

  test('chunked append stays immutable with flat random access', () {
    var page = BoardPage.empty(id: 'large-page');
    final retainedSnapshots = <BoardPage>[];

    for (var index = 0; index < 8192; index++) {
      if (page.nextTopLevelSceneZIndex != index) {
        fail('unexpected z-index before append $index');
      }
      if (page.containsTopLevelStrokeId('stroke-$index')) {
        fail('future stroke ID already exists at append $index');
      }
      page = page.appendTopLevelStroke(stroke('stroke-$index', index));
      if (index == 62 || index == 63 || index == 4095) {
        retainedSnapshots.add(page);
      }
    }

    for (final index in <int>[0, 1, 62, 63, 64, 1023, 4095, 8191]) {
      expect(page.strokes[index].id, 'stroke-$index');
      expect(page.containsTopLevelStrokeId('stroke-$index'), isTrue);
    }
    expect(page.strokes.map((item) => item.id).first, 'stroke-0');
    expect(page.strokes.map((item) => item.id).last, 'stroke-8191');
    expect(page.nextTopLevelSceneZIndex, 8192);
    expect(
      () => page.strokes[0] = stroke('mutation', 0),
      throwsUnsupportedError,
    );
    expect(
      () => page.strokes.add(stroke('mutation', 0)),
      throwsUnsupportedError,
    );

    expect(retainedSnapshots[0].strokes.length, 63);
    expect(retainedSnapshots[1].strokes.length, 64);
    expect(retainedSnapshots[2].strokes.length, 4096);
    expect(retainedSnapshots[0].strokes.last.id, 'stroke-62');
    expect(retainedSnapshots[1].strokes.last.id, 'stroke-63');
    expect(retainedSnapshots[2].strokes.last.id, 'stroke-4095');
  });

  test('first append proves ancestry from a loaded plain stroke list', () {
    final loaded = BoardPage(
      id: 'loaded-page',
      name: 'Geladen',
      strokes: <InkStroke>[stroke('persisted', 0)],
    );
    expect(loaded.strokes, isNot(isA<SingleAppendSceneList<InkStroke>>()));

    final first = loaded.appendTopLevelStroke(stroke('first-new', 1));
    final firstRevision = first.strokes as SingleAppendSceneList<InkStroke>;
    expect(firstRevision.isSingleAppendOf(loaded.strokes), isTrue);

    final second = first.appendTopLevelStroke(stroke('second-new', 2));
    final secondRevision = second.strokes as SingleAppendSceneList<InkStroke>;
    expect(secondRevision.isSingleAppendOf(first.strokes), isTrue);
    expect(
      secondRevision.isSingleAppendOf(loaded.strokes),
      isFalse,
      reason: 'ancestry proof is restricted to the direct parent snapshot',
    );
  });

  test('cached scene maximum includes legacy unsorted objects and ink', () {
    final page = BoardPage(
      id: 'legacy',
      name: 'Legacy',
      objects: <BoardObject>[
        ShapeObject(
          id: 'front-object',
          transform: const ObjectTransform(x: 0, y: 0, width: 10, height: 10),
          zIndex: 900,
        ),
        ShapeObject(
          id: 'back-object',
          transform: const ObjectTransform(x: 0, y: 0, width: 10, height: 10),
          zIndex: 2,
        ),
      ],
      strokes: <InkStroke>[stroke('middle', 500), stroke('back', 1)],
    );

    expect(page.nextTopLevelSceneZIndex, 901);
    final appended = page.appendTopLevelStroke(stroke('new', 901));
    expect(appended.nextTopLevelSceneZIndex, 902);
    expect(page.nextTopLevelSceneZIndex, 901);
  });

  test('object edits preserve the populated persistent stroke summary', () {
    final page = BoardPage(
      id: 'object-edit-summary',
      name: 'Object edit',
      strokes: <InkStroke>[stroke('first', 10), stroke('front-ink', 500)],
      objects: <BoardObject>[
        ShapeObject(
          id: 'former-front-object',
          transform: const ObjectTransform(x: 0, y: 0, width: 20, height: 20),
          zIndex: 900,
        ),
      ],
    );
    // Materialize the summary exactly as a previous committed pen stroke does.
    expect(page.nextTopLevelSceneZIndex, 901);
    expect(page.containsTopLevelStrokeId('front-ink'), isTrue);

    final changedObject = page.copyWith(
      objects: <BoardObject>[
        ShapeObject(
          id: 'former-front-object',
          transform: const ObjectTransform(x: 40, y: 40, width: 20, height: 20),
          zIndex: 2,
        ),
      ],
    );

    expect(changedObject.nextTopLevelSceneZIndex, 501);
    expect(changedObject.containsTopLevelStrokeId('first'), isTrue);
    expect(changedObject.containsTopLevelStrokeId('front-ink'), isTrue);
    expect(
      changedObject
          .appendTopLevelStroke(stroke('after-object-edit', 501))
          .nextTopLevelSceneZIndex,
      502,
    );
  });

  test('object annotation append stays flat and snapshot-safe', () {
    var layer = ObjectInkLayer(
      id: 'pdf.annotations',
      objectId: 'pdf',
      strokes: <InkStroke>[
        stroke('legacy-front', 700),
        stroke('legacy-back', 2),
      ],
    );
    final retained = <ObjectInkLayer>[];

    for (var index = 0; index < 4096; index++) {
      layer = layer.appendStroke(stroke('annotation-$index', -1));
      if (index == 61 || index == 62 || index == 2047) {
        retained.add(layer);
      }
    }

    expect(layer.strokes, hasLength(4098));
    expect(layer.strokes[0].zIndex, 700);
    expect(layer.strokes[2].zIndex, 701);
    expect(layer.strokes.last.zIndex, 4796);
    expect(layer.strokes[2049].id, 'annotation-2047');
    expect(retained[0].strokes, hasLength(64));
    expect(retained[1].strokes, hasLength(65));
    expect(retained[2].strokes, hasLength(2050));
    expect(retained[0].strokes.last.id, 'annotation-61');
    expect(
      () => layer.strokes.add(stroke('mutation', 0)),
      throwsUnsupportedError,
    );
  });

  test('object annotation ancestry accepts only its direct append child', () {
    final original = ObjectInkLayer(
      id: 'image.annotations',
      objectId: 'image',
      strokes: <InkStroke>[stroke('original', 0)],
    );
    final firstChild = original.appendStroke(stroke('first-child', 0));
    final siblingChild = original.appendStroke(stroke('sibling-child', 0));
    final grandchild = firstChild.appendStroke(stroke('grandchild', 0));

    expect(firstChild.isSingleStrokeAppendOf(original), isTrue);
    expect(siblingChild.isSingleStrokeAppendOf(original), isTrue);
    expect(grandchild.isSingleStrokeAppendOf(firstChild), isTrue);
    expect(grandchild.isSingleStrokeAppendOf(original), isFalse);
    expect(siblingChild.isSingleStrokeAppendOf(firstChild), isFalse);
    expect(
      firstChild
          .copyWith(strokes: <InkStroke>[...original.strokes, stroke('x', 0)])
          .isSingleStrokeAppendOf(original),
      isFalse,
    );
  });

  test('stroke command reuses immutable grouping output in the page', () {
    final grouping = InkGroupingEngine();
    final groupedSource = BoardPage(
      id: 'group-source',
      name: 'Group source',
      strokes: <InkStroke>[stroke('source', 0)],
    );
    final grouped = grouping.regroupAll(groupedSource);
    final transferred = groupedSource.copyWith(groups: grouped.groups);
    expect(identical(transferred.groups, grouped.groups), isTrue);

    final initial = WhiteboardDocument.create(
      id: 'group-transfer',
      now: DateTime.utc(2026, 7, 28),
    );
    final command = AddStrokeAndRegroupCommand(
      pageId: initial.currentPage.id,
      stroke: stroke('new-stroke', -40),
      grouping: grouping,
    );

    final result = command.apply(initial);

    expect(result.currentPage.strokes.single.zIndex, 0);
    expect(result.currentPage.groups, isA<ImmutableModelList<InkGroup>>());
    expect(
      () => result.currentPage.groups.add(
        InkGroup(
          id: 'mutation',
          kind: InkGroupKind.letter,
          strokeIds: const <String>['new-stroke'],
          bounds: const Rect2.zero(),
        ),
      ),
      throwsUnsupportedError,
    );
    expect(
      () => command.apply(result),
      throwsA(isA<StateError>()),
      reason: 'the persistent ID index must retain duplicate protection',
    );
  });
}
