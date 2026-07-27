import 'dart:typed_data';

import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/presentation/board_object_layer.dart';
import 'package:flowboard_x/src/features/board/presentation/board_scene_layer.dart';
import 'package:flowboard_x/src/features/board/presentation/persisted_ink_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keeps persisted vector pictures when a stroke is appended', (
    tester,
  ) async {
    final initial = List<InkStroke>.unmodifiable(
      List<InkStroke>.generate(12, _stroke),
    );

    await _pumpScene(tester, initial);
    final before = _persistedPainter(tester, 0);
    final pictureBefore = before.cache.pictureFor(initial.first);

    final appended = List<InkStroke>.unmodifiable(<InkStroke>[
      ...initial,
      _stroke(initial.length),
    ]);
    await _pumpScene(tester, appended);
    final after = _persistedPainter(tester, 0);

    expect(after.cache, same(before.cache));
    expect(after.cache.pictureFor(initial.first), same(pictureBefore));
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
}

Future<void> _pumpScene(WidgetTester tester, List<InkStroke> strokes) =>
    tester.pumpWidget(
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

class _NoAssets implements BoardAssetResolver {
  const _NoAssets();

  @override
  String? localPath(String assetId) => null;

  @override
  Future<Uint8List?> readBytes(String assetId) async => null;
}
