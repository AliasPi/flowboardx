import 'dart:math' as math;

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

  test('stroke bounds fast path preserves a hit near the visible ink', () {
    final page = BoardPage(
      id: 'p',
      name: 'P',
      strokes: [
        InkStroke(
          id: 'wide-ink',
          points: const [InkPoint(x: 0, y: 0), InkPoint(x: 100, y: 0)],
          width: 8,
        ),
      ],
    );

    final candidates = const SelectionEngine().candidatesAt(
      page,
      const Vec2(50, 15),
      tolerance: 12,
    );

    expect(candidates.map((candidate) => candidate.id), contains('wide-ink'));
  });

  test('stroke bounds fast path preserves precise rejection far from ink', () {
    final page = BoardPage(
      id: 'p',
      name: 'P',
      strokes: [
        InkStroke(
          id: 'diagonal-ink',
          points: const [InkPoint(x: 0, y: 0), InkPoint(x: 100, y: 100)],
          width: 8,
        ),
      ],
    );

    final candidates = const SelectionEngine().candidatesAt(
      page,
      const Vec2(0, 100),
      tolerance: 12,
    );

    expect(
      candidates.map((candidate) => candidate.id),
      isNot(contains('diagonal-ink')),
    );
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

  test('dense smartboard lassos are turn-preserving and strictly bounded', () {
    final dense = List<Vec2>.generate(4096, (index) {
      final angle = math.pi * 2 * index / 4095;
      return Vec2(100 + math.cos(angle) * 80, 100 + math.sin(angle) * 60);
    }, growable: false);

    final simplified = SelectionEngine.simplifyLasso(dense);

    expect(simplified.length, lessThanOrEqualTo(256));
    expect(simplified.first, same(dense.first));
    expect(simplified.last, same(dense.last));

    final page = BoardPage(
      id: 'dense-lasso',
      name: 'Dense',
      objects: <BoardObject>[
        ShapeObject(
          id: 'inside',
          transform: const ObjectTransform(x: 90, y: 90, width: 20, height: 20),
        ),
        ShapeObject(
          id: 'outside',
          transform: const ObjectTransform(
            x: 400,
            y: 400,
            width: 20,
            height: 20,
          ),
        ),
      ],
    );
    expect(const SelectionEngine().itemsInLasso(page, dense), const <String>{
      'inside',
    });
  });

  test('near-limit concave lasso buckets never select duplicate vertices', () {
    final star = List<Vec2>.generate(261, (index) {
      final angle = math.pi * 2 * index / 260;
      final radius = index.isEven ? 100.0 : 62.0;
      return Vec2(
        150 + math.cos(angle) * radius,
        150 + math.sin(angle) * radius,
      );
    }, growable: false);

    final simplified = SelectionEngine.simplifyLasso(star);

    expect(simplified, hasLength(256));
    expect(simplified.toSet(), hasLength(simplified.length));
    expect(simplified.first, same(star.first));
    expect(simplified.last, same(star.last));
  });
}
