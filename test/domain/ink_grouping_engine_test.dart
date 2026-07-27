import 'package:flutter_test/flutter_test.dart';
import 'package:flowboard_x/src/domain/domain.dart';

void main() {
  InkStroke verticalStroke(String id, double x, {double y = 0, int time = 0}) =>
      InkStroke(
        id: id,
        points: [
          InkPoint(x: x, y: y, timestampMicros: time),
          InkPoint(x: x + 5, y: y + 20, timestampMicros: time + 1000),
        ],
        createdAt: DateTime.utc(2026),
      );

  test('builds deterministic letter, word and line candidates', () {
    final strokes = [
      verticalStroke('a', 0, time: 1000),
      verticalStroke('b', 20, time: 2000),
      verticalStroke('c', 80, time: 3000),
      verticalStroke('d', 100, time: 4000),
    ];
    final page = BoardPage(id: 'page', name: 'Page', strokes: strokes);
    final engine = InkGroupingEngine();

    final first = engine.regroupAll(page);
    final second = engine.regroupAll(page);

    expect(
      first.groups.where((group) => group.kind == InkGroupKind.letter),
      hasLength(4),
    );
    expect(
      first.groups.where((group) => group.kind == InkGroupKind.word),
      hasLength(2),
    );
    expect(
      first.groups.where((group) => group.kind == InkGroupKind.line),
      hasLength(1),
    );
    expect(
      first.groups.map((group) => group.id),
      second.groups.map((group) => group.id),
    );

    final candidates = engine.selectionCandidatesAt(
      page.copyWith(groups: first.groups),
      const Vec2(2, 10),
    );
    expect(candidates.map((group) => group.kind), [
      InkGroupKind.letter,
      InkGroupKind.word,
      InkGroupKind.line,
    ]);
  });

  test('incremental regrouping preserves distant sketch and manual groups', () {
    final nearby = verticalStroke('near', 0);
    final sketch = InkStroke(
      id: 'sketch',
      points: const [InkPoint(x: 1000, y: 100), InkPoint(x: 1300, y: 200)],
      createdAt: DateTime.utc(2026),
    );
    final engine = InkGroupingEngine();
    var page = BoardPage(id: 'page', name: 'Page', strokes: [nearby, sketch]);
    final initial = engine.regroupAll(page);
    final sketchGroup = initial.groups.singleWhere(
      (group) => group.kind == InkGroupKind.sketch,
    );
    final manual = InkGroup(
      id: 'manual',
      kind: InkGroupKind.manual,
      strokeIds: const ['sketch'],
      bounds: sketch.bounds,
    );
    page = page.copyWith(groups: [...initial.groups, manual]);

    final result = engine.regroupIncrementally(
      page: page,
      changedStrokeIds: const ['near'],
    );

    expect(result.groups.any((group) => group.id == sketchGroup.id), isTrue);
    expect(result.groups.any((group) => group.id == 'manual'), isTrue);
    expect(result.affectedRegion.right, lessThan(sketch.bounds.left));
  });

  test('spatial index updates moved and removed strokes', () {
    final index = InkSpatialIndex(cellSize: 100);
    final original = verticalStroke('s', 0);
    index.synchronize([original]);
    expect(
      index.query(const Rect2(left: -10, top: -10, width: 50, height: 50)),
      hasLength(1),
    );

    final moved = original.transformed(const TransformDelta(dx: 500));
    index.synchronize([moved]);
    expect(
      index.query(const Rect2(left: -10, top: -10, width: 50, height: 50)),
      isEmpty,
    );
    expect(
      index.query(const Rect2(left: 490, top: -10, width: 50, height: 50)),
      hasLength(1),
    );

    index.synchronize(const []);
    expect(index.length, 0);
  });

  test('consecutive stroke appends retain the indexed snapshot', () {
    final engine = InkGroupingEngine();
    var page = BoardPage(id: 'append-page', name: 'Page');
    engine.regroupAll(page);

    for (var index = 0; index < 12; index++) {
      final stroke = verticalStroke(
        'append-$index',
        index * 18,
        time: index * 2000,
      );
      final before = page;
      final withStroke = page.copyWith(
        strokes: <InkStroke>[...page.strokes, stroke],
      );
      final result = engine.regroupIncrementally(
        page: withStroke,
        changedStrokeIds: <String>[stroke.id],
        dirtyRegion: stroke.bounds,
        pageBeforeAppend: before,
        appendedStroke: stroke,
      );
      page = withStroke.copyWith(groups: result.groups);
      expect(page.strokes, same(withStroke.strokes));
    }

    final complete = InkGroupingEngine().regroupAll(page);
    expect(
      page.groups.map((group) => group.id).toSet(),
      complete.groups.map((group) => group.id).toSet(),
    );
  });

  test('spatial indexes retain only recently visited pages', () {
    final engine = InkGroupingEngine(
      config: const InkGroupingConfig(maxCachedPages: 3),
    );

    for (var index = 0; index < 20; index++) {
      engine.regroupAll(
        BoardPage(
          id: 'page-$index',
          name: 'Page $index',
          strokes: <InkStroke>[
            verticalStroke('stroke-$index', index.toDouble()),
          ],
        ),
      );
    }

    expect(engine.cachedPageCount, 3);
  });
}
