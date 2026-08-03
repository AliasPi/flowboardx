import 'dart:collection';
import 'dart:typed_data';

import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/domain/model/scene_order.dart';
import 'package:flowboard_x/src/features/board/presentation/board_object_layer.dart';
import 'package:flowboard_x/src/features/board/presentation/board_scene_layer.dart';
import 'package:flowboard_x/src/features/board/presentation/ink_picture_cache.dart';
import 'package:flowboard_x/src/features/board/presentation/persisted_ink_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'document append provenance accepts only the direct immutable parent',
    () {
      final base = BoardPage.empty(id: 'append-provenance');
      final first = base.appendTopLevelStroke(_stroke(0));
      final second = first.appendTopLevelStroke(_stroke(1));
      final sibling = first.appendTopLevelStroke(
        _stroke(2).copyWith(id: 'sibling'),
      );
      final siblingChild = sibling.appendTopLevelStroke(
        _stroke(3).copyWith(id: 'sibling-child'),
      );

      final secondAppend = second.strokes as SingleAppendSceneList<InkStroke>;
      final siblingChildAppend =
          siblingChild.strokes as SingleAppendSceneList<InkStroke>;
      expect(secondAppend.isSingleAppendOf(first.strokes), isTrue);
      expect(siblingChildAppend.isSingleAppendOf(sibling.strokes), isTrue);
      expect(
        siblingChildAppend.isSingleAppendOf(second.strokes),
        isFalse,
        reason: 'equal lengths from a different undo branch are not ancestry',
      );
    },
  );

  testWidgets('keeps persisted vector pictures when a stroke is appended', (
    tester,
  ) async {
    final initial = List<InkStroke>.unmodifiable(
      List<InkStroke>.generate(12, _stroke),
    );

    await _pumpScene(tester, initial);
    final before = _persistedPainter(tester, 0);
    final pictureBefore = before.cache.batchPicturesFor(initial).first;

    final appended = List<InkStroke>.unmodifiable(<InkStroke>[
      ...initial,
      _stroke(initial.length),
    ]);
    await _pumpScene(tester, appended);
    final after = _persistedPainter(tester, 0);

    expect(after.cache, same(before.cache));
    expect(after.cache.batchPicturesFor(appended).first, same(pictureBefore));
  });

  testWidgets(
    'persisted ink uses bounded pictures and rerecords one sparse batch',
    (tester) async {
      final initial = List<InkStroke>.unmodifiable(
        List<InkStroke>.generate(40, _stroke),
      );
      await _pumpScene(tester, initial);
      final before = _persistedPainter(tester, 0);

      expect(before.cache.entryCount, 0);
      expect(before.cache.batchPictureCount, 5);
      expect(
        before.cache.batchPictureCount,
        lessThan(initial.length),
        reason:
            'persisted rendering must not retain one native Picture and issue '
            'one drawPicture call for every historical stroke',
      );
      final createCount = before.cache.batchPictureCreateCount;
      final disposeCount = before.cache.batchPictureDisposeCount;

      final changed = initial[17].transformed(
        const TransformDelta(dx: 1, dy: 1),
      );
      final updated = List<InkStroke>.of(initial, growable: false);
      updated[17] = changed;
      await _pumpScene(tester, List<InkStroke>.unmodifiable(updated));
      final after = _persistedPainter(tester, 0);

      expect(after.cache, same(before.cache));
      expect(after.cache.batchPictureCount, 5);
      expect(after.cache.batchPictureCreateCount, createCount + 1);
      expect(after.cache.batchPictureDisposeCount, disposeCount + 1);
      expect(
        after.cache.lastBatchRecordedStrokeCount,
        lessThanOrEqualTo(InkPictureCache.maximumBatchStrokes),
        reason:
            'a live sparse transform may rerecord only its small containing '
            'batch, never every stroke already visible on the page',
      );
    },
  );

  testWidgets('selected markers remain batched and are never drawn twice', (
    tester,
  ) async {
    final mutable = List<InkStroke>.generate(40, _stroke);
    mutable[3] = mutable[3].copyWith(type: InkToolType.marker);
    mutable[31] = mutable[31].copyWith(type: InkToolType.marker);
    final strokes = List<InkStroke>.unmodifiable(mutable);
    await _pumpScene(tester, strokes, selectionIds: <String>{strokes[3].id});
    final before = _persistedPainter(tester, 0);
    expect(
      before.cache.entryCount,
      0,
      reason:
          'selection must add only a halo, not a second translucent marker '
          'picture over the batched base ink',
    );

    await _pumpScene(tester, strokes, selectionIds: <String>{strokes[31].id});
    final changed = _persistedPainter(tester, 0);
    expect(changed.cache, same(before.cache));
    expect(changed.cache.entryCount, 0);

    await _pumpScene(tester, strokes);
    expect(_persistedPainter(tester, 0).cache.entryCount, 0);
  });

  testWidgets(
    'proven immutable append never scans the retained stroke prefix',
    (tester) async {
      final source = _CountingStrokeList(
        List<InkStroke>.generate(4000, _stroke, growable: false),
      );
      await _pumpScene(tester, source);
      source.readCount = 0;
      final appended = _TestSingleAppendStrokeList(source, _stroke(4000));

      await _pumpScene(tester, appended);

      expect(
        source.readCount,
        0,
        reason:
            'immutable append ancestry proves the complete prefix without an '
            'O(stroke count) identity scan on every pen-up',
      );
      expect(
        appended.readCount,
        lessThanOrEqualTo(1),
        reason: 'only the newly appended final stroke needs to be inspected',
      );
    },
  );

  testWidgets('topmost append retains every completed scene run', (
    tester,
  ) async {
    final initial = List<InkStroke>.unmodifiable(
      List<InkStroke>.generate(60, _stroke),
    );
    await _pumpScene(tester, initial);
    final before = tester
        .widgetList<PersistedInkLayer>(find.byType(PersistedInkLayer))
        .toList(growable: false);
    expect(before, hasLength(2));
    final completedRun = before.first.strokes;
    final growingRun = before.last.strokes;

    final appended = List<InkStroke>.unmodifiable(<InkStroke>[
      ...initial,
      _stroke(initial.length),
    ]);
    await _pumpScene(tester, appended);
    final after = tester
        .widgetList<PersistedInkLayer>(find.byType(PersistedInkLayer))
        .toList(growable: false);

    expect(after, hasLength(2));
    expect(
      after.first.strokes,
      same(completedRun),
      reason: 'a topmost append must not rebuild completed scene batches',
    );
    expect(after.last.strokes, isNot(same(growingRun)));
    expect(after.last.strokes.last, same(appended.last));
  });

  testWidgets('live transform refreshes only its affected scene run', (
    tester,
  ) async {
    final initial = List<InkStroke>.unmodifiable(
      List<InkStroke>.generate(60, _stroke),
    );
    await _pumpScene(tester, initial);
    final before = tester
        .widgetList<PersistedInkLayer>(find.byType(PersistedInkLayer))
        .toList(growable: false);
    expect(before, hasLength(2));
    final completedRun = before.first.strokes;
    final completedPainter = _persistedPainter(tester, 0);
    final completedPicture = completedPainter.cache.pictureFor(initial.first);

    final transformed = initial.last.transformed(
      const TransformDelta(dx: 12, dy: 8),
    );
    final updated = List<InkStroke>.unmodifiable(<InkStroke>[
      ...initial.take(initial.length - 1),
      transformed,
    ]);
    await _pumpScene(tester, updated);

    final after = tester
        .widgetList<PersistedInkLayer>(find.byType(PersistedInkLayer))
        .toList(growable: false);
    expect(after, hasLength(2));
    expect(
      after.first.strokes,
      same(completedRun),
      reason: 'an unchanged run must not be repartitioned during a drag frame',
    );
    final completedPainterAfter = _persistedPainter(tester, 0);
    expect(completedPainterAfter.cache, same(completedPainter.cache));
    expect(
      completedPainterAfter.cache.pictureFor(initial.first),
      same(completedPicture),
    );
    expect(after.last.strokes.last, same(transformed));
  });

  testWidgets('sparse live transform does not scan a large source page', (
    tester,
  ) async {
    final source = _CountingStrokeList(
      List<InkStroke>.generate(4000, _stroke, growable: false),
    );
    await _pumpScene(tester, source);
    source.readCount = 0;

    const selectedIndex = 2777;
    final transformed = source.values[selectedIndex].transformed(
      const TransformDelta(dx: 18, dy: 9),
    );
    await _pumpScene(
      tester,
      _TestSparseStrokeOverlay(source, <int, InkStroke>{
        selectedIndex: transformed,
      }),
    );

    expect(
      source.readCount,
      lessThan(10),
      reason:
          'a fixed sparse preview must update its cached scene run directly',
    );
    final layers = tester
        .widgetList<PersistedInkLayer>(find.byType(PersistedInkLayer))
        .toList(growable: false);
    expect(
      layers
          .expand((layer) => layer.strokes)
          .singleWhere((stroke) => stroke.id == transformed.id),
      same(transformed),
    );
  });

  testWidgets('bounds fullscreen ink layers with stable batches', (
    tester,
  ) async {
    final strokes = List<InkStroke>.unmodifiable(
      List<InkStroke>.generate(97, _stroke),
    );

    await _pumpScene(tester, strokes);

    expect(find.byType(PersistedInkLayer), findsNWidgets(3));
    final firstPaint = find.descendant(
      of: find.byType(PersistedInkLayer).first,
      matching: find.byType(CustomPaint),
    );
    expect(tester.getSize(firstPaint).height, lessThan(40));
    expect(tester.getSize(firstPaint).width, lessThan(130));
  });

  testWidgets('clips oversized ink without retaining a giant repaint layer', (
    tester,
  ) async {
    final oversized = InkStroke(
      id: 'oversized-circle-like-stroke',
      points: const <InkPoint>[
        InkPoint(x: -5000000, y: -5000000),
        InkPoint(x: 5000000, y: 5000000),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: BoardSceneLayer(
            objects: const [],
            strokes: <InkStroke>[oversized],
            annotationLayers: const [],
            scale: 1,
            offset: Offset.zero,
            worldClip: const Rect2(left: 0, top: 0, width: 800, height: 600),
            assets: const _NoAssets(),
          ),
        ),
      ),
    );

    final layer = tester.widget<PersistedInkLayer>(
      find.byType(PersistedInkLayer),
    );
    final paint = find.descendant(
      of: find.byType(PersistedInkLayer),
      matching: find.byType(CustomPaint),
    );
    expect(layer.isolateRepaints, isFalse);
    expect(tester.getSize(paint).width, lessThanOrEqualTo(816));
    expect(tester.getSize(paint).height, lessThanOrEqualTo(616));
  });

  testWidgets('does not build a persisted layer for an offscreen ink run', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: BoardSceneLayer(
            objects: const [],
            strokes: <InkStroke>[_stroke(0)],
            annotationLayers: const [],
            scale: 1,
            offset: Offset.zero,
            worldClip: const Rect2(
              left: 1000,
              top: 1000,
              width: 200,
              height: 200,
            ),
            assets: const _NoAssets(),
          ),
        ),
      ),
    );

    expect(find.byType(PersistedInkLayer), findsNothing);
  });

  testWidgets('distant strokes never create one oversized repaint layer', (
    tester,
  ) async {
    final strokes = <InkStroke>[
      _stroke(0),
      InkStroke(
        id: 'distant',
        points: const <InkPoint>[
          InkPoint(x: 6000, y: 10),
          InkPoint(x: 6001, y: 11),
        ],
      ),
    ];

    await _pumpScene(tester, strokes);

    expect(find.byType(PersistedInkLayer), findsNWidgets(2));
    for (final layer in find.byType(PersistedInkLayer).evaluate()) {
      expect(tester.getSize(find.byWidget(layer.widget)).width, lessThan(40));
    }
  });

  testWidgets(
    'offscreen indexed runs are not materialized as widget children',
    (tester) async {
      final strokes = <InkStroke>[
        for (var index = 0; index < 300; index++)
          InkStroke(
            id: 'spread-$index',
            points: <InkPoint>[
              InkPoint(x: index * 3000, y: 10),
              InkPoint(x: index * 3000 + 1, y: 11),
            ],
            zIndex: index,
          ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: BoardSceneLayer(
              objects: const [],
              strokes: strokes,
              annotationLayers: const [],
              scale: 1,
              offset: Offset.zero,
              worldClip: const Rect2(
                left: -100,
                top: -100,
                width: 1000,
                height: 800,
              ),
              assets: const _NoAssets(),
            ),
          ),
        ),
      );

      expect(find.byType(PersistedInkLayer), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BoardSceneLayer),
          matching: find.byType(SizedBox),
        ),
        findsNothing,
        reason:
            'the viewport index must omit distant runs instead of building one '
            'placeholder element for each run on every frame',
      );
    },
  );

  testWidgets('offscreen object runs are not materialized on viewport frames', (
    tester,
  ) async {
    final objects = <BoardObject>[
      for (var index = 0; index < 300; index++) _shape(index, x: index * 3000),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: BoardSceneLayer(
            objects: objects,
            strokes: const [],
            annotationLayers: const [],
            scale: 1,
            offset: Offset.zero,
            worldClip: const Rect2(
              left: -100,
              top: -100,
              width: 1000,
              height: 800,
            ),
            assets: const _NoAssets(),
          ),
        ),
      ),
    );

    expect(find.byType(BoardObjectLayer), findsOneWidget);
    final visibleLayer = tester.widget<BoardObjectLayer>(
      find.byType(BoardObjectLayer),
    );
    expect(visibleLayer.objects, hasLength(1));
    expect(visibleLayer.objects.single.id, 'shape-0');
  });

  testWidgets('live object transform refreshes its visibility index', (
    tester,
  ) async {
    final initial = <BoardObject>[_shape(0, x: 5000)];

    await _pumpObjectScene(tester, initial);
    expect(find.byType(BoardObjectLayer), findsNothing);

    final moved = initial.single.copyWithTransform(
      const ObjectTransform(x: 20, y: 20, width: 40, height: 40),
    );
    await _pumpObjectScene(tester, <BoardObject>[moved]);

    expect(find.byType(BoardObjectLayer), findsOneWidget);
    final visibleLayer = tester.widget<BoardObjectLayer>(
      find.byType(BoardObjectLayer),
    );
    expect(visibleLayer.objects.single, same(moved));
  });

  testWidgets('distant object transform re-partitions a retained batch', (
    tester,
  ) async {
    final initial = <BoardObject>[_shape(0, x: 20), _shape(1, x: 80)];

    await _pumpObjectScene(tester, initial);
    expect(find.byType(BoardObjectLayer), findsOneWidget);
    expect(
      tester.widget<BoardObjectLayer>(find.byType(BoardObjectLayer)).objects,
      hasLength(2),
    );

    final moved = initial.last.copyWithTransform(
      const ObjectTransform(x: 5000, y: 10, width: 40, height: 40),
    );
    await _pumpObjectScene(tester, <BoardObject>[initial.first, moved]);

    expect(find.byType(BoardObjectLayer), findsOneWidget);
    final visibleLayer = tester.widget<BoardObjectLayer>(
      find.byType(BoardObjectLayer),
    );
    expect(visibleLayer.objects, <BoardObject>[initial.first]);
  });
}

Future<void> _pumpScene(
  WidgetTester tester,
  List<InkStroke> strokes, {
  Set<String> selectionIds = const <String>{},
}) => tester.pumpWidget(
  MaterialApp(
    home: SizedBox(
      width: 800,
      height: 600,
      child: BoardSceneLayer(
        objects: const [],
        strokes: strokes,
        annotationLayers: const [],
        scale: 1,
        offset: Offset.zero,
        assets: const _NoAssets(),
        selectedIds: selectionIds,
      ),
    ),
  ),
);

Future<void> _pumpObjectScene(WidgetTester tester, List<BoardObject> objects) =>
    tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: BoardSceneLayer(
            objects: objects,
            strokes: const [],
            annotationLayers: const [],
            scale: 1,
            offset: Offset.zero,
            worldClip: const Rect2(
              left: -100,
              top: -100,
              width: 1000,
              height: 800,
            ),
            assets: const _NoAssets(),
          ),
        ),
      ),
    );

PersistedInkPainter _persistedPainter(WidgetTester tester, int index) =>
    tester
            .widgetList<CustomPaint>(
              find.descendant(
                of: find.byType(PersistedInkLayer),
                matching: find.byType(CustomPaint),
              ),
            )
            .elementAt(index)
            .painter!
        as PersistedInkPainter;

InkStroke _stroke(int index) => InkStroke(
  id: 'stroke-$index',
  points: <InkPoint>[
    InkPoint(x: index * 2, y: 10),
    InkPoint(x: index * 2 + 1, y: 11),
  ],
);

ShapeObject _shape(int index, {required double x}) => ShapeObject(
  id: 'shape-$index',
  transform: ObjectTransform(x: x, y: 10, width: 40, height: 40),
  zIndex: index,
);

class _NoAssets implements BoardAssetResolver {
  const _NoAssets();

  @override
  String? localPath(String assetId) => null;

  @override
  Future<Uint8List?> readBytes(String assetId) async => null;
}

final class _CountingStrokeList extends ListBase<InkStroke> {
  _CountingStrokeList(this.values);

  final List<InkStroke> values;
  int readCount = 0;

  @override
  int get length => values.length;

  @override
  set length(int value) => throw UnsupportedError('Test source is immutable.');

  @override
  InkStroke operator [](int index) {
    readCount++;
    return values[index];
  }

  @override
  void operator []=(int index, InkStroke value) =>
      throw UnsupportedError('Test source is immutable.');
}

final class _TestSparseStrokeOverlay extends ListBase<InkStroke>
    implements FixedSceneListOverlay<InkStroke> {
  _TestSparseStrokeOverlay(this.sceneSource, this.sceneReplacements);

  @override
  final List<InkStroke> sceneSource;

  @override
  final Map<int, InkStroke> sceneReplacements;

  @override
  int get length => sceneSource.length;

  @override
  set length(int value) => throw UnsupportedError('Test overlay is immutable.');

  @override
  InkStroke operator [](int index) =>
      sceneReplacements[index] ?? sceneSource[index];

  @override
  void operator []=(int index, InkStroke value) =>
      throw UnsupportedError('Test overlay is immutable.');
}

final class _TestSingleAppendStrokeList extends ListBase<InkStroke>
    implements SingleAppendSceneList<InkStroke> {
  _TestSingleAppendStrokeList(this.source, this.appended);

  final List<InkStroke> source;
  final InkStroke appended;
  int readCount = 0;

  @override
  bool isSingleAppendOf(List<InkStroke> previous) =>
      identical(previous, source);

  @override
  int get length => source.length + 1;

  @override
  set length(int value) => throw UnsupportedError('Test list is immutable.');

  @override
  InkStroke operator [](int index) {
    RangeError.checkValidIndex(index, this);
    readCount++;
    return index == source.length ? appended : source[index];
  }

  @override
  void operator []=(int index, InkStroke value) =>
      throw UnsupportedError('Test list is immutable.');
}
