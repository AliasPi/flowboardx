import 'dart:math' as math;

import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/selection/selection_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'selection member lookup preserves sparse source indices and groups',
    () {
      final page = BoardPage(
        id: 'resolved-members',
        name: 'Resolved members',
        strokes: <InkStroke>[
          InkStroke(
            id: 's0',
            points: const <InkPoint>[
              InkPoint(x: 0, y: 0),
              InkPoint(x: 10, y: 10),
            ],
          ),
          InkStroke(
            id: 's1',
            points: const <InkPoint>[
              InkPoint(x: 20, y: 20),
              InkPoint(x: 30, y: 30),
            ],
          ),
        ],
        objects: <BoardObject>[
          ShapeObject(
            id: 'o0',
            transform: const ObjectTransform(
              x: 40,
              y: 40,
              width: 20,
              height: 20,
            ),
          ),
        ],
        contentGroups: <ContentGroup>[
          ContentGroup(
            id: 'content',
            memberIds: <String>['s1', 'o0'],
            bounds: Rect2(left: 20, top: 20, width: 40, height: 40),
          ),
        ],
      );

      final resolved = SelectionEngine().resolveSelectionMembers(
        page,
        const <String>{'content'},
      );

      expect(resolved.expandedIds, const <String>{'s1', 'o0'});
      expect(resolved.objectIndices, const <int>[0]);
      expect(resolved.objects.single.id, 'o0');
      expect(resolved.strokeIndices, const <int>[1]);
      expect(resolved.strokes.single.id, 's1');
      expect(resolved.selectedContentGroup?.id, 'content');
      expect(
        resolved.bounds,
        const Rect2(left: 20, top: 20, width: 40, height: 40),
      );
    },
  );

  test('passive object selection does not index a dense stroke page', () {
    final diagnostics = SelectionEngineDiagnostics();
    final page = BoardPage(
      id: 'passive-object',
      name: 'Passive object',
      strokes: <InkStroke>[
        for (var index = 0; index < 12000; index++)
          InkStroke(
            id: 'passive-stroke-$index',
            points: <InkPoint>[
              InkPoint(x: index.toDouble(), y: 0),
              InkPoint(x: index.toDouble() + 1, y: 1),
            ],
          ),
      ],
      objects: <BoardObject>[
        ShapeObject(
          id: 'selected-object',
          transform: const ObjectTransform(
            x: 100,
            y: 100,
            width: 80,
            height: 50,
          ),
        ),
      ],
    );

    final engine = SelectionEngine(diagnostics: diagnostics);
    expect(
      engine.retainExistingIds(page, const <String>{'selected-object'}),
      const <String>{'selected-object'},
    );
    final resolved = engine.resolveSelectionMembers(page, const <String>{
      'selected-object',
    });

    expect(resolved.objects.single.id, 'selected-object');
    expect(diagnostics.strokeFullIndexBuilds, 0);
  });

  test('passive stroke selection advances the append index incrementally', () {
    final diagnostics = SelectionEngineDiagnostics();
    final engine = SelectionEngine(diagnostics: diagnostics);
    var page = BoardPage(
      id: 'passive-stroke',
      name: 'Passive stroke',
      strokes: <InkStroke>[
        for (var index = 0; index < 8000; index++)
          InkStroke(
            id: 'base-$index',
            points: <InkPoint>[
              InkPoint(x: index.toDouble(), y: 0),
              InkPoint(x: index.toDouble() + 1, y: 1),
            ],
          ),
      ],
    );
    const selection = <String>{'base-4000'};

    expect(
      engine.resolveSelectionMembers(page, selection).strokes.single.id,
      'base-4000',
    );
    for (var index = 0; index < 80; index++) {
      page = page.appendTopLevelStroke(
        InkStroke(
          id: 'append-$index',
          points: <InkPoint>[
            InkPoint(x: index.toDouble(), y: 100),
            InkPoint(x: index.toDouble() + 1, y: 101),
          ],
        ),
      );
      expect(
        engine.resolveSelectionMembers(page, selection).strokes.single.id,
        'base-4000',
      );
    }

    expect(diagnostics.strokeFullIndexBuilds, 1);
    expect(diagnostics.strokeIncrementalIndexUpdates, 80);
  });

  test(
    'session caches stay bounded across many visited pages and can clear',
    () {
      final engine = SelectionEngine(maximumCachedSnapshots: 2);

      for (var index = 0; index < 20; index++) {
        final stroke = InkStroke(
          id: 'cached-stroke-$index',
          points: <InkPoint>[
            InkPoint(x: index * 20, y: 10),
            InkPoint(x: index * 20 + 5, y: 15),
          ],
        );
        final object = ShapeObject(
          id: 'cached-object-$index',
          transform: ObjectTransform(
            x: index * 20,
            y: 30,
            width: 10,
            height: 10,
          ),
        );
        final page = BoardPage(
          id: 'cached-page-$index',
          name: 'Cache $index',
          strokes: <InkStroke>[stroke],
          objects: <BoardObject>[object],
          groups: <InkGroup>[
            InkGroup(
              id: 'cached-ink-group-$index',
              kind: InkGroupKind.letter,
              strokeIds: <String>[stroke.id],
              bounds: stroke.bounds,
            ),
          ],
          contentGroups: <ContentGroup>[
            ContentGroup(
              id: 'cached-content-group-$index',
              memberIds: <String>[stroke.id, object.id],
              bounds: stroke.bounds.union(object.transform.bounds),
            ),
          ],
        );

        expect(engine.retainExistingIds(page, <String>{stroke.id}), <String>{
          stroke.id,
        });
        expect(engine.cachedStrokeSnapshotCount, lessThanOrEqualTo(2));
        expect(engine.cachedObjectSnapshotCount, lessThanOrEqualTo(2));
        expect(engine.cachedContentGroupSnapshotCount, lessThanOrEqualTo(2));
        expect(engine.cachedInkGroupSnapshotCount, lessThanOrEqualTo(2));
      }

      engine.clearCaches();
      expect(engine.cachedStrokeSnapshotCount, 0);
      expect(engine.cachedObjectSnapshotCount, 0);
      expect(engine.cachedContentGroupSnapshotCount, 0);
      expect(engine.cachedInkGroupSnapshotCount, 0);
    },
  );

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
    final selected = SelectionEngine().itemsInRectangle(
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
    final candidates = SelectionEngine().candidatesAt(page, const Vec2(10, 0));
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

    final candidates = SelectionEngine().candidatesAt(page, const Vec2(25, 25));
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

    final candidates = SelectionEngine().candidatesAt(
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

    final candidates = SelectionEngine().candidatesAt(
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
      final engine = SelectionEngine();

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
    expect(SelectionEngine().itemsInLasso(page, dense), const <String>{
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

  test('dense pages only inspect spatially local tap candidates', () {
    final strokes =
        List<InkStroke>.generate(8000, (index) {
          final x = 1000.0 + (index % 100) * 320;
          final y = 1000.0 + (index ~/ 100) * 320;
          return InkStroke(
            id: 'far-$index',
            points: <InkPoint>[
              InkPoint(x: x, y: y),
              InkPoint(x: x + 40, y: y + 20),
            ],
            zIndex: index,
          );
        })..add(
          InkStroke(
            id: 'local',
            points: const <InkPoint>[
              InkPoint(x: 10, y: 10),
              InkPoint(x: 40, y: 10),
            ],
            zIndex: 8000,
          ),
        );
    final page = BoardPage(id: 'dense-local', name: 'Dense', strokes: strokes);
    final diagnostics = SelectionEngineDiagnostics();
    final engine = SelectionEngine(diagnostics: diagnostics);

    final candidates = engine.candidatesAt(page, const Vec2(25, 10));

    expect(candidates.map((candidate) => candidate.id), <String>['local']);
    expect(diagnostics.lastSpatialCandidateCount, lessThanOrEqualTo(2));
  });

  test('rectangle and lasso queries stay local on content-heavy pages', () {
    final objects =
        List<BoardObject>.generate(
          5000,
          (index) => ShapeObject(
            id: 'far-object-$index',
            transform: ObjectTransform(
              x: 2000.0 + (index % 100) * 240,
              y: 2000.0 + (index ~/ 100) * 240,
              width: 40,
              height: 40,
            ),
            zIndex: index,
          ),
        )..add(
          ShapeObject(
            id: 'local-object',
            transform: const ObjectTransform(
              x: 20,
              y: 20,
              width: 30,
              height: 30,
            ),
            zIndex: 5000,
          ),
        );
    final page = BoardPage(
      id: 'dense-region',
      name: 'Dense region',
      objects: objects,
    );
    final diagnostics = SelectionEngineDiagnostics();
    final engine = SelectionEngine(diagnostics: diagnostics);

    expect(
      engine.itemsInRectangle(
        page,
        const Rect2(left: 0, top: 0, width: 80, height: 80),
      ),
      <String>{'local-object'},
    );
    expect(diagnostics.lastSpatialCandidateCount, lessThanOrEqualTo(2));
    expect(
      engine.itemsInLasso(page, const <Vec2>[
        Vec2(0, 0),
        Vec2(80, 0),
        Vec2(80, 80),
        Vec2(0, 80),
      ]),
      <String>{'local-object'},
    );
    expect(diagnostics.lastSpatialCandidateCount, lessThanOrEqualTo(2));
  });

  test('normal immutable stroke appends extend the cached selection index', () {
    var page = BoardPage(
      id: 'append-index',
      name: 'Append',
      strokes: List<InkStroke>.generate(
        2048,
        (index) => InkStroke(
          id: 'base-$index',
          points: <InkPoint>[
            InkPoint(x: 1000.0 + index * 4, y: 1000),
            InkPoint(x: 1002.0 + index * 4, y: 1002),
          ],
          zIndex: index,
        ),
      ),
    );
    page = page.appendTopLevelStroke(
      InkStroke(
        id: 'warm',
        points: const <InkPoint>[
          InkPoint(x: 10, y: 10),
          InkPoint(x: 20, y: 10),
        ],
        zIndex: 2048,
      ),
    );
    final diagnostics = SelectionEngineDiagnostics();
    final engine = SelectionEngine(diagnostics: diagnostics);
    expect(engine.hasSelectableAt(page, const Vec2(15, 10)), isTrue);

    final next = page.appendTopLevelStroke(
      InkStroke(
        id: 'appended',
        points: const <InkPoint>[
          InkPoint(x: 30, y: 30),
          InkPoint(x: 50, y: 30),
        ],
        zIndex: 2049,
      ),
    );
    expect(engine.hasSelectableAt(next, const Vec2(40, 30)), isTrue);

    expect(diagnostics.strokeFullIndexBuilds, 1);
    expect(diagnostics.strokeIncrementalIndexUpdates, 1);
  });

  test('spatial tap preserves exact legacy mixed-scene z order', () {
    final page = BoardPage(
      id: 'legacy-z',
      name: 'Legacy',
      objects: <BoardObject>[
        ShapeObject(
          id: 'object-high',
          transform: const ObjectTransform(x: 0, y: 0, width: 60, height: 60),
          zIndex: 9,
        ),
        ShapeObject(
          id: 'object-low',
          transform: const ObjectTransform(x: 0, y: 0, width: 60, height: 60),
          zIndex: 1,
        ),
      ],
      strokes: <InkStroke>[
        InkStroke(
          id: 'stroke-middle',
          points: const <InkPoint>[
            InkPoint(x: 0, y: 30),
            InkPoint(x: 60, y: 30),
          ],
          zIndex: 5,
        ),
        InkStroke(
          id: 'stroke-top',
          points: const <InkPoint>[
            InkPoint(x: 0, y: 30),
            InkPoint(x: 60, y: 30),
          ],
          zIndex: 12,
        ),
      ],
    );

    final candidates = SelectionEngine().candidatesAt(page, const Vec2(30, 30));

    expect(candidates.map((candidate) => candidate.id), <String>[
      'stroke-top',
      'object-high',
      'stroke-middle',
      'object-low',
    ]);
  });

  test('empty-board occupancy respects persistent group lock semantics', () {
    final first = ShapeObject(
      id: 'first-locked-member',
      transform: const ObjectTransform(x: 10, y: 10, width: 20, height: 20),
    );
    final second = ShapeObject(
      id: 'second-locked-member',
      transform: const ObjectTransform(x: 80, y: 10, width: 20, height: 20),
    );
    BoardPage grouped({required bool locked}) => BoardPage(
      id: 'locked-$locked',
      name: 'Grouped',
      objects: <BoardObject>[first, second],
      contentGroups: <ContentGroup>[
        ContentGroup(
          id: 'persistent',
          memberIds: const <String>[
            'first-locked-member',
            'second-locked-member',
          ],
          bounds: const Rect2(left: 10, top: 10, width: 90, height: 20),
          locked: locked,
        ),
      ],
    );

    final engine = SelectionEngine();
    // The point is in the group's empty middle, matching candidatesAt.
    expect(
      engine.hasSelectableAt(grouped(locked: false), const Vec2(55, 20)),
      isTrue,
    );
    expect(
      engine.hasSelectableAt(grouped(locked: true), const Vec2(55, 20)),
      isFalse,
    );
  });

  test('selection ID retention stays incremental on dense pages', () {
    var page = BoardPage(
      id: 'selection-retention',
      name: 'Selection retention',
      strokes: List<InkStroke>.generate(
        8000,
        (index) => InkStroke(
          id: 'stroke-$index',
          points: <InkPoint>[
            InkPoint(x: index * 3.0, y: 40),
            InkPoint(x: index * 3.0 + 2, y: 42),
          ],
          zIndex: index,
        ),
      ),
      objects: <BoardObject>[
        ShapeObject(
          id: 'object',
          transform: const ObjectTransform(x: 10, y: 80, width: 40, height: 40),
          zIndex: 8000,
        ),
      ],
      groups: <InkGroup>[
        InkGroup(
          id: 'ink-group',
          kind: InkGroupKind.word,
          strokeIds: const <String>['stroke-4'],
          bounds: const Rect2(left: 12, top: 38, width: 4, height: 6),
        ),
      ],
      contentGroups: <ContentGroup>[
        ContentGroup(
          id: 'content-group',
          memberIds: const <String>['object', 'stroke-2'],
          bounds: const Rect2(left: 6, top: 38, width: 44, height: 82),
        ),
      ],
    );
    final diagnostics = SelectionEngineDiagnostics();
    final engine = SelectionEngine(diagnostics: diagnostics);

    expect(
      engine.retainExistingIds(page, const <String>{
        'stroke-7999',
        'object',
        'ink-group',
        'content-group',
        'missing',
      }),
      const <String>{'stroke-7999', 'object', 'ink-group', 'content-group'},
    );

    page = page.appendTopLevelStroke(
      InkStroke(
        id: 'latest',
        points: const <InkPoint>[
          InkPoint(x: 20, y: 160),
          InkPoint(x: 40, y: 160),
        ],
        zIndex: 8001,
      ),
    );
    expect(
      engine.retainExistingIds(page, const <String>{'latest', 'stroke-7999'}),
      const <String>{'latest', 'stroke-7999'},
    );
    expect(diagnostics.strokeFullIndexBuilds, 1);
    expect(diagnostics.strokeIncrementalIndexUpdates, 1);
  });
}
