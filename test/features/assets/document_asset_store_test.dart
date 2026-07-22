import 'dart:io';
import 'dart:typed_data';

import 'package:flowboard_x/src/data/file_document_repository.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/features/assets/document_asset_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('imports files with identical names without collisions', () async {
    final root = await Directory.systemTemp.createTemp('flowboard-assets-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final firstDirectory = Directory('${root.path}${Platform.pathSeparator}a');
    final secondDirectory = Directory('${root.path}${Platform.pathSeparator}b');
    await firstDirectory.create();
    await secondDirectory.create();
    final first = File(
      '${firstDirectory.path}${Platform.pathSeparator}gleich.png',
    );
    final second = File(
      '${secondDirectory.path}${Platform.pathSeparator}gleich.png',
    );
    await first.writeAsBytes(List<int>.filled(32, 1));
    await second.writeAsBytes(List<int>.filled(32, 2));
    final repository = FileDocumentRepository(
      Directory('${root.path}${Platform.pathSeparator}documents'),
    );
    final store = DocumentAssetStore(repository);

    final firstAsset = await store.importFile(
      documentId: 'doc',
      sourcePath: first.path,
      type: DocumentAssetType.image,
      mimeType: 'image/png',
    );
    final secondAsset = await store.importFile(
      documentId: 'doc',
      sourcePath: second.path,
      type: DocumentAssetType.image,
      mimeType: 'image/png',
    );

    expect(firstAsset.originalFileName, 'gleich.png');
    expect(secondAsset.originalFileName, 'gleich.png');
    expect(firstAsset.id, isNot(secondAsset.id));
    expect(firstAsset.relativePath, isNot(secondAsset.relativePath));
    final assets = await repository.assetDirectory('doc');
    expect(
      await File(
        '${assets.path}${Platform.pathSeparator}${firstAsset.relativePath}',
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        '${assets.path}${Platform.pathSeparator}${secondAsset.relativePath}',
      ).exists(),
      isTrue,
    );
  });

  test('discard removes only the uncommitted contained asset', () async {
    final root = await Directory.systemTemp.createTemp('flowboard-discard-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final repository = FileDocumentRepository(
      Directory(p.join(root.path, 'documents')),
    );
    final store = DocumentAssetStore(repository);
    final first = await store.importBytes(
      documentId: 'doc',
      bytes: Uint8List.fromList(const <int>[1, 2, 3]),
      fileName: 'first.png',
      type: DocumentAssetType.image,
      mimeType: 'image/png',
    );
    final second = await store.importBytes(
      documentId: 'doc',
      bytes: Uint8List.fromList(const <int>[4, 5, 6]),
      fileName: 'second.png',
      type: DocumentAssetType.image,
      mimeType: 'image/png',
    );
    final directory = await repository.assetDirectory('doc');

    await store.discardImportedAsset(documentId: 'doc', asset: first);

    expect(
      File(p.join(directory.path, first.relativePath)).existsSync(),
      false,
    );
    expect(
      File(p.join(directory.path, second.relativePath)).existsSync(),
      true,
    );

    final outside = File(p.join(root.path, 'outside.bin'));
    await outside.writeAsBytes(const <int>[9]);
    await store.discardImportedAsset(
      documentId: 'doc',
      asset: DocumentAsset(
        id: 'unsafe',
        type: DocumentAssetType.other,
        relativePath: p.join('..', '..', '..', 'outside.bin'),
        mimeType: 'application/octet-stream',
      ),
    );
    expect(outside.existsSync(), true);
  });
}
