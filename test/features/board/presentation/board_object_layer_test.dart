import 'dart:typed_data';

import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/presentation/board_object_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const transform = ObjectTransform(x: 20, y: 20, width: 120, height: 80);

  group('VisibleObjectInkLayerIndex', () {
    test('matches ordered PDF-page lookup and legacy fallback semantics', () {
      final hiddenExact = _layer(
        'hidden-exact',
        'pdf',
        page: 5,
        visible: false,
      );
      final legacyFirst = _layer('legacy-first', 'pdf');
      final legacyDuplicate = _layer('legacy-duplicate', 'pdf');
      final pageFiveFirst = _layer('page-five-first', 'pdf', page: 5);
      final pageFiveDuplicate = _layer('page-five-duplicate', 'pdf', page: 5);
      final pageTwo = _layer('page-two', 'pdf', page: 2);
      final shapePage = _layer('shape-page', 'shape', page: 5);
      final shapeLegacy = _layer('shape-legacy', 'shape');
      final layers = <ObjectInkLayer>[
        hiddenExact,
        legacyFirst,
        legacyDuplicate,
        pageFiveFirst,
        pageFiveDuplicate,
        pageTwo,
        shapePage,
        shapeLegacy,
      ];
      final index = VisibleObjectInkLayerIndex(layers);
      final pdfPageFive = PdfObject(
        id: 'pdf',
        transform: transform,
        assetId: 'asset',
        pageIndices: const [2, 5],
        activePageIndex: 1,
      );
      final pdfPageTwo = pdfPageFive.copyWithActivePage(0);
      final pdfMissingPage = PdfObject(
        id: 'pdf',
        transform: transform,
        assetId: 'asset',
        pageIndices: const [7],
      );
      final shape = ShapeObject(id: 'shape', transform: transform);
      final unrelated = ShapeObject(id: 'unrelated', transform: transform);

      for (final object in <BoardObject>[
        pdfPageFive,
        pdfPageTwo,
        pdfMissingPage,
        shape,
        unrelated,
      ]) {
        expect(
          index.layerFor(object),
          same(activeObjectInkLayer(object, layers)),
          reason: 'Index lookup diverged for ${object.id}/${object.type.name}',
        );
      }
      expect(index.layerFor(pdfPageFive), same(pageFiveFirst));
      expect(index.layerFor(pdfPageTwo), same(pageTwo));
      expect(index.layerFor(pdfMissingPage), same(legacyFirst));
      expect(index.layerFor(shape), same(shapeLegacy));
      expect(index.layerFor(unrelated), isNull);
    });
  });

  group('BoardObjectLayer', () {
    testWidgets('rebuilds its annotation index when the layer list changes', (
      tester,
    ) async {
      final shape = ShapeObject(id: 'shape', transform: transform);

      Future<void> pump(List<ObjectInkLayer> layers) => tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 300,
            child: BoardObjectLayer(
              objects: <BoardObject>[shape],
              annotationLayers: layers,
              scale: 1,
              offset: Offset.zero,
              assets: const _NoAssets(),
            ),
          ),
        ),
      );

      await pump(<ObjectInkLayer>[_layer('legacy', 'shape')]);
      expect(_objectLayerPaints(), findsNWidgets(2));

      await pump(<ObjectInkLayer>[_layer('other-page', 'shape', page: 4)]);
      expect(_objectLayerPaints(), findsOneWidget);
    });

    testWidgets('can preserve an already scene-ordered object run', (
      tester,
    ) async {
      final back = ShapeObject(id: 'back', transform: transform, zIndex: 1);
      final front = ShapeObject(id: 'front', transform: transform, zIndex: 9);

      Future<List<String>> pump({required bool alreadyOrdered}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 400,
              height: 300,
              child: BoardObjectLayer(
                objects: <BoardObject>[front, back],
                annotationLayers: const <ObjectInkLayer>[],
                scale: 1,
                offset: Offset.zero,
                assets: const _NoAssets(),
                objectsAreSceneOrdered: alreadyOrdered,
              ),
            ),
          ),
        );
        return find
            .byWidgetPredicate(
              (widget) =>
                  widget is Positioned &&
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'board-object-',
                  ),
            )
            .evaluate()
            .map(
              (element) => ((element.widget.key! as ValueKey<String>).value)
                  .substring('board-object-'.length),
            )
            .toList(growable: false);
      }

      expect(await pump(alreadyOrdered: false), <String>['back', 'front']);
      expect(await pump(alreadyOrdered: true), <String>['front', 'back']);
    });

    testWidgets('omits identity transform, opacity and content stack nodes', (
      tester,
    ) async {
      final shape = ShapeObject(id: 'plain', transform: transform);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 300,
            child: BoardObjectLayer(
              objects: <BoardObject>[shape],
              annotationLayers: const <ObjectInkLayer>[],
              scale: 1,
              offset: Offset.zero,
              assets: const _NoAssets(),
            ),
          ),
        ),
      );

      final object = find.byKey(const ValueKey<String>('board-object-plain'));
      expect(
        find.descendant(of: object, matching: find.byType(Transform)),
        findsNothing,
      );
      expect(
        find.descendant(of: object, matching: find.byType(Opacity)),
        findsNothing,
      );
      expect(
        find.descendant(of: object, matching: find.byType(Stack)),
        findsNothing,
      );
    });

    testWidgets('reuses recorded object annotation while viewport zooms', (
      tester,
    ) async {
      final shape = ShapeObject(id: 'annotated', transform: transform);
      final objects = <BoardObject>[shape];
      final annotations = <ObjectInkLayer>[_layer('annotation', shape.id)];

      Future<CustomPainter?> pump(double scale) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 500,
              height: 400,
              child: BoardObjectLayer(
                objects: objects,
                annotationLayers: annotations,
                scale: scale,
                offset: Offset.zero,
                assets: const _NoAssets(),
              ),
            ),
          ),
        );
        final annotation = find.byKey(
          const ValueKey<String>('board-annotation-annotated'),
        );
        return tester
            .widget<CustomPaint>(
              find.descendant(
                of: annotation,
                matching: find.byType(CustomPaint),
              ),
            )
            .painter;
      }

      final initialPainter = await pump(1);
      final zoomedPainter = await pump(1.37);
      expect(zoomedPainter, same(initialPainter));
    });

    testWidgets(
      'bounds annotation recording work while hundreds of strokes append',
      (tester) async {
        var layer = ObjectInkLayer(
          id: 'dense-annotation',
          objectId: 'shape',
          strokes: List<InkStroke>.generate(256, _annotationStroke),
        );
        final cache = ObjectAnnotationPictureCache();
        addTearDown(cache.dispose);

        cache.update(layer: layer, logicalSize: const Size(120, 80));
        expect(cache.debugFullRebuildCount, 1);
        expect(cache.debugLastRecordedStrokeCount, 256);
        expect(cache.debugPictureCount, 8);

        for (var index = 256; index < 768; index++) {
          layer = layer.appendStroke(_annotationStroke(index));
          cache.update(layer: layer, logicalSize: const Size(120, 80));
          expect(
            cache.debugLastRecordedStrokeCount,
            lessThanOrEqualTo(ObjectAnnotationPictureCache.strokesPerPicture),
          );
        }
        expect(cache.debugFullRebuildCount, 1);
        expect(cache.debugPictureCount, 24);

        final recordedBeforeUniformResize = cache.debugRecordedStrokeCount;
        cache.update(layer: layer, logicalSize: const Size(300, 200));
        expect(
          cache.debugRecordedStrokeCount,
          recordedBeforeUniformResize,
          reason: 'Uniform object resize should reuse vector pictures.',
        );

        cache.update(layer: layer, logicalSize: const Size(300, 300));
        expect(cache.debugFullRebuildCount, 2);
        expect(cache.debugLastRecordedStrokeCount, 768);

        final replaced = layer.copyWith(
          strokes: <InkStroke>[
            ...layer.strokes.take(layer.strokes.length - 1),
            _annotationStroke(9999),
          ],
        );
        cache.update(layer: replaced, logicalSize: const Size(300, 300));
        expect(
          cache.debugFullRebuildCount,
          3,
          reason: 'A replace must never be mistaken for an append.',
        );

        cache.dispose();
        expect(cache.debugPictureDisposeCount, cache.debugPictureCreateCount);
      },
    );

    testWidgets('reuses text layout while only viewport zoom changes', (
      tester,
    ) async {
      final text = TextObject(
        id: 'text',
        transform: transform,
        text: 'Ein stabil zwischengespeicherter Absatz',
      );
      final objects = <BoardObject>[text];

      Future<BoardTextPainter> pump(double scale) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 500,
              height: 400,
              child: BoardObjectLayer(
                objects: objects,
                annotationLayers: const <ObjectInkLayer>[],
                scale: scale,
                offset: Offset.zero,
                assets: const _NoAssets(),
              ),
            ),
          ),
        );
        return tester
                .widget<CustomPaint>(
                  find.byKey(const ValueKey<String>('board-text-text')),
                )
                .painter!
            as BoardTextPainter;
      }

      final initial = await pump(1);
      expect(initial.debugUsesPersistentLayoutCache, isTrue);
      expect(initial.debugLayoutCount, 1);

      final zoomed = await pump(1.37);
      expect(zoomed.debugUsesPersistentLayoutCache, isTrue);
      expect(zoomed.debugLayoutCount, 1);
    });

    testWidgets(
      'does not retain a giant raster layer for an oversized object',
      (tester) async {
        final oversized = ShapeObject(
          id: 'oversized',
          transform: const ObjectTransform(
            x: 0,
            y: 0,
            width: 100000,
            height: 100000,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 800,
              height: 600,
              child: BoardObjectLayer(
                objects: <BoardObject>[oversized],
                annotationLayers: const <ObjectInkLayer>[],
                scale: 1,
                offset: Offset.zero,
                assets: const _NoAssets(),
              ),
            ),
          ),
        );

        final object = find.byKey(
          const ValueKey<String>('board-object-oversized'),
        );
        expect(object, findsOneWidget);
        expect(
          find.descendant(of: object, matching: find.byType(RepaintBoundary)),
          findsNothing,
        );
      },
    );

    testWidgets('ignores a malformed object transform defensively', (
      tester,
    ) async {
      final malformed = ShapeObject(
        id: 'malformed',
        transform: const ObjectTransform(
          x: double.nan,
          y: 0,
          width: 40,
          height: 40,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: BoardObjectLayer(
              objects: <BoardObject>[malformed],
              annotationLayers: const <ObjectInkLayer>[],
              scale: 1,
              offset: Offset.zero,
              assets: const _NoAssets(),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('board-object-malformed')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('boardObjectShouldIsolateRepaint', () {
    test('bounds retained raster dimensions and area', () {
      expect(boardObjectShouldIsolateRepaint(const Size(800, 600)), isTrue);
      expect(boardObjectShouldIsolateRepaint(const Size(3000, 100)), isFalse);
      expect(boardObjectShouldIsolateRepaint(const Size(1800, 1800)), isFalse);
      expect(
        boardObjectShouldIsolateRepaint(const Size(double.infinity, 100)),
        isFalse,
      );
    });
  });

  group('boardObjectRasterScaleTier', () {
    test('rounds up and remains stable inside a PDF zoom band', () {
      expect(boardObjectRasterScaleTier(.76), 1);
      expect(boardObjectRasterScaleTier(.99), 1);
      expect(boardObjectRasterScaleTier(1), 1);
      expect(boardObjectRasterScaleTier(1.01), 1.5);
      expect(boardObjectRasterScaleTier(1.49), 1.5);
      expect(boardObjectRasterScaleTier(2.01), 3);
    });

    test('defensively bounds invalid and extreme scales', () {
      expect(boardObjectRasterScaleTier(double.nan), 1);
      expect(boardObjectRasterScaleTier(0), 1);
      expect(boardObjectRasterScaleTier(-4), 1);
      expect(boardObjectRasterScaleTier(1000), 16);
    });
  });
}

Finder _objectLayerPaints() => find.descendant(
  of: find.byType(BoardObjectLayer),
  matching: find.byType(CustomPaint),
);

ObjectInkLayer _layer(
  String id,
  String objectId, {
  int? page,
  bool visible = true,
}) => ObjectInkLayer(
  id: id,
  objectId: objectId,
  pdfPageIndex: page,
  visible: visible,
);

InkStroke _annotationStroke(int index) => InkStroke(
  id: 'annotation-$index',
  points: <InkPoint>[
    InkPoint(x: (index % 17) / 18, y: (index % 13) / 14, pressure: .65),
    InkPoint(
      x: ((index + 1) % 17) / 18,
      y: ((index + 2) % 13) / 14,
      pressure: .72,
    ),
    InkPoint(
      x: ((index + 2) % 17) / 18,
      y: ((index + 4) % 13) / 14,
      pressure: .8,
    ),
  ],
  width: .025,
  type: InkToolType.normal,
);

class _NoAssets implements BoardAssetResolver {
  const _NoAssets();

  @override
  String? localPath(String assetId) => null;

  @override
  Future<Uint8List?> readBytes(String assetId) async => null;
}
