import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../domain/model/document.dart';
import '../domain/model/library_organization.dart';
import '../domain/serialization/document_codec.dart';
import 'document_repository.dart';

final class FileDocumentRepository
    implements DocumentRepository, DocumentOrganizationRepository {
  FileDocumentRepository(
    this.root, {
    this.codec = const DocumentCodec(),
    this.useBackgroundIsolate = true,
  });

  final Directory root;
  final DocumentCodec codec;
  final bool useBackgroundIsolate;
  final Map<String, Future<void>> _locks = {};
  Future<void> _organizationLock = Future<void>.value();
  int _temporaryCounter = 0;

  Directory documentDirectory(String documentId) =>
      Directory(_join(root.path, 'documents', _safeDirectoryName(documentId)));

  File documentFileFor(String documentId) => File(
    _join(documentDirectory(documentId).path, 'document.flowboard.json'),
  );

  File backupFileFor(String documentId) => File(
    _join(documentDirectory(documentId).path, 'document.flowboard.backup.json'),
  );

  File journalFileFor(String documentId) => File(
    _join(
      documentDirectory(documentId).path,
      'document.flowboard.journal.json',
    ),
  );

  File get organizationFile =>
      File(_join(root.path, 'library.organization.json'));

  File get organizationBackupFile =>
      File(_join(root.path, 'library.organization.backup.json'));

  @override
  Future<LibraryOrganization> loadOrganization() =>
      _withOrganizationLock(() async {
        final primary = organizationFile;
        final backup = organizationBackupFile;
        if (!await primary.exists() && !await backup.exists()) {
          return LibraryOrganization.empty;
        }
        Object? primaryError;
        if (await primary.exists()) {
          try {
            return await _decodeOrganization(primary);
          } catch (error) {
            primaryError = error;
          }
        }
        if (await backup.exists()) {
          try {
            return await _decodeOrganization(backup);
          } catch (backupError) {
            throw DocumentStorageException(
              'Die Ordnerstruktur konnte nicht wiederhergestellt werden.',
              cause: <Object?>[primaryError, backupError],
            );
          }
        }
        throw DocumentStorageException(
          'Die Ordnerstruktur konnte nicht geladen werden.',
          cause: primaryError,
        );
      });

  @override
  Future<void> saveOrganization(LibraryOrganization organization) =>
      _withOrganizationLock(() async {
        final payload = jsonEncode(organization.normalized().toJson());
        await _replaceAtomically(
          organizationFile,
          payload,
          backup: organizationBackupFile,
        );
      });

  @override
  Future<Directory> assetDirectory(String documentId) async {
    final directory = Directory(
      _join(documentDirectory(documentId).path, 'assets'),
    );
    await directory.create(recursive: true);
    return directory;
  }

  @override
  Future<void> save(WhiteboardDocument document) =>
      _withLock(document.id, () => _saveUnlocked(document));

  @override
  Future<WhiteboardDocument?> load(
    String documentId,
  ) => _withLock(documentId, () async {
    final file = documentFileFor(documentId);
    if (!await file.exists()) return null;
    try {
      final document = await _decodeFile(file);
      _verifyIdentity(documentId, document);
      return document;
    } catch (error) {
      throw DocumentStorageException(
        'Dokument $documentId konnte nicht geladen werden. Verwende recover(), um Sicherungen zu prüfen.',
        cause: error,
      );
    }
  });

  @override
  Future<WhiteboardDocument?> recover(String documentId) => _withLock(
    documentId,
    () async {
      final directory = documentDirectory(documentId);
      if (!await directory.exists()) return null;
      final candidates = <_RecoveryCandidate>[];
      final errors = <Object>[];

      await _tryCandidate(
        candidates,
        errors,
        _RecoverySource.primary,
        documentFileFor(documentId),
        documentId,
      );
      await _tryJournalCandidate(
        candidates,
        errors,
        journalFileFor(documentId),
        documentId,
      );
      await _tryCandidate(
        candidates,
        errors,
        _RecoverySource.backup,
        backupFileFor(documentId),
        documentId,
      );

      if (candidates.isEmpty) {
        if (errors.isEmpty) return null;
        throw DocumentStorageException(
          'Keine intakte Version von $documentId gefunden.',
          cause: errors.first,
        );
      }
      candidates.sort(_compareRecoveryCandidates);
      final selected = candidates.first;
      final journal = journalFileFor(documentId);
      if (selected.source == _RecoverySource.primary) {
        if (await journal.exists()) await journal.delete();
        return selected.document;
      }

      final recovered = selected.document.copyWith(
        metadata: selected.document.metadata.copyWith(recoveredFromCrash: true),
      );
      await _saveUnlocked(recovered);
      return recovered;
    },
  );

  @override
  Future<List<DocumentSummary>> list() async {
    final documentsRoot = Directory(_join(root.path, 'documents'));
    if (!await documentsRoot.exists()) return const [];
    final summaries = <DocumentSummary>[];
    await for (final entity in documentsRoot.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final primary = File(_join(entity.path, 'document.flowboard.json'));
      final journal = File(
        _join(entity.path, 'document.flowboard.journal.json'),
      );
      final backup = File(_join(entity.path, 'document.flowboard.backup.json'));
      WhiteboardDocument? document;
      var recoveryAvailable = await journal.exists();
      try {
        if (await primary.exists()) document = await _decodeFile(primary);
      } catch (_) {
        recoveryAvailable = true;
      }
      if (document == null) {
        try {
          if (await journal.exists()) document = await _decodeJournal(journal);
        } catch (_) {
          // A corrupt journal is ignored here; recover() reports full details.
        }
      }
      if (document == null) {
        try {
          if (await backup.exists()) document = await _decodeFile(backup);
        } catch (_) {
          // Corrupt entries do not prevent the remaining overview from loading.
        }
      }
      if (document != null) {
        summaries.add(
          DocumentSummary.fromDocument(
            document,
            recoveryAvailable: recoveryAvailable,
          ),
        );
      }
    }
    summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(summaries);
  }

  @override
  Future<void> delete(String documentId) => _withLock(documentId, () async {
    final directory = documentDirectory(documentId);
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> _saveUnlocked(WhiteboardDocument document) async {
    final directory = documentDirectory(document.id);
    await directory.create(recursive: true);
    final payload = await _encode(document);
    final journalEnvelope = jsonEncode({
      'journalVersion': 1,
      'documentId': document.id,
      'revision': document.revision,
      'updatedAt': document.updatedAt.toIso8601String(),
      'checksum': _checksum(payload),
      'payload': payload,
    });
    final journal = journalFileFor(document.id);
    await _replaceAtomically(journal, journalEnvelope);
    await _replaceAtomically(
      documentFileFor(document.id),
      payload,
      backup: backupFileFor(document.id),
    );
    if (await journal.exists()) await journal.delete();
  }

  Future<void> _tryCandidate(
    List<_RecoveryCandidate> candidates,
    List<Object> errors,
    _RecoverySource source,
    File file,
    String documentId,
  ) async {
    if (!await file.exists()) return;
    try {
      final document = await _decodeFile(file);
      _verifyIdentity(documentId, document);
      candidates.add(_RecoveryCandidate(source, document));
    } catch (error) {
      errors.add(error);
    }
  }

  Future<void> _tryJournalCandidate(
    List<_RecoveryCandidate> candidates,
    List<Object> errors,
    File file,
    String documentId,
  ) async {
    if (!await file.exists()) return;
    try {
      final document = await _decodeJournal(file);
      _verifyIdentity(documentId, document);
      candidates.add(_RecoveryCandidate(_RecoverySource.journal, document));
    } catch (error) {
      errors.add(error);
    }
  }

  Future<String> _encode(WhiteboardDocument document) {
    if (!useBackgroundIsolate) return Future.value(codec.encode(document));
    final prettyPrint = codec.prettyPrint;
    return Isolate.run(
      () => DocumentCodec(prettyPrint: prettyPrint).encode(document),
    );
  }

  Future<WhiteboardDocument> _decodeFile(File file) async {
    final source = await file.readAsString();
    if (!useBackgroundIsolate) return codec.decode(source);
    final prettyPrint = codec.prettyPrint;
    return Isolate.run(
      () => DocumentCodec(prettyPrint: prettyPrint).decode(source),
    );
  }

  Future<WhiteboardDocument> _decodeJournal(File file) async {
    final source = await file.readAsString();
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Journalwurzel ist ungültig.');
    }
    final envelope = Map<String, Object?>.from(decoded);
    if (envelope['journalVersion'] != 1 || envelope['payload'] is! String) {
      throw const FormatException('Journalformat ist ungültig.');
    }
    final payload = envelope['payload']! as String;
    if (envelope['checksum'] != _checksum(payload)) {
      throw const FormatException('Journal-Prüfsumme stimmt nicht überein.');
    }
    if (!useBackgroundIsolate) return codec.decode(payload);
    final prettyPrint = codec.prettyPrint;
    return Isolate.run(
      () => DocumentCodec(prettyPrint: prettyPrint).decode(payload),
    );
  }

  Future<LibraryOrganization> _decodeOrganization(File file) async {
    final source = await file.readAsString();
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Der Bibliotheksindex ist ungültig.');
    }
    return LibraryOrganization.fromJson(Map<String, Object?>.from(decoded));
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
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<T> _withLock<T>(String documentId, Future<T> Function() action) async {
    final previous = _locks[documentId] ?? Future<void>.value();
    final release = Completer<void>();
    _locks[documentId] = release.future;
    try {
      try {
        await previous;
      } catch (_) {
        // A prior failed operation must not permanently poison this document lock.
      }
      return await action();
    } finally {
      release.complete();
      if (identical(_locks[documentId], release.future)) {
        _locks.remove(documentId);
      }
    }
  }

  Future<T> _withOrganizationLock<T>(Future<T> Function() action) async {
    final previous = _organizationLock;
    final release = Completer<void>();
    _organizationLock = release.future;
    try {
      try {
        await previous;
      } catch (_) {
        // A failed index write must not poison all later folder operations.
      }
      return await action();
    } finally {
      release.complete();
    }
  }

  void _verifyIdentity(String expectedId, WhiteboardDocument document) {
    if (document.id != expectedId) {
      throw FormatException(
        'Dokument-ID ${document.id} stimmt nicht mit $expectedId überein.',
      );
    }
  }
}

enum _RecoverySource { primary, journal, backup }

final class _RecoveryCandidate {
  const _RecoveryCandidate(this.source, this.document);

  final _RecoverySource source;
  final WhiteboardDocument document;
}

int _compareRecoveryCandidates(
  _RecoveryCandidate first,
  _RecoveryCandidate second,
) {
  final revision = second.document.revision.compareTo(first.document.revision);
  if (revision != 0) return revision;
  final updated = second.document.updatedAt.compareTo(first.document.updatedAt);
  if (updated != 0) return updated;
  const priority = {
    _RecoverySource.primary: 0,
    _RecoverySource.journal: 1,
    _RecoverySource.backup: 2,
  };
  return priority[first.source]!.compareTo(priority[second.source]!);
}

String _safeDirectoryName(String documentId) {
  if (documentId.trim().isEmpty) {
    throw ArgumentError.value(documentId, 'documentId', 'darf nicht leer sein');
  }
  return 'doc_${Uri.encodeComponent(documentId)}';
}

String _join(String first, [String? second, String? third]) {
  final separator = Platform.pathSeparator;
  var result = first.endsWith(separator)
      ? first.substring(0, first.length - 1)
      : first;
  for (final part in [second, third]) {
    if (part == null) continue;
    final normalized = part.startsWith(separator) ? part.substring(1) : part;
    result = '$result$separator$normalized';
  }
  return result;
}

String _checksum(String source) {
  var hash = 0x811C9DC5;
  for (final byte in utf8.encode(source)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
