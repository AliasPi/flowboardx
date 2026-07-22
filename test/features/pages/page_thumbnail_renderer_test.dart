import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/features/board/presentation/board_object_layer.dart';
import 'package:flowboard_x/src/features/pages/page_thumbnail_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('thumbnail survives a failing optional image asset', (
    tester,
  ) async {
    final page = BoardPage.empty(id: 'thumbnail-page', name: 'Seite').copyWith(
      objects: <BoardObject>[
        ImageObject(
          id: 'broken-image',
          transform: const ObjectTransform(
            x: 100,
            y: 120,
            width: 500,
            height: 300,
          ),
          assetId: 'missing',
        ),
      ],
    );

    final renderer = PageThumbnailRenderer();
    addTearDown(renderer.dispose);
    final image = await renderer.render(page, const _ThrowingResolver());
    expect(image.width, 192);
    expect(image.height, 108);
    image.dispose();
  });

  testWidgets('thumbnail renders and caches the active PDF source page', (
    tester,
  ) async {
    var renderCount = 0;
    var renderedSourcePage = -1;
    final renderer = PageThumbnailRenderer(
      pdfRasterizer: (path, sourcePageIndex, maxDimension) async {
        renderCount++;
        renderedSourcePage = sourcePageIndex;
        expect(path, r'C:\assets\lesson.pdf');
        expect(maxDimension, 384);
        return PdfThumbnailRaster(
          width: 2,
          height: 1,
          bgraBytes: Uint8List.fromList(<int>[0, 180, 0, 255, 0, 180, 0, 255]),
        );
      },
    );
    addTearDown(renderer.dispose);
    final page = BoardPage.empty(id: 'pdf-page', name: 'PDF').copyWith(
      objects: <BoardObject>[
        PdfObject(
          id: 'pdf-object',
          transform: const ObjectTransform(
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
          ),
          assetId: 'pdf-asset',
          pageIndices: const <int>[1, 4],
          activePageIndex: 1,
        ),
      ],
    );
    const assets = _PathResolver(r'C:\assets\lesson.pdf');

    final centerPixel = await tester.runAsync<List<int>>(() async {
      final first = await renderer.render(page, assets);
      final bytes = await first.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(bytes, isNotNull);
      final center = (54 * first.width + 96) * 4;
      final result = <int>[
        bytes!.getUint8(center),
        bytes.getUint8(center + 1),
        bytes.getUint8(center + 2),
        bytes.getUint8(center + 3),
      ];
      first.dispose();
      return result;
    });
    expect(centerPixel, <int>[0, 180, 0, 255]);

    await tester.runAsync<void>(() async {
      final second = await renderer.render(page, assets);
      second.dispose();
    });
    expect(renderedSourcePage, 4);
    expect(renderCount, 1, reason: 'the pdfrx raster is reused from the cache');
  });

  testWidgets('thumbnail uses a safe fallback when PDF rendering fails', (
    tester,
  ) async {
    final renderer = PageThumbnailRenderer(
      pdfRasterizer: (_, _, _) async => throw StateError('broken PDF'),
    );
    addTearDown(renderer.dispose);
    final page = BoardPage.empty(id: 'pdf-page').copyWith(
      objects: <BoardObject>[
        PdfObject(
          id: 'pdf-object',
          transform: const ObjectTransform(
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
          ),
          assetId: 'pdf-asset',
          pageIndices: const <int>[0],
        ),
      ],
    );

    final image = await renderer.render(
      page,
      const _PathResolver(r'C:\assets\broken.pdf'),
    );
    expect(image.width, 192);
    expect(image.height, 108);
    image.dispose();
  });
}

final class _ThrowingResolver implements BoardAssetResolver {
  const _ThrowingResolver();

  @override
  String? localPath(String assetId) => null;

  @override
  Future<Uint8List?> readBytes(String assetId) =>
      Future<Uint8List?>.error(StateError('asset unavailable'));
}

final class _PathResolver implements BoardAssetResolver {
  const _PathResolver(this.path);

  final String path;

  @override
  String? localPath(String assetId) => path;

  @override
  Future<Uint8List?> readBytes(String assetId) async => null;
}
