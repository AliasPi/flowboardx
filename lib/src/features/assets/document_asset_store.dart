import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../data/document_repository.dart';
import '../../domain/model/document.dart';
import '../board/presentation/board_object_layer.dart';

class DocumentAssetStore {
  DocumentAssetStore(this.repository, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final DocumentRepository repository;
  final Uuid _uuid;

  Future<DocumentAsset> importFile({
    required String documentId,
    required String sourcePath,
    required DocumentAssetType type,
    required String mimeType,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('Quelldatei fehlt', sourcePath);
    }
    final sourceLength = await source.length();
    final maximumLength = switch (type) {
      DocumentAssetType.image => 100 * 1024 * 1024,
      DocumentAssetType.pdf => 1024 * 1024 * 1024,
      DocumentAssetType.thumbnail => 25 * 1024 * 1024,
      DocumentAssetType.other => 256 * 1024 * 1024,
    };
    if (sourceLength <= 0 || sourceLength > maximumLength) {
      throw FormatException(
        'Die Datei ist leer oder überschreitet das Importlimit '
        'von ${maximumLength ~/ (1024 * 1024)} MB.',
      );
    }
    final directory = await repository.assetDirectory(documentId);
    final id = _uuid.v4();
    final extension = _safeExtension(sourcePath);
    final fileName = extension.isEmpty ? id : '$id$extension';
    final target = File(p.join(directory.path, fileName));
    final temporary = File('${target.path}.importing');
    try {
      await source.openRead().pipe(temporary.openWrite());
      final byteLength = await temporary.length();
      final digest = await sha256.bind(temporary.openRead()).first;
      await temporary.rename(target.path);
      return DocumentAsset(
        id: id,
        type: type,
        relativePath: fileName,
        mimeType: mimeType,
        originalFileName: p.basename(sourcePath),
        byteLength: byteLength,
        sha256: digest.toString(),
      );
    } catch (_) {
      if (await temporary.exists()) {
        await temporary.delete().catchError((_) => temporary);
      }
      rethrow;
    }
  }

  Future<DocumentAsset> importBytes({
    required String documentId,
    required Uint8List bytes,
    required String fileName,
    required DocumentAssetType type,
    required String mimeType,
  }) async {
    if (bytes.isEmpty) {
      throw const FormatException(
        'Eine leere Datei kann nicht importiert werden.',
      );
    }
    final directory = await repository.assetDirectory(documentId);
    final id = _uuid.v4();
    final extension = _safeExtension(fileName);
    final storedName = extension.isEmpty ? id : '$id$extension';
    final target = File(p.join(directory.path, storedName));
    final temporary = File('${target.path}.importing');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
      return DocumentAsset(
        id: id,
        type: type,
        relativePath: storedName,
        mimeType: mimeType,
        originalFileName: p.basename(fileName),
        byteLength: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      );
    } catch (_) {
      if (await temporary.exists()) {
        await temporary.delete().catchError((_) => temporary);
      }
      rethrow;
    }
  }

  /// Removes a freshly materialized asset that was never committed to the
  /// document. The normalized containment check makes rollback safe even for
  /// corrupt metadata and must never reach outside this document's asset
  /// directory.
  Future<void> discardImportedAsset({
    required String documentId,
    required DocumentAsset asset,
  }) async {
    if (asset.relativePath.isEmpty || p.isAbsolute(asset.relativePath)) return;
    final directory = await repository.assetDirectory(documentId);
    final root = p.normalize(p.absolute(directory.path));
    final targetPath = p.normalize(
      p.absolute(p.join(root, asset.relativePath)),
    );
    if (!p.isWithin(root, targetPath)) return;
    final target = File(targetPath);
    if (await target.exists()) await target.delete();
    final temporary = File('$targetPath.importing');
    if (await temporary.exists()) await temporary.delete();
  }

  String _safeExtension(String fileName) {
    final extension = p.extension(fileName).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension) ? extension : '';
  }
}

class FileBoardAssetResolver implements BoardAssetResolver {
  FileBoardAssetResolver({
    required this.directory,
    required WhiteboardDocument document,
  }) : _assets = {for (final asset in document.assets) asset.id: asset};

  final Directory directory;
  final Map<String, DocumentAsset> _assets;

  @override
  Future<Uint8List?> readBytes(String assetId) async {
    final path = localPath(assetId);
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  String? localPath(String assetId) {
    final asset = _assets[assetId];
    if (asset == null || p.isAbsolute(asset.relativePath)) return null;
    final path = p.normalize(p.join(directory.path, asset.relativePath));
    if (!p.isWithin(directory.path, path) &&
        !p.equals(directory.path, p.dirname(path))) {
      return null;
    }
    return path;
  }
}
