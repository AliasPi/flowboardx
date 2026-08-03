import 'dart:math' as math;

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

  test(
    'large circular stroke indexes its perimeter, not its AABB interior',
    () {
      const center = Vec2(1000, 1000);
      const radius = 720.0;
      const pointCount = 192;
      final circle = InkStroke(
        id: 'large-circle',
        width: 8,
        points: <InkPoint>[
          for (var index = 0; index <= pointCount; index++)
            InkPoint(
              x: center.x + math.cos(index * math.pi * 2 / pointCount) * radius,
              y: center.y + math.sin(index * math.pi * 2 / pointCount) * radius,
            ),
        ],
        createdAt: DateTime.utc(2026),
      );
      final index = InkSpatialIndex(cellSize: 80)..upsert(circle);

      expect(
        index.query(const Rect2(left: 960, top: 960, width: 80, height: 80)),
        isEmpty,
        reason: 'the empty center of a circle must not be indexed as ink',
      );
      expect(
        index.query(const Rect2(left: 1690, top: 960, width: 80, height: 80)),
        contains(same(circle)),
      );
    },
  );

  test('nearest spatial query is hard bounded and retains changed ink', () {
    final index = InkSpatialIndex(cellSize: 100);
    final strokes = <InkStroke>[
      for (var value = 0; value < 80; value++)
        verticalStroke('near-$value', value.toDouble(), y: value.toDouble()),
      verticalStroke('changed', 900, y: 900),
    ];
    index.synchronize(strokes);

    final nearest = index.queryNearest(
      const Rect2(left: -20, top: -20, width: 1000, height: 1000),
      center: const Vec2(0, 0),
      limit: 12,
      priorityStrokeIds: const <String>{'changed'},
    );

    expect(nearest, hasLength(12));
    expect(nearest.first.id, 'changed');
    expect(
      nearest.skip(1).map((stroke) => stroke.id),
      containsAll(<String>['near-0', 'near-1', 'near-2']),
    );
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

  test('incremental grouping linearly merges canonical distant groups', () {
    final engine = InkGroupingEngine();
    final nearby = verticalStroke('nearby', 0);
    final distantGroups = List<InkGroup>.generate(
      400,
      (index) => InkGroup(
        id: 'manual-${(399 - index).toString().padLeft(3, '0')}',
        kind: InkGroupKind.manual,
        strokeIds: const <String>['nearby'],
        bounds: Rect2(
          left: 5000 + index * 20,
          top: 5000,
          width: 10,
          height: 10,
        ),
      ),
      growable: false,
    );
    final page = BoardPage(
      id: 'many-groups',
      name: 'Page',
      strokes: <InkStroke>[nearby],
      // Recovered documents may not yet use canonical group order.
      groups: distantGroups,
    );

    final first = engine.regroupIncrementally(
      page: page,
      changedStrokeIds: const <String>['nearby'],
      dirtyRegion: nearby.bounds,
    );
    final manualIds = first.groups
        .where((group) => group.kind == InkGroupKind.manual)
        .map((group) => group.id)
        .toList(growable: false);
    expect(manualIds, orderedEquals(manualIds.toList()..sort()));

    final nextStroke = verticalStroke('next', 30);
    final withNext = page.copyWith(
      strokes: <InkStroke>[nearby, nextStroke],
      groups: first.groups,
    );
    final second = engine.regroupIncrementally(
      page: withNext,
      changedStrokeIds: const <String>['next'],
      dirtyRegion: nextStroke.bounds,
      pageBeforeAppend: page.copyWith(groups: first.groups),
      appendedStroke: nextStroke,
    );

    final firstManualById = <String, InkGroup>{
      for (final group in first.groups)
        if (group.kind == InkGroupKind.manual) group.id: group,
    };
    for (final group in second.groups.where(
      (group) => group.kind == InkGroupKind.manual,
    )) {
      expect(group, same(firstManualById[group.id]));
    }
  });

  test('6000-group append path never rebuilds the persistent group index', () {
    final engine = InkGroupingEngine(
      config: const InkGroupingConfig(
        analysisMargin: 120,
        spatialCellSize: 100,
      ),
    );
    final seed = verticalStroke('seed', 0);
    final manualGroups = List<InkGroup>.generate(
      6000,
      (index) => InkGroup(
        id: 'manual-${(5999 - index).toString().padLeft(4, '0')}',
        kind: InkGroupKind.manual,
        strokeIds: const <String>['seed'],
        bounds: Rect2(
          left: 10000 + (index % 100) * 30,
          top: 10000 + (index ~/ 100) * 30,
          width: 12,
          height: 12,
        ),
      ),
      growable: false,
    );
    var page = BoardPage(
      id: 'large-group-page',
      name: 'Large',
      strokes: <InkStroke>[seed],
      groups: manualGroups,
    );
    final first = engine.regroupIncrementally(
      page: page,
      changedStrokeIds: const <String>['seed'],
      dirtyRegion: seed.bounds,
    );
    page = page.copyWith(groups: first.groups);
    final rebuilds = engine.debugGroupIndexRebuildCount;

    for (var index = 0; index < 40; index++) {
      final stroke = verticalStroke(
        'local-$index',
        18 + index * 3,
        time: 10000 + index * 2000,
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

      expect(
        page.groups,
        same(result.groups),
        reason:
            'BoardPage must retain the exact persistent group revision so '
            'the next synchronize call takes its O(1) identity fast path',
      );
      expect(engine.debugGroupIndexRebuildCount, rebuilds);
      expect(
        engine.debugLastGroupCandidateCount,
        lessThan(32),
        reason: 'distant groups must not be visited after every pen-up',
      );
    }

    expect(
      page.groups.where((group) => group.kind == InkGroupKind.manual),
      hasLength(6000),
    );
    final actual = page.groups.toList(growable: false);
    final expected = List<InkGroup>.of(actual)
      ..sort((a, b) {
        final kind = a.kind.index.compareTo(b.kind.index);
        return kind != 0 ? kind : a.id.compareTo(b.id);
      });
    expect(
      actual.map((group) => group.id),
      orderedEquals(expected.map((group) => group.id)),
    );
  });

  test('temporally distant dense ink does not trigger quadratic grouping', () {
    const strokeCount = 256;
    final strokes = List<InkStroke>.generate(
      strokeCount,
      (index) => verticalStroke(
        'historic-$index',
        (index % 8) * 4,
        y: (index % 8) * 3,
        time: index * const Duration(seconds: 20).inMicroseconds,
      ),
      growable: false,
    );
    final engine = InkGroupingEngine();

    final result = engine.regroupAll(
      BoardPage(id: 'dense-history', name: 'Dense', strokes: strokes),
    );

    expect(
      result.groups.where((group) => group.kind == InkGroupKind.letter),
      hasLength(strokeCount),
    );
    expect(
      engine.debugGlyphPairComparisonCount,
      0,
      reason: 'the temporal window must stop before spatial glyph checks',
    );
    expect(
      engine.debugTokenPairComparisonCount,
      0,
      reason: 'word and line clustering must use the same bounded window',
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
