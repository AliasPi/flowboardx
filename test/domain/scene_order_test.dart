import 'package:flowboard_x/src/domain/commands/document_commands.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/domain/model/scene_order.dart';
import 'package:flowboard_x/src/domain/serialization/document_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ShapeObject object(String id, int zIndex) => ShapeObject(
    id: id,
    transform: const ObjectTransform(x: 0, y: 0, width: 40, height: 40),
    zIndex: zIndex,
  );

  InkStroke stroke(String id, int zIndex) => InkStroke(
    id: id,
    points: const <InkPoint>[InkPoint(x: 0, y: 0), InkPoint(x: 20, y: 20)],
    zIndex: zIndex,
  );

  test('orders mixed object and ink content by one stable z-index', () {
    final scene = orderedBoardSceneItems(
      objects: <BoardObject>[object('object-back', 0), object('object-top', 4)],
      strokes: <InkStroke>[stroke('ink-middle', 2)],
    );

    expect(scene.map((item) => item.id), <String>[
      'object-back',
      'ink-middle',
      'object-top',
    ]);
  });

  test('legacy z-index ties retain objects-below-ink rendering', () {
    final scene = orderedBoardSceneItems(
      objects: <BoardObject>[object('object-a', 0), object('object-b', 0)],
      strokes: <InkStroke>[stroke('ink-a', 0), stroke('ink-b', 0)],
    );

    expect(scene.map((item) => item.id), <String>[
      'object-a',
      'object-b',
      'ink-a',
      'ink-b',
    ]);
  });

  test('moves a mixed selection one level and normalizes unique layers', () {
    final arranged = arrangeBoardSceneItems(
      objects: <BoardObject>[object('object', 1)],
      strokes: <InkStroke>[stroke('ink-back', 0), stroke('ink-front', 2)],
      selectedIds: const <String>{'object'},
      arrangement: SceneArrangement.oneForward,
    );

    expect(arranged.map((item) => item.id), <String>[
      'ink-back',
      'ink-front',
      'object',
    ]);
    expect(arranged.map((item) => item.zIndex), <int>[0, 1, 2]);
  });

  test('ink z-index serializes and missing legacy value defaults to zero', () {
    final encoded = stroke('ink', 27).toJson();
    expect(InkStroke.fromJson(encoded).zIndex, 27);

    final legacy = <String, Object?>{...encoded}..remove('zIndex');
    expect(InkStroke.fromJson(legacy).zIndex, 0);
  });

  test('document codec round-trips mixed scene layers', () {
    final base = WhiteboardDocument.create(
      id: 'scene-document',
      now: DateTime.utc(2026, 7, 22),
    );
    final document = base.copyWith(
      pages: <BoardPage>[
        base.currentPage.copyWith(
          objects: <BoardObject>[object('object', 9)],
          strokes: <InkStroke>[stroke('ink', 14)],
        ),
      ],
    );

    final decoded = const DocumentCodec().decode(
      const DocumentCodec().encode(document),
    );
    expect(decoded.currentPage.objectById('object')!.zIndex, 9);
    expect(decoded.currentPage.strokeById('ink')!.zIndex, 14);
  });

  test('add commands always place new free content on top', () {
    var document = WhiteboardDocument.create(
      id: 'add-document',
      now: DateTime.utc(2026, 7, 22),
    );
    final pageId = document.currentPage.id;
    document = AddObjectCommand(pageId, object('object', -50)).apply(document);
    document = AddStrokeCommand(pageId, stroke('ink', -50)).apply(document);
    document = AddObjectCommand(
      pageId,
      object('front-object', -50),
    ).apply(document);

    expect(document.currentPage.objectById('object')!.zIndex, 0);
    expect(document.currentPage.strokeById('ink')!.zIndex, 1);
    expect(document.currentPage.objectById('front-object')!.zIndex, 2);
  });
}
