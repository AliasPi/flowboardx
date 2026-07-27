import 'dart:typed_data';

import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
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

class _NoAssets implements BoardAssetResolver {
  const _NoAssets();

  @override
  String? localPath(String assetId) => null;

  @override
  Future<Uint8List?> readBytes(String assetId) async => null;
}
