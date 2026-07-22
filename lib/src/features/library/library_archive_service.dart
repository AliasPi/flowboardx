import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/document_repository.dart';
import '../../domain/serialization/document_codec.dart';

typedef LibraryTemporaryDirectoryProvider = Future<Directory> Function();
typedef LibrarySystemShare =
    Future<ShareResult> Function(File archive, Rect? shareOrigin);
typedef LibraryArchiveSaveDestination =
    Future<String?> Function(String suggestedFileName);

/// Produces portable ZIP bundles containing complete Flowboard documents and
/// their assets, then hands the bundle to the native platform share sheet.
/// Every archive path includes the stable document ID, so equal display names
/// can never overwrite one another.
final class LibraryArchiveService {
  LibraryArchiveService({
    required this.repository,
    this.codec = const DocumentCodec(prettyPrint: true),
    LibraryTemporaryDirectoryProvider? temporaryDirectoryProvider,
    LibrarySystemShare? systemShare,
    LibraryArchiveSaveDestination? saveDestination,
    DateTime Function()? clock,
  }) : _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory,
       _systemShare = systemShare ?? _shareWithPlatform,
       _saveDestination = saveDestination ?? _pickArchiveDestination,
       _clock = clock ?? DateTime.now;

  final DocumentRepository repository;
  final DocumentCodec codec;
  final LibraryTemporaryDirectoryProvider _temporaryDirectoryProvider;
  final LibrarySystemShare _systemShare;
  final LibraryArchiveSaveDestination _saveDestination;
  final DateTime Function() _clock;

  Future<File> createArchive({
    required Iterable<String> documentIds,
    String? collectionName,
  }) async {
    final ids = documentIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) {
      throw const DocumentStorageException(
        'Es wurden keine Dokumente zum Teilen ausgewählt.',
      );
    }
    final outputRoot = await _temporaryDirectoryProvider();
    await outputRoot.create(recursive: true);
    final exportRoot = Directory(p.join(outputRoot.path, 'FlowboardX-Exporte'));
    await exportRoot.create(recursive: true);
    final staging = await exportRoot.createTemp('bundle-');
    File? archive;
    try {
      final manifestDocuments = <Map<String, Object?>>[];
      for (var index = 0; index < ids.length; index++) {
        final id = ids[index];
        var document = await repository.load(id);
        document ??= await repository.recover(id);
        if (document == null) {
          throw DocumentStorageException(
            'Das Dokument $id wurde nicht gefunden und nicht exportiert.',
          );
        }
        final entryName = _uniqueDocumentDirectoryName(
          index: index,
          title: document.title,
          id: document.id,
        );
        final destination = Directory(p.join(staging.path, entryName));
        await destination.create(recursive: true);
        await File(
          p.join(destination.path, 'document.flowboard.json'),
        ).writeAsString(codec.encode(document), flush: true);
        final assets = await repository.assetDirectory(document.id);
        if (await assets.exists()) {
          await _copyDirectoryContents(
            assets,
            Directory(p.join(destination.path, 'assets')),
          );
        }
        manifestDocuments.add(<String, Object?>{
          'id': document.id,
          'title': document.title,
          'path': entryName,
          'revision': document.revision,
          'updatedAt': document.updatedAt.toUtc().toIso8601String(),
        });
      }
      final exportedAt = _clock().toUtc();
      await File(p.join(staging.path, 'flowboard-bundle.json')).writeAsString(
        jsonEncode(<String, Object?>{
          'bundleVersion': 1,
          'collectionName': collectionName?.trim(),
          'exportedAt': exportedAt.toIso8601String(),
          'documents': manifestDocuments,
        }),
        flush: true,
      );
      archive = await _uniqueArchiveFile(
        exportRoot,
        _archiveBaseName(collectionName, ids.length),
        exportedAt,
      );
      await ZipFileEncoder().zipDirectory(
        staging,
        filename: archive.path,
        level: ZipFileEncoder.gzip,
        followLinks: false,
      );
      if (!await archive.exists() || await archive.length() == 0) {
        throw const DocumentStorageException(
          'Das ZIP-Archiv konnte nicht fertiggestellt werden.',
        );
      }
      return archive;
    } catch (error) {
      if (archive != null && await archive.exists()) await archive.delete();
      if (error is DocumentStorageException) rethrow;
      throw DocumentStorageException(
        'Die ausgewählten Dokumente konnten nicht gepackt werden.',
        cause: error,
      );
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<ShareResult> shareArchive(File archive, {Rect? shareOrigin}) async {
    if (!await archive.exists()) {
      throw const DocumentStorageException(
        'Das freizugebende ZIP-Archiv wurde nicht gefunden.',
      );
    }
    try {
      final result = await _systemShare(archive, shareOrigin);
      if (result.status == ShareResultStatus.unavailable) {
        throw const DocumentStorageException(
          'Quick Share/Systemfreigabe ist auf diesem Gerät nicht verfügbar.',
        );
      }
      return result;
    } catch (error) {
      if (error is DocumentStorageException) rethrow;
      throw DocumentStorageException(
        'Die Systemfreigabe ist auf diesem Gerät nicht verfügbar.',
        cause: error,
      );
    }
  }

  /// Copies a completed archive to a location explicitly chosen by the user.
  /// Returning `null` means the native save picker was cancelled.
  Future<File?> saveArchiveLocally(File archive) async {
    if (!await archive.exists() || await archive.length() == 0) {
      throw const DocumentStorageException(
        'Das zu speichernde ZIP-Archiv wurde nicht gefunden.',
      );
    }
    try {
      final suggestedName = p.basename(archive.path);
      var destination = await _saveDestination(suggestedName);
      if (destination == null) return null;
      destination = destination.trim();
      if (destination.isEmpty) return null;
      if (!destination.toLowerCase().endsWith('.zip')) {
        destination = '$destination.zip';
      }
      final output = File(destination);
      await output.parent.create(recursive: true);
      if (p.equals(p.absolute(output.path), p.absolute(archive.path))) {
        return archive;
      }
      await archive.copy(output.path);
      if (!await output.exists() || await output.length() == 0) {
        throw const FileSystemException(
          'Das ZIP-Archiv wurde nicht gespeichert.',
        );
      }
      return output;
    } catch (error) {
      if (error is DocumentStorageException) rethrow;
      throw DocumentStorageException(
        'Das ZIP-Archiv konnte nicht lokal gespeichert werden.',
        cause: error,
      );
    }
  }

  Future<ShareResult> createAndShare({
    required Iterable<String> documentIds,
    String? collectionName,
    Rect? shareOrigin,
  }) async {
    final archive = await createArchive(
      documentIds: documentIds,
      collectionName: collectionName,
    );
    return shareArchive(archive, shareOrigin: shareOrigin);
  }
}

Future<ShareResult> _shareWithPlatform(File archive, Rect? shareOrigin) =>
    SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(archive.path, mimeType: 'application/zip')],
        title: 'Flowboard-X-Dokumente teilen',
        subject: 'Flowboard-X-Dokumente',
        sharePositionOrigin: shareOrigin,
      ),
    );

Future<String?> _pickArchiveDestination(String suggestedFileName) =>
    FilePicker.saveFile(
      dialogTitle: 'Flowboard-ZIP speichern',
      fileName: suggestedFileName,
      type: FileType.custom,
      allowedExtensions: const <String>['zip'],
    );

Future<void> _copyDirectoryContents(
  Directory source,
  Directory destination,
) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    if (entity is Link) continue;
    final relative = p.relative(entity.path, from: source.path);
    if (relative == '.' || relative.startsWith('..${p.separator}')) continue;
    final targetPath = p.join(destination.path, relative);
    if (entity is Directory) {
      await Directory(targetPath).create(recursive: true);
    } else if (entity is File) {
      await File(targetPath).parent.create(recursive: true);
      await entity.copy(targetPath);
    }
  }
}

String _uniqueDocumentDirectoryName({
  required int index,
  required String title,
  required String id,
}) {
  final position = (index + 1).toString().padLeft(3, '0');
  final safeTitle = _safeFilePart(title, fallback: 'Whiteboard');
  final safeId = _safeFilePart(id, fallback: 'document');
  return '$position-$safeTitle--$safeId';
}

String _archiveBaseName(String? collectionName, int documentCount) {
  final name = collectionName?.trim();
  if (name != null && name.isNotEmpty) {
    return _safeFilePart(name, fallback: 'Flowboard-Ordner');
  }
  return documentCount == 1
      ? 'Flowboard-Dokument'
      : 'Flowboard-Dokumente-$documentCount';
}

Future<File> _uniqueArchiveFile(
  Directory directory,
  String baseName,
  DateTime timestamp,
) async {
  final stamp = timestamp
      .toIso8601String()
      .replaceAll(RegExp(r'[-:]'), '')
      .replaceAll('.', '-')
      .replaceAll('Z', '');
  for (var suffix = 0; suffix < 10000; suffix++) {
    final extra = suffix == 0 ? '' : '-$suffix';
    final candidate = File(
      p.join(directory.path, '$baseName-$stamp$extra.zip'),
    );
    if (!await candidate.exists()) return candidate;
  }
  throw const DocumentStorageException(
    'Für das ZIP-Archiv konnte kein freier Dateiname gefunden werden.',
  );
}

String _safeFilePart(String value, {required String fallback}) {
  var result = value
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '-')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (result.isEmpty) result = fallback;
  const reserved = <String>{
    'con',
    'prn',
    'aux',
    'nul',
    'com1',
    'com2',
    'com3',
    'com4',
    'com5',
    'com6',
    'com7',
    'com8',
    'com9',
    'lpt1',
    'lpt2',
    'lpt3',
    'lpt4',
    'lpt5',
    'lpt6',
    'lpt7',
    'lpt8',
    'lpt9',
  };
  if (reserved.contains(result.toLowerCase())) result = '_$result';
  if (result.length > 72) result = result.substring(0, 72).trimRight();
  return result;
}
