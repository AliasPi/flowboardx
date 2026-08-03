import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flowboard_x/src/features/assets/imported_image_layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ImportedImageLayout', () {
    test('keeps landscape and portrait aspect ratios in insertion bounds', () {
      final landscape = ImportedImageLayout.boardSizeFor(
        const ui.Size(1600, 900),
      );
      final portrait = ImportedImageLayout.boardSizeFor(
        const ui.Size(900, 1600),
      );

      expect(landscape.width, 640);
      expect(landscape.height, closeTo(360, .001));
      expect(portrait.width, closeTo(236.25, .001));
      expect(portrait.height, 420);
      expect(landscape.aspectRatio, closeTo(1600 / 900, .0001));
      expect(portrait.aspectRatio, closeTo(900 / 1600, .0001));
    });

    test('uses a safe legacy size for unusable image metadata', () {
      expect(
        ImportedImageLayout.boardSizeFor(null),
        ImportedImageLayout.defaultBounds,
      );
      expect(
        ImportedImageLayout.boardSizeFor(const ui.Size(0, 100)),
        ImportedImageLayout.defaultBounds,
      );
      expect(
        ImportedImageLayout.boardSizeFor(const ui.Size(double.infinity, 100)),
        ImportedImageLayout.defaultBounds,
      );
    });

    test('reads encoded dimensions without decoding a board frame', () async {
      final data = await _png(width: 40, height: 20);

      final dimensions = await ImportedImageLayout.dimensionsFromBytes(data);

      expect(dimensions, const ui.Size(40, 20));
    });

    test('uses a fit decode policy for independently quantised bounds', () {
      final provider = ImportedImageLayout.aspectPreservingProvider(
        MemoryImage(Uint8List.fromList(const [1, 2, 3])),
        physicalSize: const ui.Size(600, 400),
      );

      // The two cache bounds quantise to 1024 x 512. With Flutter's default
      // exact policy this would deform 3:2 input to 2:1.
      expect(provider.width, 1024);
      expect(provider.height, 512);
      expect(provider.policy, ResizeImagePolicy.fit);
    });

    test('bounds one 4K image cache entry without changing its source', () {
      final provider = ImportedImageLayout.aspectPreservingProvider(
        MemoryImage(Uint8List.fromList(const [1, 2, 3])),
        physicalSize: const ui.Size(5000, 5000),
      );

      expect(provider.width, ImportedImageLayout.maximumBoardDecodeAxis);
      expect(provider.height, ImportedImageLayout.maximumBoardDecodeAxis);
      expect(provider.policy, ResizeImagePolicy.fit);
    });

    test(
      'decoded 3:2 and odd-ratio images retain their source ratio',
      () async {
        final threeByTwo = await _decodedSize(
          source: await _png(width: 600, height: 400),
          physicalSize: const ui.Size(300, 200),
        );
        final oddRatio = await _decodedSize(
          source: await _png(width: 403, height: 277),
          physicalSize: const ui.Size(300, 207),
        );

        expect(threeByTwo, const ui.Size(384, 256));
        expect(threeByTwo.aspectRatio, closeTo(1.5, .0001));
        expect(oddRatio.aspectRatio, closeTo(403 / 277, .005));
        expect(oddRatio.aspectRatio, isNot(closeTo(403 / 256, .01)));
      },
    );

    test('reads common Web formats from bounded header metadata', () {
      final webp = Uint8List(30);
      webp.setRange(0, 4, 'RIFF'.codeUnits);
      webp.setRange(8, 12, 'WEBP'.codeUnits);
      webp.setRange(12, 16, 'VP8X'.codeUnits);
      ByteData.sublistView(webp, 16, 20).setUint32(0, 10, Endian.little);
      _setUint24Little(webp, 24, 599);
      _setUint24Little(webp, 27, 399);

      final jpeg = Uint8List.fromList([
        0xFF,
        0xD8,
        0xFF,
        0xC0,
        0x00,
        0x11,
        0x08,
        0x01,
        0x90,
        0x02,
        0x58,
        0x03,
        0x01,
        0x11,
        0,
        0x02,
        0x11,
        0,
        0x03,
        0x11,
        0,
      ]);

      expect(
        ImportedImageLayout.dimensionsFromEncodedHeader(webp),
        const ui.Size(600, 400),
      );
      expect(
        ImportedImageLayout.dimensionsFromEncodedHeader(jpeg),
        const ui.Size(600, 400),
      );
      expect(
        ImportedImageLayout.dimensionsFromEncodedHeader(
          Uint8List.fromList(const [0xFF, 0xD8, 0xFF]),
        ),
        isNull,
      );
    });

    test('accepts a normal 8K image within the Android safety budget', () {
      final encoded = ImportedImageLayout.dimensionsFromEncodedHeader(
        _pngHeader(width: 7680, height: 4320),
      );

      expect(
        ImportedImageLayout.validateDimensions(encoded!),
        const ui.Size(7680, 4320),
      );
    });

    test('rejects an oversized axis before invoking a pixel decoder', () async {
      await expectLater(
        ImportedImageLayout.dimensionsFromBytes(
          _pngHeader(
            width: ImportedImageLayout.maximumAxisPixels + 1,
            height: 100,
          ),
        ),
        throwsA(
          isA<ImportedImageValidationException>().having(
            (error) => error.failure,
            'failure',
            ImportedImageValidationFailure.axisTooLarge,
          ),
        ),
      );
    });

    test('rejects excessive decoded megapixels before decoding', () async {
      await expectLater(
        ImportedImageLayout.dimensionsFromBytes(
          _pngHeader(width: 8192, height: 8192),
        ),
        throwsA(
          isA<ImportedImageValidationException>().having(
            (error) => error.failure,
            'failure',
            ImportedImageValidationFailure.pixelCountTooLarge,
          ),
        ),
      );
    });

    test('rejects unknown bytes instead of guessing image bounds', () async {
      await expectLater(
        ImportedImageLayout.dimensionsFromBytes(
          Uint8List.fromList(const [1, 2, 3, 4, 5]),
        ),
        throwsA(
          isA<ImportedImageValidationException>().having(
            (error) => error.failure,
            'failure',
            ImportedImageValidationFailure.unsupportedOrCorrupt,
          ),
        ),
      );
    });
  });
}

Future<Uint8List> _png({required int width, required int height}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF42DDB0),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Future<ui.Size> _decodedSize({
  required Uint8List source,
  required ui.Size physicalSize,
}) async {
  final provider = ImportedImageLayout.aspectPreservingProvider(
    MemoryImage(source),
    physicalSize: physicalSize,
  );
  final stream = provider.resolve(ImageConfiguration.empty);
  final completer = Completer<ui.Size>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!completer.isCompleted) {
        completer.complete(
          ui.Size(info.image.width.toDouble(), info.image.height.toDouble()),
        );
      }
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  final result = await completer.future.timeout(const Duration(seconds: 5));
  await provider.evict(configuration: ImageConfiguration.empty);
  return result;
}

void _setUint24Little(Uint8List bytes, int offset, int value) {
  bytes[offset] = value & 0xFF;
  bytes[offset + 1] = (value >> 8) & 0xFF;
  bytes[offset + 2] = (value >> 16) & 0xFF;
}

Uint8List _pngHeader({required int width, required int height}) {
  final bytes = Uint8List(24);
  bytes.setRange(0, 8, const [137, 80, 78, 71, 13, 10, 26, 10]);
  final data = ByteData.sublistView(bytes);
  data.setUint32(16, width, Endian.big);
  data.setUint32(20, height, Endian.big);
  return bytes;
}
