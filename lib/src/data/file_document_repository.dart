import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../domain/model/document.dart';
import '../domain/model/library_organization.dart';
import '../domain/serialization/document_codec.dart';
import 'document_repository.dart';

final class FileDocumentSaveDiagnostics {
  const FileDocumentSaveDiagnostics({
    required this.documentId,
    required this.revision,
    required this.payloadByteLength,
    required this.fullPayloadWrites,
    required this.encodeDuration,
    required this.ioDuration,
    required this.totalDuration,
    required this.usedBackgroundIsolate,
    this.encodedPageCount = 0,
    this.reusedPageCount = 0,
  });

  final String documentId;
  final int revision;
  final int payloadByteLength;
  final int fullPayloadWrites;
  final Duration encodeDuration;
  final Duration ioDuration;
  final Duration totalDuration;
  final bool usedBackgroundIsolate;
  final int encodedPageCount;
  final int reusedPageCount;
}

final class FileDocumentRepository
    implements
        DocumentRepository,
        DocumentOrganizationRepository,
        DocumentTrashRepository {
  FileDocumentRepository(
    this.root, {
    this.codec = const DocumentCodec(),
    this.useBackgroundIsolate = true,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Directory root;
  final DocumentCodec codec;
  final bool useBackgroundIsolate;
  final DateTime Function() _clock;
  final Map<String, Future<void>> _locks = {};
  final LinkedHashMap<String, _EncoderSnapshot> _encoderSnapshots =
      LinkedHashMap<String, _EncoderSnapshot>();
  Future<void> _organizationLock = Future<void>.value();
  int _temporaryCounter = 0;
  FileDocumentSaveDiagnostics? _lastSaveDiagnostics;

  FileDocumentSaveDiagnostics? get lastSaveDiagnostics => _lastSaveDiagnostics;

  Directory documentDirectory(String documentId) =>
      Directory(_join(root.path, 'documents', _safeDirectoryName(documentId)));

  Directory get trashDirectory => Directory(_join(root.path, 'trash'));

  Directory trashDocumentDirectory(String documentId) =>
      Directory(_join(trashDirectory.path, _safeDirectoryName(documentId)));

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

  File trashMetadataFileFor(String documentId) => File(
    _join(trashDocumentDirectory(documentId).path, _trashMetadataFileName),
  );

  File trashMetadataBackupFileFor(String documentId) => File(
    _join(
      trashDocumentDirectory(documentId).path,
      _trashMetadataBackupFileName,
    ),
  );

  /// Returns the currently referenced pending payload for a v3 journal.
  ///
  /// Exposed for diagnostics/tests; callers must treat the file as
  /// repository-owned transaction state.
  Future<File?> pendingPayloadFileFor(String documentId) async {
    final journal = journalFileFor(documentId);
    if (!await journal.exists()) return null;
    final prefix = await _readJournalPrefix(journal);
    return prefix?.header.journalVersion == 3
        ? _pendingPayloadFile(journal, prefix!.header)
        : null;
  }

  /// Compact, disposable library metadata for [list].
  ///
  /// The document remains the source of truth. The cache is accepted only
  /// while its primary-file stamp still matches and is rebuilt from the full
  /// document for legacy or stale entries.
  File summaryFileFor(String documentId) => File(
    _join(
      documentDirectory(documentId).path,
      'document.flowboard.summary.json',
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
  Future<Directory> assetDirectory(String documentId) =>
      _withLock(documentId, () async {
        await _throwIfTrashedUnlocked(documentId);
        final directory = Directory(
          _join(documentDirectory(documentId).path, 'assets'),
        );
        await directory.create(recursive: true);
        return directory;
      });

  Future<void> _throwIfTrashedUnlocked(String documentId) async {
    if (!await trashDocumentDirectory(documentId).exists()) return;
    throw DocumentStorageException(
      'Das Dokument $documentId befindet sich im Papierkorb und kann nicht überschrieben werden.',
    );
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
  Future<WhiteboardDocument?> recover(String documentId) =>
      _withLock(documentId, () => _recoverUnlocked(documentId));

  Future<WhiteboardDocument?> _recoverUnlocked(String documentId) async {
    final directory = documentDirectory(documentId);
    if (!await directory.exists()) return null;
    final inspection = await _inspectRecoveryDirectory(directory, documentId);
    if (inspection.candidates.isEmpty) {
      if (inspection.errors.isEmpty) return null;
      throw DocumentStorageException(
        'Keine intakte Version von $documentId gefunden.',
        cause: inspection.errors.first,
      );
    }
    final candidates = inspection.candidates..sort(_compareRecoveryCandidates);
    final selected = candidates.first;
    final journal = journalFileFor(documentId);
    if (selected.source == _RecoverySource.primary) {
      final primarySnapshot = selected.primarySnapshot;
      bool summarySafe;
      if (primarySnapshot != null) {
        summarySafe = await _refreshSummaryCache(
          selected.document,
          primarySnapshot.fingerprint,
          primarySnapshot.stat,
        );
      } else {
        // A cache can always be regenerated. Do not leave a possibly stale
        // entry trusted after recovery removes the journal marker.
        summarySafe = await _deleteSummaryCache(documentId);
      }
      if (summarySafe && await journal.exists()) await journal.delete();
      return selected.document;
    }

    final recovered = selected.document.copyWith(
      metadata: selected.document.metadata.copyWith(recoveredFromCrash: true),
    );
    await _saveUnlocked(recovered);
    return recovered;
  }

  Future<DocumentSummary?> _listDocumentUnlocked(String documentId) async {
    final primary = documentFileFor(documentId);
    final journal = journalFileFor(documentId);
    final backup = backupFileFor(documentId);
    final recoveryAvailableFromJournal = await journal.exists();

    if (await primary.exists()) {
      final cached = await _readSummaryCache(documentId);
      if (cached != null &&
          await _summaryCacheMatchesPrimary(
            cached,
            primary,
            journal: recoveryAvailableFromJournal ? journal : null,
          )) {
        return cached.summary.copyWithRecovery(recoveryAvailableFromJournal);
      }
    }

    WhiteboardDocument? document;
    var recoveryAvailable = recoveryAvailableFromJournal;
    try {
      if (await primary.exists()) {
        final snapshot = await _decodePrimarySnapshot(primary);
        _verifyIdentity(documentId, snapshot.document);
        document = snapshot.document;
        await _refreshSummaryCache(
          document,
          snapshot.fingerprint,
          snapshot.stat,
        );
      }
    } catch (_) {
      recoveryAvailable = true;
      await _deleteSummaryCache(documentId);
    }
    if (document == null) {
      try {
        if (await journal.exists()) {
          document = await _decodeJournal(journal);
          _verifyIdentity(documentId, document);
        }
      } catch (_) {
        // A corrupt journal is ignored here; recover() reports full details.
      }
    }
    if (document == null) {
      try {
        if (await backup.exists()) {
          document = await _decodeFile(backup);
          _verifyIdentity(documentId, document);
        }
      } catch (_) {
        // Corrupt entries do not prevent the remaining overview from loading.
      }
    }
    if (document == null) return null;
    return DocumentSummary.fromDocument(
      document,
      recoveryAvailable: recoveryAvailable,
    );
  }

  @override
  Future<List<DocumentSummary>> list() async {
    final documentsRoot = Directory(_join(root.path, 'documents'));
    if (!await documentsRoot.exists()) return const [];
    final summaries = <DocumentSummary>[];
    await for (final entity in documentsRoot.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final documentId = _documentIdFromDirectory(entity);
      if (documentId == null) continue;
      final summary = await _withLock(
        documentId,
        () => _listDocumentUnlocked(documentId),
      );
      if (summary != null) summaries.add(summary);
    }
    summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(summaries);
  }

  @override
  Future<TrashedDocumentSummary> moveToTrash(
    String documentId, {
    String? originalFolderId,
  }) => _withLock(documentId, () async {
    final source = documentDirectory(documentId);
    if (!await source.exists()) {
      throw DocumentStorageException(
        'Das Dokument $documentId wurde nicht gefunden.',
      );
    }
    final destination = trashDocumentDirectory(documentId);
    if (await destination.exists()) {
      throw DocumentStorageException(
        'Im Papierkorb existiert bereits ein Dokument mit dieser ID.',
      );
    }

    // Inspect without promoting or consuming journal/backup files: moving to
    // trash must preserve the complete recovery state byte-for-byte.
    final inspection = await _inspectRecoveryDirectory(source, documentId);
    if (inspection.candidates.isEmpty) {
      throw DocumentStorageException(
        'Das Dokument $documentId konnte nicht für den Papierkorb gelesen werden.',
        cause: inspection.errors.isEmpty ? null : inspection.errors.first,
      );
    }
    final candidates = inspection.candidates..sort(_compareRecoveryCandidates);
    final document = candidates.first.document;
    final deletedAt = _clock().toUtc();
    final metadata = _TrashMetadata(
      documentId: document.id,
      title: document.title,
      deletedAt: deletedAt,
      pageCount: document.pages.length,
      revision: document.revision,
      originalFolderId: _normalizedOptionalId(originalFolderId),
    );
    final metadataFile = File(_join(source.path, _trashMetadataFileName));
    final metadataBackup = File(
      _join(source.path, _trashMetadataBackupFileName),
    );
    try {
      await _replaceAtomically(
        metadataFile,
        jsonEncode(metadata.toJson()),
        backup: metadataBackup,
      );
      await trashDirectory.create(recursive: true);
      await source.rename(destination.path);
    } catch (error) {
      // A failed destination creation/rename leaves the live document
      // untouched. Remove only metadata written by this attempt; document and
      // asset files remain.
      await _deleteBestEffort(metadataFile);
      await _deleteBestEffort(metadataBackup);
      throw DocumentStorageException(
        'Das Dokument konnte nicht in den Papierkorb verschoben werden.',
        cause: error,
      );
    }
    await _invalidateEncoder(documentId);
    return metadata.toSummary(recoverable: true);
  });

  @override
  Future<List<TrashedDocumentSummary>> listTrashed() async {
    final rootDirectory = trashDirectory;
    if (!await rootDirectory.exists()) return const <TrashedDocumentSummary>[];
    final summaries = <TrashedDocumentSummary>[];
    await for (final entity in rootDirectory.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final documentId = _documentIdFromDirectory(entity);
      if (documentId == null) continue;
      final summary = await _withLock(
        documentId,
        () => _listTrashedDocumentUnlocked(entity, documentId),
      );
      summaries.add(summary);
    }
    summaries.sort((first, second) {
      final deleted = second.deletedAt.compareTo(first.deletedAt);
      return deleted != 0 ? deleted : first.id.compareTo(second.id);
    });
    return List<TrashedDocumentSummary>.unmodifiable(summaries);
  }

  @override
  Future<RestoredTrashDocument> restoreFromTrash(
    String documentId,
  ) => _withLock(documentId, () async {
    final source = trashDocumentDirectory(documentId);
    if (!await source.exists()) {
      throw DocumentStorageException(
        'Das Dokument wurde im Papierkorb nicht gefunden.',
      );
    }
    final destination = documentDirectory(documentId);
    if (await destination.exists()) {
      throw DocumentStorageException(
        'Ein aktives Dokument mit derselben ID verhindert die Wiederherstellung.',
      );
    }
    final metadata = await _readTrashMetadata(source, documentId);
    final inspection = await _inspectRecoveryDirectory(source, documentId);
    if (inspection.candidates.isEmpty) {
      throw DocumentStorageException(
        'Im Papierkorb wurde keine intakte Dokumentversion gefunden.',
        cause: inspection.errors.isEmpty ? null : inspection.errors.first,
      );
    }
    final candidates = inspection.candidates..sort(_compareRecoveryCandidates);
    final selected = candidates.first;
    final hadJournal = await File(
      _join(source.path, 'document.flowboard.journal.json'),
    ).exists();
    await destination.parent.create(recursive: true);
    try {
      await source.rename(destination.path);
      await _deleteBestEffort(
        File(_join(destination.path, _trashMetadataFileName)),
      );
      await _deleteBestEffort(
        File(_join(destination.path, _trashMetadataBackupFileName)),
      );
      return RestoredTrashDocument(
        document: selected.document,
        recoveryAvailable:
            hadJournal || selected.source != _RecoverySource.primary,
        originalFolderId: metadata?.originalFolderId,
      );
    } catch (error) {
      // Roll the complete directory back when validation/promotion after the
      // rename fails. Never leave half a document in both locations.
      if (await destination.exists() && !await source.exists()) {
        try {
          await source.parent.create(recursive: true);
          await destination.rename(source.path);
        } on FileSystemException {
          // The original error contains the useful recovery context. A later
          // list still exposes whichever complete directory survived.
        }
      }
      if (error is DocumentStorageException) rethrow;
      throw DocumentStorageException(
        'Das Dokument konnte nicht wiederhergestellt werden.',
        cause: error,
      );
    }
  });

  @override
  Future<void> deletePermanentlyFromTrash(String documentId) =>
      _withLock(documentId, () async {
        final directory = trashDocumentDirectory(documentId);
        if (!await directory.exists()) {
          throw const DocumentStorageException(
            'Das Dokument wurde im Papierkorb nicht gefunden.',
          );
        }
        await directory.delete(recursive: true);
        await _invalidateEncoder(documentId);
      });

  @override
  Future<void> delete(String documentId) => _withLock(documentId, () async {
    final directory = documentDirectory(documentId);
    if (await directory.exists()) await directory.delete(recursive: true);
    await _invalidateEncoder(documentId);
  });

  Future<void> _invalidateEncoder(String documentId) async {
    final cacheKey = '${root.absolute.path}\u0000$documentId';
    _encoderSnapshots.remove(cacheKey);
    await _sharedDocumentEncoder.invalidate(cacheKey);
  }

  Future<void> _saveUnlocked(WhiteboardDocument document) async {
    await _throwIfTrashedUnlocked(document.id);
    final totalWatch = Stopwatch()..start();
    final directory = documentDirectory(document.id);
    await directory.create(recursive: true);
    final encodeWatch = Stopwatch()..start();
    final encoded = await _encodeForSave(document);
    encodeWatch.stop();
    final journal = journalFileFor(document.id);
    final previousPending = await _pendingPayloadFileFromExistingJournal(
      journal,
    );
    final pendingName = _newPendingPayloadName();
    final pending = File(_join(directory.path, pendingName));
    final journalHeader = jsonEncode({
      'journalVersion': 3,
      'documentId': document.id,
      'revision': document.revision,
      'updatedAt': document.updatedAt.toIso8601String(),
      'payloadStorage': 'pending-file',
      'payloadFile': pendingName,
      'payloadByteLength': encoded.byteLength,
      'checksum': encoded.checksum,
    });
    final ioWatch = Stopwatch()..start();
    await _replaceBytesAtomically(pending, encoded.payload);
    try {
      await _replaceAtomically(journal, journalHeader);
    } catch (_) {
      await _deleteBestEffort(pending);
      rethrow;
    }
    await _deleteBestEffort(previousPending, except: pending);
    await _promotePendingPayload(
      pending,
      documentFileFor(document.id),
      backup: backupFileFor(document.id),
    );
    final primaryStat = await documentFileFor(document.id).stat();
    final summarySafe = await _refreshSummaryCache(
      document,
      encoded.fingerprint,
      primaryStat,
    );
    if (summarySafe && await journal.exists()) await journal.delete();
    // A process termination between writing a pending payload and publishing
    // its journal can leave an unreferenced full-document file behind. Those
    // files otherwise accumulate with document size and eventually make
    // directory scans and low-storage devices slower. Cleanup happens only
    // after the new primary is durable, and the strict filename predicate
    // cannot match imported assets.
    await _deleteOrphanTransactionFiles(directory);
    ioWatch.stop();
    totalWatch.stop();
    _lastSaveDiagnostics = FileDocumentSaveDiagnostics(
      documentId: document.id,
      revision: document.revision,
      payloadByteLength: encoded.byteLength,
      fullPayloadWrites: 1,
      encodeDuration: encodeWatch.elapsed,
      ioDuration: ioWatch.elapsed,
      totalDuration: totalWatch.elapsed,
      usedBackgroundIsolate: useBackgroundIsolate,
      encodedPageCount: encoded.encodedPageCount,
      reusedPageCount: encoded.reusedPageCount,
    );
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
      final primarySnapshot = source == _RecoverySource.primary
          ? await _decodePrimarySnapshot(file)
          : null;
      final document = primarySnapshot?.document ?? await _decodeFile(file);
      _verifyIdentity(documentId, document);
      candidates.add(
        _RecoveryCandidate(source, document, primarySnapshot: primarySnapshot),
      );
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

  Future<_RecoveryInspection> _inspectRecoveryDirectory(
    Directory directory,
    String documentId,
  ) async {
    final candidates = <_RecoveryCandidate>[];
    final errors = <Object>[];
    await _tryCandidate(
      candidates,
      errors,
      _RecoverySource.primary,
      File(_join(directory.path, 'document.flowboard.json')),
      documentId,
    );
    await _tryJournalCandidate(
      candidates,
      errors,
      File(_join(directory.path, 'document.flowboard.journal.json')),
      documentId,
    );
    await _tryCandidate(
      candidates,
      errors,
      _RecoverySource.backup,
      File(_join(directory.path, 'document.flowboard.backup.json')),
      documentId,
    );
    return _RecoveryInspection(candidates: candidates, errors: errors);
  }

  Future<_TrashMetadata?> _readTrashMetadata(
    Directory directory,
    String documentId,
  ) async {
    for (final name in <String>[
      _trashMetadataFileName,
      _trashMetadataBackupFileName,
    ]) {
      final file = File(_join(directory.path, name));
      if (!await file.exists()) continue;
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map) continue;
        final metadata = _TrashMetadata.fromJson(
          Map<String, Object?>.from(decoded),
        );
        if (metadata.documentId == documentId) return metadata;
      } catch (_) {
        // A damaged sidecar must not hide the complete trash directory. The
        // document payload (or a final corrupt-entry fallback) is used below.
      }
    }
    return null;
  }

  Future<TrashedDocumentSummary> _listTrashedDocumentUnlocked(
    Directory directory,
    String documentId,
  ) async {
    final metadata = await _readTrashMetadata(directory, documentId);
    final inspection = await _inspectRecoveryDirectory(directory, documentId);
    inspection.candidates.sort(_compareRecoveryCandidates);
    final document = inspection.candidates.isEmpty
        ? null
        : inspection.candidates.first.document;
    DateTime fallbackDeletedAt;
    try {
      fallbackDeletedAt = (await directory.stat()).modified.toUtc();
    } catch (_) {
      fallbackDeletedAt = _clock().toUtc();
    }
    return TrashedDocumentSummary(
      id: documentId,
      title: metadata?.title ?? document?.title ?? 'Beschädigtes Dokument',
      deletedAt: metadata?.deletedAt ?? fallbackDeletedAt,
      pageCount: metadata?.pageCount ?? document?.pages.length ?? 0,
      revision: metadata?.revision ?? document?.revision ?? 0,
      recoverable: document != null,
      originalFolderId: metadata?.originalFolderId,
    );
  }

  Future<_EncodedDocument> _encodeForSave(WhiteboardDocument document) async {
    final prettyPrint = codec.prettyPrint;
    if (!useBackgroundIsolate) {
      return _encodeDocument(document, prettyPrint);
    }
    // Pretty-printed documents are primarily a diagnostic/development option.
    // Keep their exact formatting contract on the simple full encoder path.
    if (prettyPrint) return _encodeInFreshIsolate(document, prettyPrint);

    final cacheKey = '${root.absolute.path}\u0000${document.id}';
    final previous = _encoderSnapshots[cacheKey];
    final changedPages = previous == null
        ? document.pages.toList(growable: false)
        : previous.changedPages(document.pages);
    var request = _IncrementalEncodeRequest(
      cacheKey: cacheKey,
      cacheToken: previous?.cacheToken,
      header: _documentHeaderJson(document),
      pageIds: document.pages.map((page) => page.id).toList(growable: false),
      changedPages: changedPages,
    );

    try {
      var response = await _sharedDocumentEncoder.encode(request);
      if (response.needsFullSnapshot) {
        // The bounded worker cache may evict an inactive document. Retry with
        // all pages; this is still off the UI isolate and remains correct.
        request = _IncrementalEncodeRequest(
          cacheKey: cacheKey,
          cacheToken: null,
          header: request.header,
          pageIds: request.pageIds,
          changedPages: document.pages.toList(growable: false),
        );
        response = await _sharedDocumentEncoder.encode(request);
      }
      if (response.needsFullSnapshot || response.payload == null) {
        throw StateError(
          'Der inkrementelle Dokumentencoder konnte nicht initialisiert werden.',
        );
      }
      final cacheToken = response.cacheToken;
      if (cacheToken == null) {
        _encoderSnapshots.remove(cacheKey);
      } else {
        _rememberEncoderSnapshot(
          cacheKey,
          _EncoderSnapshot.fromDocument(document, cacheToken),
        );
      }
      return _EncodedDocument(
        payload: response.payload!.materialize().asUint8List(),
        checksum: response.checksum!,
        byteLength: response.byteLength!,
        encodedPageCount: response.encodedPageCount,
        reusedPageCount: response.reusedPageCount,
      );
    } catch (_) {
      // Persistence correctness never depends on the disposable acceleration
      // cache. A worker restart, unsupported isolate runtime, or corrupt cache
      // therefore falls back to the established complete encoder.
      _encoderSnapshots.remove(cacheKey);
      return _encodeInFreshIsolate(document, prettyPrint);
    }
  }

  Future<_EncodedDocument> _encodeInFreshIsolate(
    WhiteboardDocument document,
    bool prettyPrint,
  ) async {
    final transferred = await Isolate.run(
      () => _encodeDocumentForTransfer(document, prettyPrint),
    );
    return _EncodedDocument(
      payload: transferred.payload.materialize().asUint8List(),
      checksum: transferred.checksum,
      byteLength: transferred.byteLength,
      encodedPageCount: document.pages.length,
      reusedPageCount: 0,
    );
  }

  void _rememberEncoderSnapshot(String key, _EncoderSnapshot snapshot) {
    _encoderSnapshots.remove(key);
    _encoderSnapshots[key] = snapshot;
    while (_encoderSnapshots.length > _maximumRootEncoderSnapshots) {
      _encoderSnapshots.remove(_encoderSnapshots.keys.first);
    }
  }

  Future<WhiteboardDocument> _decodeFile(File file) async {
    final source = await file.readAsString();
    if (!useBackgroundIsolate) return codec.decode(source);
    final prettyPrint = codec.prettyPrint;
    return Isolate.run(
      () => DocumentCodec(prettyPrint: prettyPrint).decode(source),
    );
  }

  Future<_PrimarySnapshot> _decodePrimarySnapshot(File file) async {
    final statBefore = await file.stat();
    final source = await file.readAsString();
    final prettyPrint = codec.prettyPrint;
    final decoded = useBackgroundIsolate
        ? await Isolate.run(
            () => _decodeDocumentWithFingerprint(source, prettyPrint),
          )
        : _decodeDocumentWithFingerprint(source, prettyPrint);
    final statAfter = await file.stat();
    if (!_sameFileStamp(statBefore, statAfter)) {
      throw const FileSystemException(
        'Das Dokument wurde während des Lesens verändert.',
      );
    }
    if (statAfter.size != decoded.fingerprint.byteLength) {
      throw const FormatException(
        'Dokumentgröße und gelesene Nutzdaten stimmen nicht überein.',
      );
    }
    return _PrimarySnapshot(
      document: decoded.document,
      fingerprint: decoded.fingerprint,
      stat: statAfter,
    );
  }

  Future<_DocumentSummaryCache?> _readSummaryCache(String documentId) async {
    final file = summaryFileFor(documentId);
    if (!await file.exists()) return null;
    try {
      final source = await file.readAsString();
      final decoded = jsonDecode(source);
      if (decoded is! Map) return null;
      final cache = _DocumentSummaryCache.fromJson(
        Map<String, Object?>.from(decoded),
      );
      return cache.summary.id == documentId ? cache : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSummaryCache(
    WhiteboardDocument document,
    _Utf8Fingerprint fingerprint,
    FileStat primaryStat,
  ) async {
    final cache = _DocumentSummaryCache(
      summary: DocumentSummary.fromDocument(document),
      payloadByteLength: fingerprint.byteLength,
      payloadChecksum: fingerprint.checksum,
      primaryModifiedMicros: primaryStat.modified.microsecondsSinceEpoch,
    );
    await _replaceAtomically(
      summaryFileFor(document.id),
      jsonEncode(cache.toJson()),
    );
    final currentPrimaryStat = await documentFileFor(document.id).stat();
    if (!_sameFileStamp(primaryStat, currentPrimaryStat)) {
      throw const FileSystemException(
        'Das Dokument wurde während der Indexaktualisierung verändert.',
      );
    }
  }

  Future<bool> _refreshSummaryCache(
    WhiteboardDocument document,
    _Utf8Fingerprint fingerprint,
    FileStat primaryStat,
  ) async {
    try {
      await _writeSummaryCache(document, fingerprint, primaryStat);
      return true;
    } catch (_) {
      // This index is only an acceleration structure. A full, successfully
      // promoted document must remain usable even on a read-only or nearly
      // full volume where the tiny cache cannot be refreshed.
      return _deleteSummaryCache(document.id);
    }
  }

  Future<bool> _deleteSummaryCache(String documentId) async {
    final cache = summaryFileFor(documentId);
    try {
      if (await cache.exists()) await cache.delete();
      return !await cache.exists();
    } on FileSystemException {
      // The cache is disposable and its file stamp prevents stale reuse.
      return false;
    }
  }

  Future<bool> _summaryCacheMatchesPrimary(
    _DocumentSummaryCache cache,
    File primary, {
    File? journal,
  }) async {
    try {
      final stat = await primary.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != cache.payloadByteLength ||
          stat.modified.microsecondsSinceEpoch != cache.primaryModifiedMicros) {
        return false;
      }
      if (journal != null) {
        final header = (await _readJournalPrefix(journal))?.header;
        if (header != null &&
            (header.documentId != cache.summary.id ||
                header.revision != cache.summary.revision ||
                header.updatedAt != cache.summary.updatedAt ||
                header.payloadByteLength != cache.payloadByteLength ||
                header.payloadChecksum != cache.payloadChecksum)) {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<_JournalPrefix?> _readJournalPrefix(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final length = await handle.length();
      if (length <= 0 || length > _maximumJournalHeaderBytes) {
        // V2 journals contain a newline within the prefix followed by an
        // arbitrarily large inline payload. V3 is a small header-only file.
        if (length <= 0) return null;
      }
      final prefix = await handle.read(
        length.clamp(0, _maximumJournalHeaderBytes).toInt(),
      );
      final separator = prefix.indexOf(0x0A);
      final headerBytes = separator > 0
          ? prefix.sublist(0, separator)
          : length <= _maximumJournalHeaderBytes
          ? prefix
          : null;
      if (headerBytes == null || headerBytes.isEmpty) return null;
      final decoded = jsonDecode(utf8.decode(headerBytes));
      if (decoded is! Map) return null;
      final header = _JournalHeader.fromJson(
        Map<String, Object?>.from(decoded),
      );
      if (header.journalVersion == 2 && separator <= 0) return null;
      if (header.journalVersion == 3 && separator >= 0) return null;
      return _JournalPrefix(
        header: header,
        payloadOffset: separator >= 0 ? separator + 1 : null,
      );
    } catch (_) {
      return null;
    } finally {
      await handle?.close();
    }
  }

  Future<WhiteboardDocument> _decodeJournal(File file) async {
    final prefix = await _readJournalPrefix(file);
    if (prefix == null) {
      return _decodeLegacyJournalSource(await file.readAsString());
    }
    final String payload;
    if (prefix.header.journalVersion == 2) {
      payload = await file
          .openRead(prefix.payloadOffset!)
          .transform(utf8.decoder)
          .join();
    } else {
      final pending = _pendingPayloadFile(file, prefix.header);
      final committedPrimary = File(
        _join(file.parent.path, 'document.flowboard.json'),
      );
      final payloadFile = pending != null && await pending.exists()
          ? pending
          : committedPrimary;
      if (!await payloadFile.exists()) {
        throw const FileSystemException(
          'Das ausstehende Journal-Payload fehlt.',
        );
      }
      payload = await payloadFile.readAsString();
    }
    final prettyPrint = codec.prettyPrint;
    if (!useBackgroundIsolate) {
      return _decodeJournalPayload(prefix.header, payload, prettyPrint);
    }
    final header = prefix.header;
    return Isolate.run(
      () => _decodeJournalPayload(header, payload, prettyPrint),
    );
  }

  Future<WhiteboardDocument> _decodeLegacyJournalSource(String source) async {
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

  String _newPendingPayloadName() {
    final micros = DateTime.now().microsecondsSinceEpoch;
    return 'document.flowboard.pending.$pid.$micros.${_temporaryCounter++}.json';
  }

  Future<File?> _pendingPayloadFileFromExistingJournal(File journal) async {
    if (!await journal.exists()) return null;
    final prefix = await _readJournalPrefix(journal);
    return prefix?.header.journalVersion == 3
        ? _pendingPayloadFile(journal, prefix!.header)
        : null;
  }

  File? _pendingPayloadFile(File journal, _JournalHeader header) {
    final name = header.payloadFile;
    if (name == null ||
        !RegExp(
          r'^document\.flowboard\.pending\.\d+\.\d+\.\d+\.json$',
        ).hasMatch(name)) {
      return null;
    }
    return File(_join(journal.parent.path, name));
  }

  Future<void> _deleteBestEffort(File? file, {File? except}) async {
    if (file == null || (except != null && file.path == except.path)) return;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // An obsolete pending payload is an ignorable orphan. The journal only
      // ever references the new, already durable payload at this point.
    }
  }

  Future<void> _deleteOrphanTransactionFiles(Directory directory) async {
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!_orphanTransactionFilePattern.hasMatch(name)) continue;
        await _deleteBestEffort(entity);
      }
    } on FileSystemException {
      // Transaction cleanup is opportunistic. The promoted primary and its
      // recovery guarantees must not be downgraded by a read-only directory
      // or an antivirus temporarily holding one obsolete file.
    }
  }

  /// Writes the only full durable copy needed for this save.
  ///
  /// UTF-8 conversion happened on the encoder isolate. `flush: true` makes the
  /// pending payload durable before the tiny journal starts referencing it.
  Future<void> _replaceBytesAtomically(File target, Uint8List contents) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp.$pid.${_temporaryCounter++}');
    await temporary.writeAsBytes(contents, flush: true);
    try {
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  /// Promotes the already durable pending payload without a second full write.
  ///
  /// If promotion fails after moving the previous primary, the backup is
  /// restored while the journal and pending payload remain recoverable.
  Future<void> _promotePendingPayload(
    File pending,
    File target, {
    required File backup,
  }) async {
    var targetMoved = false;
    try {
      if (await target.exists()) {
        if (await backup.exists()) await backup.delete();
        await target.rename(backup.path);
        targetMoved = true;
      }
      await pending.rename(target.path);
    } catch (_) {
      if (targetMoved && await backup.exists() && !await target.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
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
  const _RecoveryCandidate(this.source, this.document, {this.primarySnapshot});

  final _RecoverySource source;
  final WhiteboardDocument document;
  final _PrimarySnapshot? primarySnapshot;
}

final class _RecoveryInspection {
  const _RecoveryInspection({required this.candidates, required this.errors});

  final List<_RecoveryCandidate> candidates;
  final List<Object> errors;
}

final class _TrashMetadata {
  const _TrashMetadata({
    required this.documentId,
    required this.title,
    required this.deletedAt,
    required this.pageCount,
    required this.revision,
    this.originalFolderId,
  });

  final String documentId;
  final String title;
  final DateTime deletedAt;
  final int pageCount;
  final int revision;
  final String? originalFolderId;

  Map<String, Object?> toJson() => <String, Object?>{
    'trashVersion': _trashMetadataVersion,
    'documentId': documentId,
    'title': title,
    'deletedAt': deletedAt.toUtc().toIso8601String(),
    'pageCount': pageCount,
    'revision': revision,
    if (originalFolderId != null) 'originalFolderId': originalFolderId,
  };

  factory _TrashMetadata.fromJson(Map<String, Object?> json) {
    final version = json['trashVersion'];
    final documentId = json['documentId'];
    final title = json['title'];
    final deletedAtSource = json['deletedAt'];
    final pageCountSource = json['pageCount'];
    final revisionSource = json['revision'];
    final originalFolderIdSource = json['originalFolderId'];
    if (version != _trashMetadataVersion ||
        documentId is! String ||
        documentId.trim().isEmpty ||
        title is! String ||
        title.trim().isEmpty ||
        deletedAtSource is! String ||
        pageCountSource is! num ||
        revisionSource is! num ||
        (originalFolderIdSource != null && originalFolderIdSource is! String)) {
      throw const FormatException('Papierkorb-Metadaten sind ungültig.');
    }
    final deletedAt = DateTime.tryParse(deletedAtSource);
    final pageCount = pageCountSource.toInt();
    final revision = revisionSource.toInt();
    if (deletedAt == null ||
        pageCountSource != pageCount ||
        pageCount < 1 ||
        pageCount > WhiteboardDocument.maxPageCount ||
        revisionSource != revision ||
        revision < 0) {
      throw const FormatException('Papierkorb-Metadaten sind inkonsistent.');
    }
    return _TrashMetadata(
      documentId: documentId,
      title: title,
      deletedAt: deletedAt.toUtc(),
      pageCount: pageCount,
      revision: revision,
      originalFolderId: _normalizedOptionalId(
        originalFolderIdSource as String?,
      ),
    );
  }

  TrashedDocumentSummary toSummary({required bool recoverable}) =>
      TrashedDocumentSummary(
        id: documentId,
        title: title,
        deletedAt: deletedAt,
        pageCount: pageCount,
        revision: revision,
        recoverable: recoverable,
        originalFolderId: originalFolderId,
      );
}

String? _normalizedOptionalId(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
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

String? _documentIdFromDirectory(Directory directory) {
  final separator = Platform.pathSeparator;
  final normalized = directory.path.endsWith(separator)
      ? directory.path.substring(0, directory.path.length - 1)
      : directory.path;
  final separatorIndex = normalized.lastIndexOf(separator);
  final name = separatorIndex < 0
      ? normalized
      : normalized.substring(separatorIndex + 1);
  if (!name.startsWith('doc_') || name.length <= 4) return null;
  try {
    final id = Uri.decodeComponent(name.substring(4));
    return id.trim().isEmpty ? null : id;
  } on FormatException {
    return null;
  }
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

Map<String, Object?> _documentHeaderJson(WhiteboardDocument document) => {
  'schemaVersion': DocumentMigrator.currentVersion,
  'id': document.id,
  'title': document.title,
  'createdAt': document.createdAt.toIso8601String(),
  'updatedAt': document.updatedAt.toIso8601String(),
  'revision': document.revision,
  'currentPageIndex': document.currentPageIndex,
  'presets': document.presets
      .map((preset) => preset.toJson())
      .toList(growable: false),
  'activePresetId': document.activePresetId,
  'assets': document.assets
      .map((asset) => asset.toJson())
      .toList(growable: false),
  'metadata': document.metadata.toJson(),
  if (document.thumbnailAssetId != null)
    'thumbnailAssetId': document.thumbnailAssetId,
};

final class _EncoderSnapshot {
  _EncoderSnapshot({
    required this.cacheToken,
    required Map<String, WeakReference<BoardPage>> pages,
  }) : pages = Map<String, WeakReference<BoardPage>>.unmodifiable(pages);

  factory _EncoderSnapshot.fromDocument(
    WhiteboardDocument document,
    int cacheToken,
  ) => _EncoderSnapshot(
    cacheToken: cacheToken,
    pages: {
      for (final page in document.pages)
        page.id: WeakReference<BoardPage>(page),
    },
  );

  final int cacheToken;
  final Map<String, WeakReference<BoardPage>> pages;

  List<BoardPage> changedPages(List<BoardPage> current) {
    final changed = <BoardPage>[];
    for (final page in current) {
      if (!identical(pages[page.id]?.target, page)) changed.add(page);
    }
    return changed;
  }
}

final class _IncrementalEncodeRequest {
  const _IncrementalEncodeRequest({
    required this.cacheKey,
    required this.cacheToken,
    required this.header,
    required this.pageIds,
    required this.changedPages,
  });

  final String cacheKey;
  final int? cacheToken;
  final Map<String, Object?> header;
  final List<String> pageIds;
  final List<BoardPage> changedPages;
}

final class _IncrementalEncodeResponse {
  const _IncrementalEncodeResponse._({
    required this.needsFullSnapshot,
    this.payload,
    this.checksum,
    this.byteLength,
    this.cacheToken,
    this.encodedPageCount = 0,
    this.reusedPageCount = 0,
    this.error,
    this.stackTrace,
  });

  const _IncrementalEncodeResponse.needsFull()
    : this._(needsFullSnapshot: true);

  const _IncrementalEncodeResponse.success({
    required TransferableTypedData payload,
    required String checksum,
    required int byteLength,
    required int? cacheToken,
    required int encodedPageCount,
    required int reusedPageCount,
  }) : this._(
         needsFullSnapshot: false,
         payload: payload,
         checksum: checksum,
         byteLength: byteLength,
         cacheToken: cacheToken,
         encodedPageCount: encodedPageCount,
         reusedPageCount: reusedPageCount,
       );

  const _IncrementalEncodeResponse.failure(String error, String stackTrace)
    : this._(needsFullSnapshot: false, error: error, stackTrace: stackTrace);

  final bool needsFullSnapshot;
  final TransferableTypedData? payload;
  final String? checksum;
  final int? byteLength;
  final int? cacheToken;
  final int encodedPageCount;
  final int reusedPageCount;
  final String? error;
  final String? stackTrace;
}

final class _EncoderWorkerMessage {
  const _EncoderWorkerMessage(this.request, this.replyTo);

  final _IncrementalEncodeRequest request;
  final SendPort replyTo;
}

final class _EncoderWorkerInvalidate {
  const _EncoderWorkerInvalidate(this.cacheKey);

  final String cacheKey;
}

/// One shared, bounded encoder isolate retains only serialized page fragments.
///
/// Sending an immutable 100-page model to a fresh isolate still requires the
/// root isolate to traverse and copy that complete object graph. That copy can
/// briefly contend with pointer delivery even though JSON conversion itself is
/// off-thread. The worker receives only page objects whose identity changed
/// since the preceding save and reuses compact bytes for all other pages.
final class _SharedDocumentEncoder {
  Future<SendPort>? _starting;
  Isolate? _isolate;

  Future<_IncrementalEncodeResponse> encode(
    _IncrementalEncodeRequest request,
  ) async {
    final sendPort = await _ensureStarted();
    final replies = ReceivePort();
    try {
      sendPort.send(_EncoderWorkerMessage(request, replies.sendPort));
      final response = await replies.first.timeout(
        _encoderWorkerResponseTimeout,
      );
      if (response is! _IncrementalEncodeResponse) {
        throw const FormatException(
          'Der Dokumentencoder hat eine ungÃ¼ltige Antwort geliefert.',
        );
      }
      if (response.error != null) {
        throw StateError(
          '${response.error}\n${response.stackTrace ?? ''}'.trimRight(),
        );
      }
      return response;
    } on TimeoutException {
      _reset();
      rethrow;
    } finally {
      replies.close();
    }
  }

  Future<void> invalidate(String cacheKey) async {
    final starting = _starting;
    if (starting == null) return;
    try {
      final sendPort = await starting;
      sendPort.send(_EncoderWorkerInvalidate(cacheKey));
    } catch (_) {
      // The cache is disposable and a subsequent encode restarts/falls back.
    }
  }

  Future<SendPort> _ensureStarted() {
    final starting = _starting;
    if (starting != null) return starting;
    final operation = _start();
    _starting = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_starting, operation)) _starting = null;
        },
      ),
    );
    return operation;
  }

  Future<SendPort> _start() async {
    final ready = ReceivePort();
    try {
      final isolate = await Isolate.spawn<SendPort>(
        _documentEncoderWorkerMain,
        ready.sendPort,
        debugName: 'flowboard-document-encoder',
      );
      final port = await ready.first.timeout(_encoderWorkerStartupTimeout);
      if (port is! SendPort) {
        isolate.kill(priority: Isolate.immediate);
        throw const FormatException(
          'Der Dokumentencoder konnte nicht gestartet werden.',
        );
      }
      _isolate = isolate;
      return port;
    } finally {
      ready.close();
    }
  }

  void _reset() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _starting = null;
  }
}

void _documentEncoderWorkerMain(SendPort ready) {
  final messages = ReceivePort();
  final state = _DocumentEncoderWorkerState();
  ready.send(messages.sendPort);
  messages.listen((message) {
    if (message is _EncoderWorkerInvalidate) {
      state.invalidate(message.cacheKey);
      return;
    }
    if (message is! _EncoderWorkerMessage) return;
    try {
      message.replyTo.send(state.encode(message.request));
    } catch (error, stackTrace) {
      message.replyTo.send(
        _IncrementalEncodeResponse.failure(
          error.toString(),
          stackTrace.toString(),
        ),
      );
    }
  });
}

final class _DocumentEncoderWorkerState {
  final LinkedHashMap<String, _WorkerDocumentCache> _documents =
      LinkedHashMap<String, _WorkerDocumentCache>();
  int _cachedBytes = 0;
  int _nextToken = 1;

  _IncrementalEncodeResponse encode(_IncrementalEncodeRequest request) {
    final existing = _documents[request.cacheKey];
    if (request.cacheToken != null &&
        (existing == null || existing.token != request.cacheToken)) {
      return const _IncrementalEncodeResponse.needsFull();
    }

    final fragments = request.cacheToken == null
        ? <String, Uint8List>{}
        : Map<String, Uint8List>.from(existing!.pageFragments);
    final changedIds = <String>{};
    for (final page in request.changedPages) {
      if (!changedIds.add(page.id)) {
        throw FormatException('Seite ${page.id} wurde doppelt Ã¼bergeben.');
      }
      fragments[page.id] = _encodeJsonBytes(page.toJson());
    }
    final orderedIds = request.pageIds.toSet();
    if (orderedIds.length != request.pageIds.length) {
      throw const FormatException('Seiten-IDs sind nicht eindeutig.');
    }
    fragments.removeWhere((pageId, _) => !orderedIds.contains(pageId));
    for (final pageId in request.pageIds) {
      if (!fragments.containsKey(pageId)) {
        return const _IncrementalEncodeResponse.needsFull();
      }
    }

    final orderedFragments = <Uint8List>[
      for (final pageId in request.pageIds) fragments[pageId]!,
    ];
    final payload = _assembleDocumentPayload(request.header, orderedFragments);
    final fingerprint = _byteFingerprint(payload);
    final token = request.cacheToken ?? _nextToken++;
    final nextCache = _WorkerDocumentCache(
      token: token,
      pageFragments: fragments,
    );
    if (existing != null) _cachedBytes -= existing.byteLength;
    _documents.remove(request.cacheKey);
    _documents[request.cacheKey] = nextCache;
    _cachedBytes += nextCache.byteLength;
    _evictToBudget();
    final retainedToken = _documents.containsKey(request.cacheKey)
        ? token
        : null;
    return _IncrementalEncodeResponse.success(
      payload: TransferableTypedData.fromList(<Uint8List>[payload]),
      checksum: fingerprint.checksum,
      byteLength: fingerprint.byteLength,
      cacheToken: retainedToken,
      encodedPageCount: changedIds.length,
      reusedPageCount: request.pageIds.length - changedIds.length,
    );
  }

  void invalidate(String cacheKey) {
    final removed = _documents.remove(cacheKey);
    if (removed != null) _cachedBytes -= removed.byteLength;
  }

  void _evictToBudget() {
    while ((_cachedBytes > _maximumWorkerEncoderCacheBytes ||
            _documents.length > _maximumWorkerEncoderDocuments) &&
        _documents.isNotEmpty) {
      final oldestKey = _documents.keys.first;
      final removed = _documents.remove(oldestKey)!;
      _cachedBytes -= removed.byteLength;
    }
  }
}

final class _WorkerDocumentCache {
  _WorkerDocumentCache({
    required this.token,
    required Map<String, Uint8List> pageFragments,
  }) : pageFragments = Map<String, Uint8List>.unmodifiable(pageFragments),
       byteLength = pageFragments.values.fold<int>(
         0,
         (total, page) => total + page.length,
       );

  final int token;
  final Map<String, Uint8List> pageFragments;
  final int byteLength;
}

Uint8List _encodeJsonBytes(Object? value) {
  final bytes = JsonUtf8Encoder(
    null,
    null,
    _documentEncodingBufferBytes,
  ).convert(value);
  return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}

Uint8List _assembleDocumentPayload(
  Map<String, Object?> header,
  List<Uint8List> pages,
) {
  final headerBytes = _encodeJsonBytes(header);
  if (headerBytes.length < 2 ||
      headerBytes.first != _jsonObjectOpen ||
      headerBytes.last != _jsonObjectClose) {
    throw const FormatException('Dokumentkopf ist kein JSON-Objekt.');
  }
  var length = _documentPagesPrefix.length + 1 + headerBytes.length;
  for (final page in pages) {
    length += page.length;
  }
  if (pages.length > 1) length += pages.length - 1;
  final result = Uint8List(length);
  var offset = 0;
  result.setRange(
    offset,
    offset + _documentPagesPrefix.length,
    _documentPagesPrefix,
  );
  offset += _documentPagesPrefix.length;
  for (var index = 0; index < pages.length; index++) {
    if (index > 0) result[offset++] = _jsonComma;
    final page = pages[index];
    result.setRange(offset, offset + page.length, page);
    offset += page.length;
  }
  result[offset++] = _jsonArrayClose;
  result[offset++] = _jsonComma;
  result.setRange(offset, offset + headerBytes.length - 1, headerBytes, 1);
  offset += headerBytes.length - 1;
  if (offset != result.length) {
    throw StateError(
      'Dokumentencoder schrieb $offset statt ${result.length} Bytes.',
    );
  }
  return result;
}

final class _EncodedDocument {
  const _EncodedDocument({
    required this.payload,
    required this.checksum,
    required this.byteLength,
    required this.encodedPageCount,
    required this.reusedPageCount,
  });

  final Uint8List payload;
  final String checksum;
  final int byteLength;
  final int encodedPageCount;
  final int reusedPageCount;

  _Utf8Fingerprint get fingerprint => _Utf8Fingerprint(checksum, byteLength);
}

_EncodedDocument _encodeDocument(
  WhiteboardDocument document,
  bool prettyPrint,
) {
  // Encode directly to the bytes that are persisted. Building a complete
  // JSON String first and UTF-8-encoding it afterwards temporarily retained
  // two full document payloads in the worker isolate and traversed the output
  // twice. That cost grows with every page and can increase GC pressure while
  // a new stylus gesture is starting.
  // Dart's default JSON UTF-8 chunk is only 256 bytes. A board document can
  // therefore allocate tens of thousands of tiny chunks before they are
  // combined. A bounded 64 KiB chunk keeps allocation/GC overhead stable while
  // remaining small compared with a page image or a typical ink document.
  final encoder = JsonUtf8Encoder(
    prettyPrint ? '  ' : null,
    null,
    _documentEncodingBufferBytes,
  );
  final bytes = encoder.convert(
    document.toJson(schemaVersion: DocumentMigrator.currentVersion),
  );
  final payload = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final fingerprint = _byteFingerprint(payload);
  return _EncodedDocument(
    payload: payload,
    checksum: fingerprint.checksum,
    byteLength: fingerprint.byteLength,
    encodedPageCount: document.pages.length,
    reusedPageCount: 0,
  );
}

final class _TransferredEncodedDocument {
  const _TransferredEncodedDocument({
    required this.payload,
    required this.checksum,
    required this.byteLength,
  });

  final TransferableTypedData payload;
  final String checksum;
  final int byteLength;
}

_TransferredEncodedDocument _encodeDocumentForTransfer(
  WhiteboardDocument document,
  bool prettyPrint,
) {
  final encoded = _encodeDocument(document, prettyPrint);
  return _TransferredEncodedDocument(
    payload: TransferableTypedData.fromList(<Uint8List>[encoded.payload]),
    checksum: encoded.checksum,
    byteLength: encoded.byteLength,
  );
}

final class _DecodedDocument {
  const _DecodedDocument(this.document, this.fingerprint);

  final WhiteboardDocument document;
  final _Utf8Fingerprint fingerprint;
}

_DecodedDocument _decodeDocumentWithFingerprint(
  String source,
  bool prettyPrint,
) => _DecodedDocument(
  DocumentCodec(prettyPrint: prettyPrint).decode(source),
  _utf8Fingerprint(source),
);

final class _PrimarySnapshot {
  const _PrimarySnapshot({
    required this.document,
    required this.fingerprint,
    required this.stat,
  });

  final WhiteboardDocument document;
  final _Utf8Fingerprint fingerprint;
  final FileStat stat;
}

const int _documentSummaryCacheVersion = 1;
const int _trashMetadataVersion = 1;
const String _trashMetadataFileName = 'document.flowboard.trash.json';
const String _trashMetadataBackupFileName =
    'document.flowboard.trash.backup.json';
const int _maximumJournalHeaderBytes = 4096;
const int _documentEncodingBufferBytes = 64 * 1024;
const int _maximumRootEncoderSnapshots = 8;
const int _maximumWorkerEncoderDocuments = 4;
const int _maximumWorkerEncoderCacheBytes = 48 * 1024 * 1024;
const int _jsonObjectOpen = 0x7B;
const int _jsonObjectClose = 0x7D;
const int _jsonArrayClose = 0x5D;
const int _jsonComma = 0x2C;
const Duration _encoderWorkerStartupTimeout = Duration(seconds: 10);
const Duration _encoderWorkerResponseTimeout = Duration(minutes: 2);
final _SharedDocumentEncoder _sharedDocumentEncoder = _SharedDocumentEncoder();
final Uint8List _documentPagesPrefix = Uint8List.fromList(
  utf8.encode('{"pages":['),
);
final RegExp _orphanTransactionFilePattern = RegExp(
  r'^document\.flowboard\.pending\.\d+\.\d+\.\d+\.json'
  r'(?:\.tmp\.\d+\.\d+)?$',
);

final class _DocumentSummaryCache {
  const _DocumentSummaryCache({
    required this.summary,
    required this.payloadByteLength,
    required this.payloadChecksum,
    required this.primaryModifiedMicros,
  });

  final DocumentSummary summary;
  final int payloadByteLength;
  final String payloadChecksum;
  final int primaryModifiedMicros;

  Map<String, Object?> toJson() => <String, Object?>{
    'summaryVersion': _documentSummaryCacheVersion,
    'documentId': summary.id,
    'title': summary.title,
    'updatedAt': summary.updatedAt.toUtc().toIso8601String(),
    'pageCount': summary.pageCount,
    'revision': summary.revision,
    if (summary.thumbnailAssetId != null)
      'thumbnailAssetId': summary.thumbnailAssetId,
    'payloadByteLength': payloadByteLength,
    'payloadChecksum': payloadChecksum,
    'primaryModifiedMicros': primaryModifiedMicros,
  };

  factory _DocumentSummaryCache.fromJson(Map<String, Object?> json) {
    final version = json['summaryVersion'];
    final id = json['documentId'];
    final title = json['title'];
    final updatedAtSource = json['updatedAt'];
    final pageCount = json['pageCount'];
    final revision = json['revision'];
    final thumbnailAssetId = json['thumbnailAssetId'];
    final payloadByteLength = json['payloadByteLength'];
    final payloadChecksum = json['payloadChecksum'];
    final primaryModifiedMicros = json['primaryModifiedMicros'];
    if (version != _documentSummaryCacheVersion ||
        id is! String ||
        id.trim().isEmpty ||
        title is! String ||
        updatedAtSource is! String ||
        pageCount is! num ||
        revision is! num ||
        (thumbnailAssetId != null && thumbnailAssetId is! String) ||
        payloadByteLength is! num ||
        payloadChecksum is! String ||
        primaryModifiedMicros is! num) {
      throw const FormatException('Dokumentübersicht ist ungültig.');
    }
    final parsedUpdatedAt = DateTime.tryParse(updatedAtSource);
    final normalizedPageCount = pageCount.toInt();
    final normalizedRevision = revision.toInt();
    final normalizedByteLength = payloadByteLength.toInt();
    final normalizedModifiedMicros = primaryModifiedMicros.toInt();
    if (parsedUpdatedAt == null ||
        normalizedPageCount < 1 ||
        normalizedPageCount > WhiteboardDocument.maxPageCount ||
        normalizedRevision < 0 ||
        normalizedByteLength < 1 ||
        payloadChecksum.isEmpty ||
        normalizedModifiedMicros < 1) {
      throw const FormatException('Dokumentübersicht ist inkonsistent.');
    }
    return _DocumentSummaryCache(
      summary: DocumentSummary(
        id: id,
        title: title,
        updatedAt: parsedUpdatedAt.toUtc(),
        pageCount: normalizedPageCount,
        revision: normalizedRevision,
        thumbnailAssetId: thumbnailAssetId as String?,
      ),
      payloadByteLength: normalizedByteLength,
      payloadChecksum: payloadChecksum,
      primaryModifiedMicros: normalizedModifiedMicros,
    );
  }
}

final class _JournalHeader {
  const _JournalHeader({
    required this.journalVersion,
    required this.documentId,
    required this.revision,
    required this.updatedAt,
    required this.payloadByteLength,
    required this.payloadChecksum,
    this.payloadFile,
  });

  final int journalVersion;
  final String documentId;
  final int revision;
  final DateTime updatedAt;
  final int payloadByteLength;
  final String payloadChecksum;
  final String? payloadFile;

  factory _JournalHeader.fromJson(Map<String, Object?> json) {
    final journalVersion = json['journalVersion'];
    final documentId = json['documentId'];
    final revision = json['revision'];
    final updatedAt = json['updatedAt'];
    final payloadByteLength = json['payloadByteLength'];
    final payloadChecksum = json['checksum'];
    final payloadFile = json['payloadFile'];
    final validStorage =
        (journalVersion is num &&
            journalVersion.toInt() == 2 &&
            json['payloadEncoding'] == 'utf-8-json') ||
        (journalVersion is num &&
            journalVersion.toInt() == 3 &&
            json['payloadStorage'] == 'pending-file' &&
            payloadFile is String);
    if (!validStorage ||
        documentId is! String ||
        revision is! num ||
        updatedAt is! String ||
        payloadByteLength is! num ||
        payloadChecksum is! String) {
      throw const FormatException('Journal-v2-Kopfzeile ist ungültig.');
    }
    final parsedUpdatedAt = DateTime.tryParse(updatedAt);
    if (parsedUpdatedAt == null) {
      throw const FormatException('Journal-v2-Zeitstempel ist ungültig.');
    }
    return _JournalHeader(
      journalVersion: journalVersion.toInt(),
      documentId: documentId,
      revision: revision.toInt(),
      updatedAt: parsedUpdatedAt.toUtc(),
      payloadByteLength: payloadByteLength.toInt(),
      payloadChecksum: payloadChecksum,
      payloadFile: payloadFile as String?,
    );
  }
}

final class _JournalPrefix {
  const _JournalPrefix({required this.header, required this.payloadOffset});

  final _JournalHeader header;
  final int? payloadOffset;
}

extension on DocumentSummary {
  DocumentSummary copyWithRecovery(bool recoveryAvailable) => DocumentSummary(
    id: id,
    title: title,
    updatedAt: updatedAt,
    pageCount: pageCount,
    revision: revision,
    thumbnailAssetId: thumbnailAssetId,
    recoveryAvailable: recoveryAvailable,
  );
}

bool _sameFileStamp(FileStat first, FileStat second) =>
    first.type == second.type &&
    first.size == second.size &&
    first.modified == second.modified;

WhiteboardDocument _decodeJournalPayload(
  _JournalHeader header,
  String payload,
  bool prettyPrint,
) {
  final fingerprint = _utf8Fingerprint(payload);
  if (header.payloadByteLength != fingerprint.byteLength ||
      header.payloadChecksum != fingerprint.checksum) {
    throw const FormatException('Journal-Prüfsumme stimmt nicht überein.');
  }

  final document = DocumentCodec(prettyPrint: prettyPrint).decode(payload);
  if (header.documentId != document.id ||
      header.revision != document.revision ||
      header.updatedAt != document.updatedAt) {
    throw const FormatException(
      'Journal-Kopfzeile und Dokumentdaten stimmen nicht überein.',
    );
  }
  return document;
}

String _checksum(String source) => _utf8Fingerprint(source).checksum;

final class _Utf8Fingerprint {
  const _Utf8Fingerprint(this.checksum, this.byteLength);

  final String checksum;
  final int byteLength;
}

_Utf8Fingerprint _utf8Fingerprint(String source) {
  final sink = _FnvByteSink();
  final encoder = utf8.encoder.startChunkedConversion(sink);
  if (source.isEmpty) {
    encoder.close();
  } else {
    const chunkLength = 64 * 1024;
    for (var start = 0; start < source.length; start += chunkLength) {
      final end = start + chunkLength < source.length
          ? start + chunkLength
          : source.length;
      encoder.addSlice(source, start, end, end == source.length);
    }
  }
  return _Utf8Fingerprint(
    sink.hash.toRadixString(16).padLeft(8, '0'),
    sink.byteLength,
  );
}

_Utf8Fingerprint _byteFingerprint(Uint8List bytes) {
  var hash = 0x811C9DC5;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return _Utf8Fingerprint(hash.toRadixString(16).padLeft(8, '0'), bytes.length);
}

final class _FnvByteSink extends ByteConversionSinkBase {
  var hash = 0x811C9DC5;
  var byteLength = 0;

  @override
  void add(List<int> chunk) {
    byteLength += chunk.length;
    for (final byte in chunk) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
  }

  @override
  void close() {}
}
