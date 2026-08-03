import 'dart:typed_data';

import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/features/assets/imported_image_layout.dart';
import 'package:flowboard_x/src/features/board/presentation/board_object_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('existing oversized asset is rejected before renderer decode', (
    tester,
  ) async {
    final resolver = _MemoryResolver(
      _pngHeader(width: ImportedImageLayout.maximumAxisPixels + 1, height: 100),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.expand(
          child: BoardObjectLayer(
            objects: [
              ImageObject(
                id: 'oversized',
                transform: const ObjectTransform(
                  x: 20,
                  y: 20,
                  width: 640,
                  height: 420,
                ),
                assetId: 'asset',
              ),
            ],
            annotationLayers: const [],
            scale: 1,
            offset: Offset.zero,
            assets: resolver,
          ),
        ),
      ),
    );
    await tester.pump();

    final object = find.byKey(const ValueKey('board-object-oversized'));
    expect(object, findsOneWidget);
    expect(
      find.descendant(
        of: object,
        matching: find.byIcon(Icons.broken_image_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: object, matching: find.byType(Image)),
      findsNothing,
    );
    expect(resolver.byteReads, 1);
  });

  testWidgets('viewport culling does not probe the same image asset again', (
    tester,
  ) async {
    final resolver = _MemoryResolver(
      _pngHeader(width: ImportedImageLayout.maximumAxisPixels + 1, height: 100),
    );
    final image = ImageObject(
      id: 'culled-image',
      transform: const ObjectTransform(x: 20, y: 20, width: 120, height: 80),
      assetId: 'asset',
    );

    Future<void> pump(Rect2 clip) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 300,
            child: BoardObjectLayer(
              objects: <BoardObject>[image],
              annotationLayers: const <ObjectInkLayer>[],
              scale: 1,
              offset: Offset.zero,
              assets: resolver,
              worldClip: clip,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pump(const Rect2(left: 0, top: 0, width: 400, height: 300));
    expect(resolver.byteReads, 1);

    await pump(const Rect2(left: 1000, top: 1000, width: 400, height: 300));
    expect(
      find.byKey(const ValueKey<String>('board-object-culled-image')),
      findsNothing,
    );

    await pump(const Rect2(left: 0, top: 0, width: 400, height: 300));
    expect(resolver.byteReads, 1);
  });
}

final class _MemoryResolver implements BoardAssetResolver {
  _MemoryResolver(this.bytes);

  final Uint8List bytes;
  int byteReads = 0;

  @override
  String? localPath(String assetId) => null;

  @override
  Future<Uint8List?> readBytes(String assetId) async {
    byteReads++;
    return bytes;
  }
}

Uint8List _pngHeader({required int width, required int height}) {
  final bytes = Uint8List(24);
  bytes.setRange(0, 8, const [137, 80, 78, 71, 13, 10, 26, 10]);
  final data = ByteData.sublistView(bytes);
  data.setUint32(16, width, Endian.big);
  data.setUint32(20, height, Endian.big);
  return bytes;
}
