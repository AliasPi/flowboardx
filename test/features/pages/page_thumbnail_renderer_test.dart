import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/presentation/board_object_layer.dart';
import 'package:flowboard_x/src/features/pages/page_thumbnail_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('long circular ink is reduced to a fixed thumbnail command budget', () {
    final source = List<InkPoint>.generate(20000, (index) {
      final angle = math.pi * 2 * index / 19999;
      return InkPoint(
        x: math.cos(angle) * 500,
        y: math.sin(angle) * 500,
        pressure: index / 20000,
      );
    }, growable: false);

    final sampled = PageThumbnailRenderer.sampleStrokePoints(source);

    expect(
      sampled,
      hasLength(PageThumbnailRenderer.maximumThumbnailStrokePoints),
    );
    expect(sampled.first, same(source.first));
    expect(sampled.last, same(source.last));
    expect(sampled.map((point) => point.y).reduce(math.min), lessThan(-495));
    expect(sampled.map((point) => point.y).reduce(math.max), greaterThan(495));
  });

  test('long stroke reduction cooperatively observes cancellation', () {
    var checks = 0;
    final source = List<InkPoint>.generate(
      100000,
      (index) => InkPoint(x: index.toDouble(), y: (index % 17).toDouble()),
      growable: false,
    );

    expect(
      () => PageThumbnailRenderer.sampleStrokePoints(
        source,
        shouldCancel: () => ++checks > 5,
      ),
      throwsA(isA<PageThumbnailRenderCancelled>()),
    );
    expect(checks, lessThan(20));
  });

  test('content-heavy pages have one aggregate thumbnail point budget', () {
    final budgets = PageThumbnailRenderer.allocateStrokePointBudgets(
      List<int>.filled(2400, 2000, growable: false),
    );

    expect(budgets, hasLength(2400));
    expect(
      budgets.fold<int>(0, (total, value) => total + value),
      lessThanOrEqualTo(
        PageThumbnailRenderer.maximumThumbnailTotalStrokePoints,
      ),
    );
    expect(
      budgets.every(
        (value) =>
            value >= 0 &&
            value <= PageThumbnailRenderer.maximumThumbnailStrokePoints,
      ),
      isTrue,
    );
    expect(
      budgets.where((value) => value > 0),
      hasLength(2400),
      reason: 'ordinary classroom-sized stroke counts remain represented',
    );
  });

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

  testWidgets('reuses an embedded image decode across ink-only refreshes', (
    tester,
  ) async {
    final sourceBytes = await tester.runAsync<Uint8List>(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, 4, 2),
        ui.Paint()..color = const ui.Color(0xFF267F66),
      );
      final picture = recorder.endRecording();
      final source = await picture.toImage(4, 2);
      final data = await source.toByteData(format: ui.ImageByteFormat.png);
      source.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    });
    final assets = _CountingBytesResolver(sourceBytes!);
    final page = BoardPage.empty(id: 'image-cache-page').copyWith(
      objects: <BoardObject>[
        ImageObject(
          id: 'cached-image',
          transform: const ObjectTransform(x: 0, y: 0, width: 960, height: 540),
          assetId: 'image-asset',
        ),
      ],
    );
    final renderer = PageThumbnailRenderer();
    addTearDown(renderer.dispose);

    await tester.runAsync<void>(() async {
      final first = await renderer.render(page, assets);
      first.dispose();
      final inkChangedPage = page.copyWith(
        strokes: <InkStroke>[
          InkStroke(
            id: 'new-ink',
            points: const <InkPoint>[
              InkPoint(x: 20, y: 20),
              InkPoint(x: 80, y: 80),
            ],
          ),
        ],
      );
      final second = await renderer.render(inkChangedPage, assets);
      second.dispose();
    });

    expect(
      assets.readCount,
      1,
      reason: 'new ink must not decode an unchanged embedded image again',
    );
  });

  testWidgets('embedded-image cache evicts least-recently-used assets', (
    tester,
  ) async {
    final sourceBytes = await tester.runAsync<Uint8List>(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, 4, 2),
        ui.Paint()..color = const ui.Color(0xFF397A93),
      );
      final picture = recorder.endRecording();
      final source = await picture.toImage(4, 2);
      final data = await source.toByteData(format: ui.ImageByteFormat.png);
      source.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    });
    final assets = _PerAssetCountingBytesResolver(sourceBytes!);
    final renderer = PageThumbnailRenderer(imageCacheCapacity: 2);
    addTearDown(renderer.dispose);

    BoardPage pageFor(String assetId) =>
        BoardPage.empty(id: 'page-$assetId').copyWith(
          objects: <BoardObject>[
            ImageObject(
              id: 'object-$assetId',
              transform: const ObjectTransform(
                x: 0,
                y: 0,
                width: 960,
                height: 540,
              ),
              assetId: assetId,
            ),
          ],
        );

    await tester.runAsync<void>(() async {
      for (final assetId in const <String>[
        'image-1',
        'image-2',
        'image-3',
        'image-3',
      ]) {
        final thumbnail = await renderer.render(pageFor(assetId), assets);
        thumbnail.dispose();
      }
    });

    expect(assets.readCounts['image-1'], 1);
    expect(assets.readCounts['image-2'], 1);
    expect(
      assets.readCounts['image-3'],
      1,
      reason: 'recent assets replace cold entries instead of bypassing cache',
    );
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

  testWidgets('cancels stale work without poisoning the PDF raster cache', (
    tester,
  ) async {
    var rasterizeCount = 0;
    var cancelled = false;
    final renderer = PageThumbnailRenderer(
      pdfRasterizer: (_, _, _) async {
        rasterizeCount++;
        cancelled = true;
        return PdfThumbnailRaster(
          width: 2,
          height: 1,
          bgraBytes: Uint8List.fromList(<int>[0, 180, 0, 255, 0, 180, 0, 255]),
        );
      },
    );
    addTearDown(renderer.dispose);
    final page = BoardPage.empty(id: 'cancel-page').copyWith(
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

    await tester.runAsync<void>(() async {
      final stale = renderer.render(
        page,
        const _PathResolver(r'C:\assets\lesson.pdf'),
        shouldCancel: () => cancelled,
      );
      await expectLater(stale, throwsA(isA<PageThumbnailRenderCancelled>()));

      cancelled = false;
      final fresh = await renderer.render(
        page,
        const _PathResolver(r'C:\assets\lesson.pdf'),
      );
      fresh.dispose();
    });

    expect(rasterizeCount, 1);
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

final class _CountingBytesResolver implements BoardAssetResolver {
  _CountingBytesResolver(this.bytes);

  final Uint8List bytes;
  int readCount = 0;

  @override
  String? localPath(String assetId) => null;

  @override
  Future<Uint8List?> readBytes(String assetId) async {
    readCount++;
    return bytes;
  }
}

final class _PerAssetCountingBytesResolver implements BoardAssetResolver {
  _PerAssetCountingBytesResolver(this.bytes);

  final Uint8List bytes;
  final Map<String, int> readCounts = <String, int>{};

  @override
  String? localPath(String assetId) => null;

  @override
  Future<Uint8List?> readBytes(String assetId) async {
    readCounts.update(assetId, (count) => count + 1, ifAbsent: () => 1);
    return bytes;
  }
}
