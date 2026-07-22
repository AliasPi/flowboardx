import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/selection/selection_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rectangle selects strokes and heterogeneous objects', () {
    final page = BoardPage(
      id: 'p',
      name: 'P',
      strokes: [
        InkStroke(
          id: 's',
          points: const [InkPoint(x: 10, y: 10), InkPoint(x: 30, y: 30)],
        ),
      ],
      objects: [
        ShapeObject(
          id: 'o',
          transform: const ObjectTransform(x: 40, y: 40, width: 20, height: 20),
        ),
      ],
    );
    final selected = const SelectionEngine().itemsInRectangle(
      page,
      const Rect2(left: 0, top: 0, width: 70, height: 70),
    );
    expect(selected, {'s', 'o'});
  });

  test('tap returns word/group and precise stroke candidates', () {
    final stroke = InkStroke(
      id: 's',
      points: const [InkPoint(x: 0, y: 0), InkPoint(x: 20, y: 0)],
    );
    final page = BoardPage(
      id: 'p',
      name: 'P',
      strokes: [stroke],
      groups: [
        InkGroup(
          id: 'g',
          kind: InkGroupKind.word,
          strokeIds: const ['s'],
          bounds: const Rect2(left: 0, top: -4, width: 20, height: 8),
        ),
      ],
    );
    final candidates = const SelectionEngine().candidatesAt(
      page,
      const Vec2(10, 0),
    );
    expect(
      candidates.map((candidate) => candidate.type),
      contains(SelectionCandidateType.word),
    );
    expect(
      candidates.map((candidate) => candidate.type),
      contains(SelectionCandidateType.stroke),
    );
  });

  test('tap prioritizes the top item in the mixed object and ink scene', () {
    final page = BoardPage(
      id: 'p',
      name: 'P',
      objects: [
        ShapeObject(
          id: 'object',
          transform: const ObjectTransform(x: 0, y: 0, width: 50, height: 50),
          zIndex: 1,
        ),
      ],
      strokes: [
        InkStroke(
          id: 'ink',
          points: const [InkPoint(x: 0, y: 25), InkPoint(x: 50, y: 25)],
          zIndex: 2,
        ),
      ],
    );

    final candidates = const SelectionEngine().candidatesAt(
      page,
      const Vec2(25, 25),
    );
    expect(candidates.first.id, 'ink');
  });

  test(
    'persistent groups are selected atomically by tap rectangle and lasso',
    () {
      final first = ShapeObject(
        id: 'first',
        transform: const ObjectTransform(x: 10, y: 10, width: 30, height: 30),
      );
      final second = ShapeObject(
        id: 'second',
        transform: const ObjectTransform(x: 60, y: 10, width: 30, height: 30),
      );
      final page = BoardPage(
        id: 'p',
        name: 'P',
        objects: <BoardObject>[first, second],
        contentGroups: <ContentGroup>[
          ContentGroup(
            id: 'persistent',
            memberIds: const <String>['first', 'second'],
            bounds: first.transform.bounds.union(second.transform.bounds),
          ),
        ],
      );
      const engine = SelectionEngine();

      final candidates = engine.candidatesAt(page, const Vec2(20, 20));
      expect(candidates.map((candidate) => candidate.id), <String>[
        'persistent',
      ]);
      expect(
        engine.itemsInRectangle(
          page,
          const Rect2(left: 5, top: 5, width: 40, height: 40),
        ),
        <String>{'persistent'},
      );
      expect(
        engine.itemsInLasso(page, const <Vec2>[
          Vec2(5, 5),
          Vec2(45, 5),
          Vec2(45, 45),
          Vec2(5, 45),
        ]),
        <String>{'persistent'},
      );
      expect(engine.allItems(page), <String>{'persistent'});
    },
  );
}
