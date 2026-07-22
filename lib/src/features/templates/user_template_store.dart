import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../domain/model/board_object.dart';
import '../../domain/model/document.dart';
import 'user_template.dart';

typedef UserTemplateClock = DateTime Function();
typedef UserTemplateUuid = String Function();

/// Result of copying a user template into a destination document.
///
/// The caller adds [assets] and [page] to one document command. If that commit
/// fails, [rollbackFiles] removes only files created by this materialization.
final class UserTemplateMaterialization {
  UserTemplateMaterialization({
    required this.page,
    required Iterable<DocumentAsset> assets,
    required Iterable<File> createdFiles,
  }) : assets = List<DocumentAsset>.unmodifiable(assets),
       _createdFiles = List<File>.unmodifiable(createdFiles);

  final BoardPage page;
  final List<DocumentAsset> assets;
  final List<File> _createdFiles;

  Future<void> rollbackFiles() async {
    for (final file in _createdFiles.reversed) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // A cleanup failure must not hide the document commit failure.
      }
    }
  }
}

/// Persistent, application-global storage for user-created page templates.
///
/// JSON metadata and the independent asset directory live below [directory].
/// Large image/PDF data is streamed between files and never encoded as Base64.
/// A single store instance should be shared so read-modify-write operations are
/// serialized with template deletion and materialization.
final class UserTemplateStore {
  UserTemplateStore({
    required this.directory,
    UserTemplateClock? clock,
    UserTemplateUuid? uuid,
    this.useBackgroundIsolate = true,
  }) : _clock = clock ?? _systemClock,
       _uuid = uuid ?? _systemUuid;

  static const formatIdentifier = 'flowboard-x-user-templates';
  static const formatVersion = 2;
  static const _legacyFormatVersion = 1;

  final Directory directory;
  final bool useBackgroundIsolate;
  final UserTemplateClock _clock;
  final UserTemplateUuid _uuid;

  Future<void> _lock = Future<void>.value();
  int _temporaryCounter = 0;

  File get primaryFile =>
      File(path.join(directory.path, 'user_templates.flowboard.json'));

  File get backupFile =>
      File(path.join(directory.path, 'user_templates.flowboard.backup.json'));

  Directory get assetRootDirectory =>
      Directory(path.join(directory.path, 'user_template_assets'));

  /// The private asset directory for [templateId]. The id itself is hashed so
  /// imported/corrupt metadata can never escape [assetRootDirectory].
  Directory templateAssetDirectory(String templateId) => Directory(
    path.join(assetRootDirectory.path, _templateFolderName(templateId)),
  );

  Future<List<UserTemplate>> load() => _withLock(() async {
    final snapshot = await _loadSnapshotUnlocked();
    return List<UserTemplate>.unmodifiable(snapshot.templates);
  });

  /// Saves [page] as a new, document-independent template.
  ///
  /// If the page contains images/PDFs, [sourceAssets] and
  /// [sourceAssetDirectory] must describe their source files. Every referenced
  /// file is copied, measured and hashed before metadata is committed.
  Future<UserTemplate> save({
    required String name,
    required BoardPage page,
    Iterable<DocumentAsset> sourceAssets = const [],
    Directory? sourceAssetDirectory,
  }) => _withLock(() async {
    Directory? stagedDirectory;
    Directory? promotedDirectory;
    try {
      final normalizedName = normalizeUserTemplateName(name);
      final current = await _loadSnapshotUnlocked();
      final id = await _createUniqueTemplateId(
        current.templates.map((template) => template.id).toSet(),
      );
      final createdAt = _clock().toUtc();
      final copied = await _snapshotAssets(
        templateId: id,
        page: page,
        sourceAssets: sourceAssets,
        sourceDirectory: sourceAssetDirectory,
        createdAt: createdAt,
      );
      stagedDirectory = copied.stagedDirectory;

      final template = UserTemplate(
        id: id,
        name: normalizedName,
        createdAt: createdAt,
        page: rebindUserTemplateAssetIds(
          page.copyWith(id: 'user-template-$id-page', name: normalizedName),
          copied.assetIdMap,
        ),
        assets: copied.assets,
      );

      if (stagedDirectory != null) {
        final destination = templateAssetDirectory(id);
        if (await destination.exists()) {
          throw FileSystemException(
            'Vorlagen-Assetverzeichnis existiert bereits',
            destination.path,
          );
        }
        promotedDirectory = await stagedDirectory.rename(destination.path);
        stagedDirectory = null;
      }

      final next = _UserTemplateSnapshot(
        updatedAt: createdAt,
        templates: [template, ...current.templates],
      );
      await _writeSnapshotUnlocked(next);
      promotedDirectory = null;
      await _cleanupOrphanedAssetsUnlocked(next);
      return template;
    } on UserTemplateStorageException {
      rethrow;
    } on ArgumentError {
      rethrow;
    } catch (error) {
      throw UserTemplateStorageException(
        'Die Nutzervorlage konnte nicht gespeichert werden.',
        cause: error,
      );
    } finally {
      await _deleteDirectoryBestEffort(stagedDirectory);
      await _deleteDirectoryBestEffort(promotedDirectory);
    }
  });

  /// Copies and verifies a stored template's files into a document asset
  /// directory and returns a page whose image/PDF ids reference fresh assets.
  Future<UserTemplateMaterialization> materialize({
    required String templateId,
    required Directory targetAssetDirectory,
    required Iterable<String> existingDocumentAssetIds,
    required String pageId,
    required String pageName,
  }) => _withLock(() async {
    final createdFiles = <File>[];
    final temporaryFiles = <File>[];
    try {
      final current = await _loadSnapshotUnlocked();
      final template = current.templates
          .where((candidate) => candidate.id == templateId)
          .firstOrNull;
      if (template == null) {
        throw StateError('Die Nutzervorlage wurde nicht gefunden.');
      }
      await targetAssetDirectory.create(recursive: true);
      final usedIds = existingDocumentAssetIds.toSet();
      final reboundIds = <String, String>{};
      final documentAssets = <DocumentAsset>[];

      for (final templateAsset in template.assets) {
        final source = _templateAssetFile(template, templateAsset);
        final newId = _createUniqueId(usedIds);
        usedIds.add(newId);
        final extension = _safeExtension(templateAsset.relativePath);
        final storedName = extension.isEmpty ? newId : '$newId$extension';
        final target = File(path.join(targetAssetDirectory.path, storedName));
        if (await target.exists()) {
          throw FileSystemException(
            'Ziel-Asset existiert bereits',
            target.path,
          );
        }
        final temporary = File(
          '${target.path}.importing.$pid.${_temporaryCounter++}',
        );
        temporaryFiles.add(temporary);
        await source.openRead().pipe(temporary.openWrite());
        final length = await temporary.length();
        final digest = await _fileSha256(temporary);
        if (length != templateAsset.byteLength ||
            digest != templateAsset.sha256) {
          throw const FormatException(
            'Ein Vorlagen-Asset ist beschädigt oder unvollständig.',
          );
        }
        await temporary.rename(target.path);
        temporaryFiles.remove(temporary);
        createdFiles.add(target);
        reboundIds[templateAsset.id] = newId;
        documentAssets.add(
          DocumentAsset(
            id: newId,
            type: templateAsset.type,
            relativePath: storedName,
            mimeType: templateAsset.mimeType,
            originalFileName: templateAsset.originalFileName,
            byteLength: length,
            sha256: digest,
            createdAt: _clock().toUtc(),
          ),
        );
      }

      return UserTemplateMaterialization(
        page: template.createPage(
          pageId: pageId,
          pageName: pageName,
          assetIdMap: reboundIds,
        ),
        assets: documentAssets,
        createdFiles: createdFiles,
      );
    } on UserTemplateStorageException {
      rethrow;
    } catch (error) {
      for (final file in [...temporaryFiles, ...createdFiles].reversed) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          // Best effort; the typed error below remains the useful failure.
        }
      }
      throw UserTemplateStorageException(
        'Die Nutzervorlage konnte nicht eingefügt werden.',
        cause: error,
      );
    }
  });

  /// Deletes exactly one template by id and reports whether it existed.
  Future<bool> delete(String id) => _withLock(() async {
    try {
      final normalizedId = id.trim();
      if (normalizedId.isEmpty) {
        throw ArgumentError.value(id, 'id', 'darf nicht leer sein');
      }
      final current = await _loadSnapshotUnlocked();
      final retained = current.templates
          .where((template) => template.id != normalizedId)
          .toList(growable: false);
      if (retained.length == current.templates.length) return false;

      final next = _UserTemplateSnapshot(
        updatedAt: _clock().toUtc(),
        templates: retained,
      );
      await _writeSnapshotUnlocked(next);

      // Mirroring after the successful primary commit lets normal deletion
      // reclaim files immediately while still leaving a valid recovery copy.
      // If mirroring fails, cleanup protects assets referenced by the old
      // backup and a later successful write can collect them.
      try {
        await _replaceAtomically(backupFile, await primaryFile.readAsString());
      } catch (_) {
        // Primary metadata already committed; preserving the old backup is safe.
      }
      await _cleanupOrphanedAssetsUnlocked(next);
      return true;
    } on UserTemplateStorageException {
      rethrow;
    } on ArgumentError {
      rethrow;
    } catch (error) {
      throw UserTemplateStorageException(
        'Die Nutzervorlage konnte nicht gelöscht werden.',
        cause: error,
      );
    }
  });

  Future<_UserTemplateSnapshot> _loadSnapshotUnlocked() async {
    Object? primaryFailure;
    if (await primaryFile.exists()) {
      try {
        final decoded = await _readSnapshot(primaryFile);
        await _validateSnapshotAssets(decoded.snapshot);
        await _cleanupOrphanedAssetsUnlocked(decoded.snapshot);
        return decoded.snapshot;
      } catch (error) {
        primaryFailure = error;
      }
    }

    Object? backupFailure;
    if (await backupFile.exists()) {
      try {
        final recovered = await _readSnapshot(backupFile);
        await _validateSnapshotAssets(recovered.snapshot);
        // Do not rotate a corrupt primary over the last known-good backup.
        await _replaceAtomically(primaryFile, recovered.source);
        await _cleanupOrphanedAssetsUnlocked(recovered.snapshot);
        return recovered.snapshot;
      } catch (error) {
        backupFailure = error;
      }
    }

    if (primaryFailure == null && backupFailure == null) {
      final empty = _UserTemplateSnapshot.empty();
      await _cleanupOrphanedAssetsUnlocked(empty);
      return empty;
    }
    throw UserTemplateStorageException(
      'Nutzervorlagen konnten weder aus der Hauptdatei noch aus der '
      'Sicherung wiederhergestellt werden.',
      cause: _UserTemplateRecoveryFailure(
        primary: primaryFailure,
        backup: backupFailure,
      ),
    );
  }

  Future<_DecodedUserTemplateSnapshot> _readSnapshot(File file) async {
    final source = await file.readAsString();
    final snapshot = useBackgroundIsolate
        ? await Isolate.run(() => _decodeSnapshot(source))
        : _decodeSnapshot(source);
    return _DecodedUserTemplateSnapshot(source: source, snapshot: snapshot);
  }

  Future<void> _writeSnapshotUnlocked(_UserTemplateSnapshot snapshot) async {
    final contents = useBackgroundIsolate
        ? await Isolate.run(() => _encodeSnapshot(snapshot))
        : _encodeSnapshot(snapshot);
    await _replaceAtomically(primaryFile, contents, backup: backupFile);
  }

  Future<_CopiedTemplateAssets> _snapshotAssets({
    required String templateId,
    required BoardPage page,
    required Iterable<DocumentAsset> sourceAssets,
    required Directory? sourceDirectory,
    required DateTime createdAt,
  }) async {
    final referencedIds = <String>{};
    for (final object in page.objects) {
      switch (object) {
        case final ImageObject image:
          referencedIds.add(image.assetId);
        case final PdfObject pdf:
          referencedIds.add(pdf.assetId);
        default:
          break;
      }
    }
    if (referencedIds.isEmpty) return const _CopiedTemplateAssets.empty();
    if (sourceDirectory == null) {
      throw const FormatException(
        'Bild-/PDF-Dateien benötigen ihr Quelldokumentverzeichnis.',
      );
    }

    final sourceById = <String, DocumentAsset>{};
    for (final asset in sourceAssets) {
      if (sourceById.containsKey(asset.id)) {
        throw FormatException('Doppelte Quell-Asset-ID: ${asset.id}');
      }
      sourceById[asset.id] = asset;
    }
    final missing = referencedIds.where((id) => !sourceById.containsKey(id));
    if (missing.isNotEmpty) {
      throw FormatException('Quell-Asset fehlt: ${missing.join(', ')}');
    }

    await assetRootDirectory.create(recursive: true);
    final staging = Directory(
      path.join(
        assetRootDirectory.path,
        '.staging-${_templateFolderName(templateId)}.$pid.'
        '${_temporaryCounter++}',
      ),
    );
    await staging.create();
    final snapshots = <UserTemplateAsset>[];
    final reboundIds = <String, String>{};
    try {
      var index = 0;
      for (final sourceId in referencedIds) {
        final sourceAsset = sourceById[sourceId]!;
        final source = _resolveSourceFile(sourceDirectory, sourceAsset);
        if (!await source.exists()) {
          throw FileSystemException('Quell-Asset fehlt', source.path);
        }
        final sourceLength = await source.length();
        final maximumLength = _maximumLength(sourceAsset.type);
        if (sourceLength <= 0 || sourceLength > maximumLength) {
          throw FormatException(
            'Das Quell-Asset ist leer oder überschreitet das Importlimit.',
          );
        }
        final temporary = File(path.join(staging.path, 'asset-$index.part'));
        await source.openRead().pipe(temporary.openWrite());
        final copiedLength = await temporary.length();
        final digest = await _fileSha256(temporary);
        if (copiedLength != sourceLength ||
            (sourceAsset.byteLength != null &&
                sourceAsset.byteLength != copiedLength) ||
            (sourceAsset.sha256 != null &&
                sourceAsset.sha256!.toLowerCase() != digest)) {
          throw const FormatException(
            'Die Quelldatei stimmt nicht mit ihren Asset-Metadaten überein.',
          );
        }
        final extension = _safeExtension(
          sourceAsset.relativePath.isEmpty
              ? sourceAsset.originalFileName ?? ''
              : sourceAsset.relativePath,
        );
        final storedName = extension.isEmpty ? digest : '$digest$extension';
        final storedFile = File(path.join(staging.path, storedName));
        if (await storedFile.exists()) {
          await temporary.delete();
        } else {
          await temporary.rename(storedFile.path);
        }
        final templateAssetId = 'asset-${index + 1}-${digest.substring(0, 12)}';
        reboundIds[sourceId] = templateAssetId;
        snapshots.add(
          UserTemplateAsset(
            id: templateAssetId,
            type: sourceAsset.type,
            relativePath: storedName,
            mimeType: sourceAsset.mimeType,
            originalFileName: sourceAsset.originalFileName,
            byteLength: copiedLength,
            sha256: digest,
            createdAt: createdAt,
          ),
        );
        index++;
      }
      return _CopiedTemplateAssets(
        assets: snapshots,
        assetIdMap: reboundIds,
        stagedDirectory: staging,
      );
    } catch (_) {
      await _deleteDirectoryBestEffort(staging);
      rethrow;
    }
  }

  File _resolveSourceFile(Directory sourceDirectory, DocumentAsset asset) {
    if (path.isAbsolute(asset.relativePath)) {
      throw const FormatException('Absolute Assetpfade sind nicht erlaubt.');
    }
    final root = path.normalize(path.absolute(sourceDirectory.path));
    final candidate = path.normalize(path.absolute(root, asset.relativePath));
    if (!path.isWithin(root, candidate)) {
      throw const FormatException('Assetpfad verlässt das Quelldokument.');
    }
    return File(candidate);
  }

  File _templateAssetFile(UserTemplate template, UserTemplateAsset asset) {
    final root = path.normalize(
      path.absolute(templateAssetDirectory(template.id).path),
    );
    final candidate = path.normalize(path.absolute(root, asset.relativePath));
    if (!path.isWithin(root, candidate)) {
      throw const FormatException('Ungültiger Vorlagen-Assetpfad.');
    }
    return File(candidate);
  }

  Future<void> _validateSnapshotAssets(_UserTemplateSnapshot snapshot) async {
    for (final template in snapshot.templates) {
      for (final asset in template.assets) {
        final file = _templateAssetFile(template, asset);
        if (!await file.exists() || await file.length() != asset.byteLength) {
          throw FormatException(
            'Asset ${asset.id} der Vorlage ${template.id} fehlt oder ist '
            'unvollständig.',
          );
        }
      }
    }
  }

  Future<void> _cleanupOrphanedAssetsUnlocked(
    _UserTemplateSnapshot primary,
  ) async {
    try {
      if (!await assetRootDirectory.exists()) return;
      final protectedTemplateIds = primary.templates
          .map((template) => template.id)
          .toSet();
      if (await backupFile.exists()) {
        try {
          final backup = await _readSnapshot(backupFile);
          protectedTemplateIds.addAll(
            backup.snapshot.templates.map((template) => template.id),
          );
        } catch (_) {
          // A corrupt backup protects nothing; the valid primary remains.
        }
      }
      final protectedFolders = protectedTemplateIds
          .map(_templateFolderName)
          .toSet();
      await for (final entity in assetRootDirectory.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = path.basename(entity.path);
        final ownedFinalFolder = RegExp(r'^[a-f0-9]{64}$').hasMatch(name);
        final ownedStagingFolder = name.startsWith('.staging-');
        if ((ownedFinalFolder && !protectedFolders.contains(name)) ||
            ownedStagingFolder) {
          await _deleteDirectoryBestEffort(entity);
        }
      }
    } catch (_) {
      // Cleanup is maintenance. A read-only or temporarily unavailable file
      // system must not invalidate an otherwise healthy template snapshot.
    }
  }

  Future<void> _replaceAtomically(
    File target,
    String contents, {
    File? backup,
  }) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp.$pid.${_temporaryCounter++}');
    await temporary.writeAsString(contents, flush: true);

    var targetMoved = false;
    try {
      if (await target.exists()) {
        if (backup == null) {
          await target.delete();
        } else {
          if (await backup.exists()) await backup.delete();
          await target.rename(backup.path);
          targetMoved = true;
        }
      }
      await temporary.rename(target.path);
    } catch (_) {
      if (targetMoved &&
          backup != null &&
          await backup.exists() &&
          !await target.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {
        // A stale temp file is harmless and must not hide the original error.
      }
    }
  }

  Future<String> _createUniqueTemplateId(Set<String> existingIds) async {
    for (var attempt = 0; attempt < 32; attempt++) {
      final candidate = _uuid().trim();
      if (_isSafeGeneratedId(candidate) &&
          !existingIds.contains(candidate) &&
          !await templateAssetDirectory(candidate).exists()) {
        return candidate;
      }
    }
    throw StateError(
      'Nach 32 Versuchen konnte keine eindeutige Vorlagen-ID erzeugt werden.',
    );
  }

  String _createUniqueId(Set<String> existingIds) {
    for (var attempt = 0; attempt < 32; attempt++) {
      final candidate = _uuid().trim();
      if (_isSafeGeneratedId(candidate) && !existingIds.contains(candidate)) {
        return candidate;
      }
    }
    throw StateError(
      'Nach 32 Versuchen konnte keine eindeutige Asset-ID erzeugt werden.',
    );
  }

  Future<String> _fileSha256(File file) {
    if (!useBackgroundIsolate) return _sha256FileAtPath(file.path);
    final filePath = file.path;
    return Isolate.run(() => _sha256FileAtPath(filePath));
  }

  Future<T> _withLock<T>(Future<T> Function() operation) async {
    final previous = _lock;
    final release = Completer<void>();
    _lock = release.future;
    try {
      try {
        await previous;
      } catch (_) {
        // A failed operation must not poison subsequent store operations.
      }
      return await operation();
    } finally {
      release.complete();
    }
  }
}

final class UserTemplateStorageException implements Exception {
  const UserTemplateStorageException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message ($cause)';
}

final class _CopiedTemplateAssets {
  const _CopiedTemplateAssets({
    required this.assets,
    required this.assetIdMap,
    required this.stagedDirectory,
  });

  const _CopiedTemplateAssets.empty()
    : assets = const [],
      assetIdMap = const {},
      stagedDirectory = null;

  final List<UserTemplateAsset> assets;
  final Map<String, String> assetIdMap;
  final Directory? stagedDirectory;
}

final class _UserTemplateSnapshot {
  const _UserTemplateSnapshot({
    required this.updatedAt,
    required this.templates,
  });

  factory _UserTemplateSnapshot.empty() => _UserTemplateSnapshot(
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    templates: const [],
  );

  final DateTime updatedAt;
  final List<UserTemplate> templates;
}

final class _DecodedUserTemplateSnapshot {
  const _DecodedUserTemplateSnapshot({
    required this.source,
    required this.snapshot,
  });

  final String source;
  final _UserTemplateSnapshot snapshot;
}

final class _UserTemplateRecoveryFailure {
  const _UserTemplateRecoveryFailure({this.primary, this.backup});

  final Object? primary;
  final Object? backup;

  @override
  String toString() =>
      'primary: ${primary ?? 'nicht vorhanden'}, '
      'backup: ${backup ?? 'nicht vorhanden'}';
}

String _encodeSnapshot(_UserTemplateSnapshot snapshot) {
  final payload = <String, Object?>{
    'updatedAt': snapshot.updatedAt.toUtc().toIso8601String(),
    'templates': snapshot.templates
        .map((template) => template.toJson())
        .toList(growable: false),
  };
  final canonicalPayload = jsonEncode(payload);
  return const JsonEncoder.withIndent('  ').convert({
    'format': UserTemplateStore.formatIdentifier,
    'version': UserTemplateStore.formatVersion,
    'checksum': sha256.convert(utf8.encode(canonicalPayload)).toString(),
    'payload': payload,
  });
}

_UserTemplateSnapshot _decodeSnapshot(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('Die Wurzel der Vorlagendatei ist ungültig.');
  }
  final envelope = Map<String, Object?>.from(decoded);
  final version = envelope['version'];
  if (envelope['format'] != UserTemplateStore.formatIdentifier ||
      (version != UserTemplateStore.formatVersion &&
          version != UserTemplateStore._legacyFormatVersion)) {
    throw const FormatException('Das Vorlagendateiformat ist unbekannt.');
  }
  final rawPayload = envelope['payload'];
  if (rawPayload is! Map) {
    throw const FormatException('Der Inhalt der Vorlagendatei fehlt.');
  }
  final payload = Map<String, Object?>.from(rawPayload);
  final expectedChecksum = envelope['checksum'];
  final actualChecksum = sha256
      .convert(utf8.encode(jsonEncode(payload)))
      .toString();
  if (expectedChecksum is! String || expectedChecksum != actualChecksum) {
    throw const FormatException(
      'Die Prüfsumme der Vorlagendatei stimmt nicht überein.',
    );
  }

  final updatedAtValue = payload['updatedAt'];
  final updatedAt = updatedAtValue is String
      ? DateTime.tryParse(updatedAtValue)
      : null;
  if (updatedAt == null) {
    throw const FormatException('updatedAt der Vorlagendatei ist ungültig.');
  }
  final rawTemplates = payload['templates'];
  if (rawTemplates is! List) {
    throw const FormatException('Die Vorlagenliste fehlt.');
  }

  final templates = <UserTemplate>[];
  final ids = <String>{};
  for (final item in rawTemplates) {
    if (item is! Map) {
      throw const FormatException('Ein Vorlageneintrag ist ungültig.');
    }
    final template = UserTemplate.fromJson(Map<String, Object?>.from(item));
    if (!ids.add(template.id)) {
      throw FormatException('Doppelte Vorlagen-ID: ${template.id}');
    }
    templates.add(template);
  }
  return _UserTemplateSnapshot(
    updatedAt: updatedAt.toUtc(),
    templates: List<UserTemplate>.unmodifiable(templates),
  );
}

Future<String> _sha256FileAtPath(String filePath) async {
  final digest = await sha256.bind(File(filePath).openRead()).first;
  return digest.toString();
}

Future<void> _deleteDirectoryBestEffort(Directory? directory) async {
  if (directory == null) return;
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } catch (_) {
    // Orphan cleanup retries on the next successful store operation.
  }
}

int _maximumLength(DocumentAssetType type) => switch (type) {
  DocumentAssetType.image => 100 * 1024 * 1024,
  DocumentAssetType.pdf => 1024 * 1024 * 1024,
  DocumentAssetType.thumbnail => 25 * 1024 * 1024,
  DocumentAssetType.other => 256 * 1024 * 1024,
};

String _safeExtension(String fileName) {
  final extension = path.extension(fileName).toLowerCase();
  return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension) ? extension : '';
}

String _templateFolderName(String templateId) =>
    sha256.convert(utf8.encode(templateId)).toString();

bool _isSafeGeneratedId(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$').hasMatch(value);

DateTime _systemClock() => DateTime.now().toUtc();
String _systemUuid() => const Uuid().v4();
