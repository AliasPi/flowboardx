import 'package:flowboard_x/src/domain/commands/document_commands.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/serialization/document_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('group remains serialized and transformed until explicit ungroup', () {
    final now = DateTime.utc(2026, 7, 22);
    var document = _document(now);
    final pageId = document.currentPage.id;
    document = GroupItemsCommand(pageId, 'group', const <String>[
      'a',
      'b',
    ], now: now).apply(document);
    document = TransformItemsCommand(
      pageId,
      const <String>['group'],
      const TransformDelta(dx: 80, dy: 25),
      now: now,
    ).apply(document);
    document = const DocumentCodec().decode(
      const DocumentCodec().encode(document),
    );

    final restoredGroup = document.currentPage.contentGroups.single;
    expect(restoredGroup.id, 'group');
    expect(restoredGroup.memberIds, <String>['a', 'b']);
    expect(document.currentPage.objectById('a')!.transform.x, 90);
    expect(document.currentPage.objectById('b')!.transform.x, 140);

    document = UngroupItemsCommand(pageId, 'group', now: now).apply(document);
    expect(document.currentPage.contentGroups, isEmpty);
    expect(document.currentPage.selection.selectedItemIds, <String>['a', 'b']);
  });

  test('regrouping a member consumes the complete existing group', () {
    final now = DateTime.utc(2026, 7, 22);
    var document = _document(now);
    final pageId = document.currentPage.id;
    document = GroupItemsCommand(pageId, 'first-group', const <String>[
      'a',
      'b',
    ], now: now).apply(document);

    document = GroupItemsCommand(pageId, 'merged-group', const <String>[
      'b',
      'c',
    ], now: now).apply(document);

    expect(document.currentPage.contentGroups, hasLength(1));
    expect(document.currentPage.contentGroups.single.id, 'merged-group');
    expect(
      document.currentPage.contentGroups.single.memberIds.toSet(),
      <String>{'a', 'b', 'c'},
    );
  });
}

WhiteboardDocument _document(DateTime now) {
  final base = WhiteboardDocument.create(id: 'persistent', now: now);
  BoardObject shape(String id, double x) => ShapeObject(
    id: id,
    transform: ObjectTransform(x: x, y: 10, width: 30, height: 30),
    createdAt: now,
  );
  return base.copyWith(
    pages: <BoardPage>[
      base.currentPage.copyWith(
        objects: <BoardObject>[shape('a', 10), shape('b', 60), shape('c', 110)],
      ),
    ],
  );
}
