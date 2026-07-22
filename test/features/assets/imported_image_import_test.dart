import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/features/assets/imported_image_layout.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Google/byte image import adopts its intrinsic aspect ratio', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flowboard-image-aspect-',
    );
    final repository = _AssetRepository(directory);
    final controller = EditorController(
      document: WhiteboardDocument.create(id: 'image-aspect'),
      repository: repository,
      assetDirectory: directory,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    await controller.importImageBytes(
      await _png(width: 40, height: 20),
      fileName: 'google-result.png',
      mimeType: 'image/png',
    );

    final image = controller.page.objects.whereType<ImageObject>().single;
    expect(image.transform.width, 640);
    expect(image.transform.height, closeTo(320, .001));
    expect(image.transform.width / image.transform.height, closeTo(2, .0001));
  });

  test('file image import adopts a portrait aspect ratio', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flowboard-file-image-aspect-',
    );
    final repository = _AssetRepository(directory);
    final source = File(
      '${directory.path}${Platform.pathSeparator}portrait-source.png',
    );
    await source.writeAsBytes(await _png(width: 20, height: 40), flush: true);
    final controller = EditorController(
      document: WhiteboardDocument.create(id: 'file-image-aspect'),
      repository: repository,
      assetDirectory: directory,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    await controller.importImage(source.path, mimeType: 'image/png');

    final image = controller.page.objects.whereType<ImageObject>().single;
    expect(image.transform.width, closeTo(210, .001));
    expect(image.transform.height, 420);
    expect(image.transform.width / image.transform.height, closeTo(.5, .0001));
  });

  test('oversized byte image is rejected without creating an asset', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flowboard-image-bomb-bytes-',
    );
    final repository = _AssetRepository(directory);
    final controller = EditorController(
      document: WhiteboardDocument.create(id: 'image-bomb-bytes'),
      repository: repository,
      assetDirectory: directory,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    await expectLater(
      controller.importImageBytes(
        _pngHeader(
          width: ImportedImageLayout.maximumAxisPixels + 1,
          height: 64,
        ),
        fileName: 'decompression-bomb.png',
        mimeType: 'image/png',
      ),
      throwsA(
        isA<ImportedImageValidationException>().having(
          (error) => error.failure,
          'failure',
          ImportedImageValidationFailure.axisTooLarge,
        ),
      ),
    );

    expect(controller.document.assets, isEmpty);
    expect(controller.page.objects, isEmpty);
    expect(await directory.list().toList(), isEmpty);
  });

  test('oversized file image is rejected without an orphaned copy', () async {
    final root = await Directory.systemTemp.createTemp(
      'flowboard-image-bomb-file-',
    );
    final assets = await Directory(
      '${root.path}${Platform.pathSeparator}assets',
    ).create();
    final source = File(
      '${root.path}${Platform.pathSeparator}decompression-bomb.png',
    );
    await source.writeAsBytes(
      _pngHeader(width: 8192, height: 8192),
      flush: true,
    );
    final repository = _AssetRepository(assets);
    final controller = EditorController(
      document: WhiteboardDocument.create(id: 'image-bomb-file'),
      repository: repository,
      assetDirectory: assets,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await expectLater(
      controller.importImage(source.path, mimeType: 'image/png'),
      throwsA(
        isA<ImportedImageValidationException>()
            .having(
              (error) => error.failure,
              'failure',
              ImportedImageValidationFailure.pixelCountTooLarge,
            )
            .having(
              (error) => error.toString(),
              'message',
              contains('zu groß'),
            ),
      ),
    );

    expect(controller.document.assets, isEmpty);
    expect(controller.page.objects, isEmpty);
    expect(await assets.list().toList(), isEmpty);
    expect(await source.exists(), isTrue);
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

Uint8List _pngHeader({required int width, required int height}) {
  final bytes = Uint8List(24);
  bytes.setRange(0, 8, const [137, 80, 78, 71, 13, 10, 26, 10]);
  final data = ByteData.sublistView(bytes);
  data.setUint32(16, width, Endian.big);
  data.setUint32(20, height, Endian.big);
  return bytes;
}

final class _AssetRepository implements DocumentRepository {
  _AssetRepository(this.directory);

  final Directory directory;

  @override
  Future<Directory> assetDirectory(String documentId) async => directory;

  @override
  Future<void> delete(String documentId) async {}

  @override
  Future<List<DocumentSummary>> list() async => const <DocumentSummary>[];

  @override
  Future<WhiteboardDocument?> load(String documentId) async => null;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => null;

  @override
  Future<void> save(WhiteboardDocument document) async {}
}
