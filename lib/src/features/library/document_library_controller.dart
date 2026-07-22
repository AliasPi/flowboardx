import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../data/document_repository.dart';
import '../../domain/model/document.dart';
import '../../domain/model/library_organization.dart';

typedef DocumentIdFactory = String Function();
typedef FolderIdFactory = String Function();
typedef DocumentLibraryClock = DateTime Function();

enum DocumentLibraryStatus { idle, loading, ready, error }

@immutable
class DocumentLibraryEntry {
  const DocumentLibraryEntry({
    required this.summary,
    this.previewPage,
    this.wasRecovered = false,
    this.previewError,
  });

  final DocumentSummary summary;
  final BoardPage? previewPage;
  final bool wasRecovered;
  final String? previewError;
}

@immutable
class DocumentLibraryOpenResult {
  const DocumentLibraryOpenResult({
    required this.document,
    required this.assetDirectory,
    required this.recovered,
  });

  final WhiteboardDocument document;
  final Directory assetDirectory;
  final bool recovered;
}

/// Asynchronous state holder for the document overview. It deliberately does
/// not depend on navigation or dialogs, which keeps repository behavior easy to
/// test and lets the screen remain a replaceable presentation layer.
class DocumentLibraryController extends ChangeNotifier {
  DocumentLibraryController({
    required this.repository,
    DocumentIdFactory? documentIdFactory,
    FolderIdFactory? folderIdFactory,
    DocumentLibraryClock? clock,
    this.previewConcurrency = 4,
  }) : assert(previewConcurrency > 0),
       _documentIdFactory = documentIdFactory ?? _newDocumentId,
       _folderIdFactory = folderIdFactory ?? _newDocumentId,
       _clock = clock ?? DateTime.now;

  final DocumentRepository repository;
  final int previewConcurrency;
  final DocumentIdFactory _documentIdFactory;
  final FolderIdFactory _folderIdFactory;
  final DocumentLibraryClock _clock;

  DocumentLibraryStatus _status = DocumentLibraryStatus.idle;
  List<DocumentLibraryEntry> _entries = const <DocumentLibraryEntry>[];
  String? _loadError;
  String? _operationError;
  bool _creating = false;
  bool _organizing = false;
  final Set<String> _busyDocumentIds = <String>{};
  final Set<String> _selectedDocumentIds = <String>{};
  LibraryOrganization _organization = LibraryOrganization.empty;
  String? _activeFolderId;
  var _loadGeneration = 0;
  var _disposed = false;

  DocumentLibraryStatus get status => _status;
  List<DocumentLibraryEntry> get entries => _entries;
  String? get loadError => _loadError;
  String? get operationError => _operationError;
  bool get isCreating => _creating;
  bool get isOrganizing => _organizing;
  Set<String> get busyDocumentIds => Set.unmodifiable(_busyDocumentIds);
  Set<String> get selectedDocumentIds =>
      Set<String>.unmodifiable(_selectedDocumentIds);
  bool get hasSelection => _selectedDocumentIds.isNotEmpty;
  List<LibraryFolder> get folders => _organization.folders;
  String? get activeFolderId => _activeFolderId;
  LibraryFolder? get activeFolder => folderById(_activeFolderId);
  List<DocumentLibraryEntry> get visibleEntries => List.unmodifiable(
    _entries.where(
      (entry) =>
          _organization.documentFolderIds[entry.summary.id] == _activeFolderId,
    ),
  );

  int documentCountInFolder(String folderId) => _entries
      .where(
        (entry) =>
            _organization.documentFolderIds[entry.summary.id] == folderId,
      )
      .length;

  LibraryFolder? folderById(String? id) {
    if (id == null) return null;
    for (final folder in _organization.folders) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  String? folderIdForDocument(String documentId) =>
      _organization.documentFolderIds[documentId];

  bool isBusy(String documentId) => _busyDocumentIds.contains(documentId);

  void openFolder(String? folderId) {
    if (folderId != null && folderById(folderId) == null) return;
    if (_activeFolderId == folderId && _selectedDocumentIds.isEmpty) return;
    _activeFolderId = folderId;
    _selectedDocumentIds.clear();
    _safeNotify();
  }

  void toggleDocumentSelection(String documentId) {
    if (_entryById(documentId) == null || isBusy(documentId)) return;
    if (!_selectedDocumentIds.remove(documentId)) {
      _selectedDocumentIds.add(documentId);
    }
    _safeNotify();
  }

  void selectDocument(String documentId) {
    if (_entryById(documentId) == null || isBusy(documentId)) return;
    if (_selectedDocumentIds.add(documentId)) _safeNotify();
  }

  /// Makes a directly dragged, previously unselected card the sole selection.
  ///
  /// Desktop file managers follow the same rule: dragging outside the current
  /// selection moves that item alone. Keeping the visual selection identical
  /// to the immutable drag payload avoids moving one document while the UI
  /// appears to promise that several documents will be moved.
  void selectOnlyDocument(String documentId) {
    if (_entryById(documentId) == null || isBusy(documentId)) return;
    if (_selectedDocumentIds.length == 1 &&
        _selectedDocumentIds.contains(documentId)) {
      return;
    }
    _selectedDocumentIds
      ..clear()
      ..add(documentId);
    _safeNotify();
  }

  void selectAllVisible() {
    var changed = false;
    for (final entry in visibleEntries) {
      changed = _selectedDocumentIds.add(entry.summary.id) || changed;
    }
    if (changed) _safeNotify();
  }

  void clearSelection() {
    if (_selectedDocumentIds.isEmpty) return;
    _selectedDocumentIds.clear();
    _safeNotify();
  }

  Future<LibraryFolder?> createFolder(String name) async {
    final normalized = name.trim();
    if (!_validateFolderName(normalized)) return null;
    if (_organizing) return null;
    _organizing = true;
    _operationError = null;
    _safeNotify();
    try {
      final now = _clock().toUtc();
      final folder = LibraryFolder(
        id: _folderIdFactory(),
        name: normalized,
        createdAt: now,
        updatedAt: now,
      );
      final next = LibraryOrganization(
        folders: <LibraryFolder>[..._organization.folders, folder],
        documentFolderIds: _organization.documentFolderIds,
      ).normalized();
      await _saveOrganization(next);
      _organization = next;
      return folder;
    } catch (error) {
      _operationError = _messageFor(
        error,
        fallback: 'Der Ordner konnte nicht erstellt werden.',
      );
      return null;
    } finally {
      _organizing = false;
      _safeNotify();
    }
  }

  Future<bool> renameFolder(String folderId, String name) async {
    final normalized = name.trim();
    if (!_validateFolderName(normalized, exceptFolderId: folderId)) {
      return false;
    }
    final existing = folderById(folderId);
    if (existing == null || _organizing) return false;
    if (existing.name == normalized) return true;
    _organizing = true;
    _operationError = null;
    _safeNotify();
    try {
      final next = LibraryOrganization(
        folders: _organization.folders
            .map(
              (folder) => folder.id == folderId
                  ? folder.copyWith(
                      name: normalized,
                      updatedAt: _clock().toUtc(),
                    )
                  : folder,
            )
            .toList(growable: false),
        documentFolderIds: _organization.documentFolderIds,
      ).normalized();
      await _saveOrganization(next);
      _organization = next;
      return true;
    } catch (error) {
      _operationError = _messageFor(
        error,
        fallback: 'Der Ordner konnte nicht umbenannt werden.',
      );
      return false;
    } finally {
      _organizing = false;
      _safeNotify();
    }
  }

  /// Removes only the folder entry. Its documents are moved to the root so a
  /// mistaken folder deletion can never delete board data.
  Future<bool> deleteFolder(String folderId) async {
    if (folderById(folderId) == null || _organizing) return false;
    _organizing = true;
    _operationError = null;
    _safeNotify();
    try {
      final assignments = Map<String, String>.from(
        _organization.documentFolderIds,
      )..removeWhere((_, assignedFolder) => assignedFolder == folderId);
      final next = LibraryOrganization(
        folders: _organization.folders
            .where((folder) => folder.id != folderId)
            .toList(growable: false),
        documentFolderIds: assignments,
      ).normalized();
      await _saveOrganization(next);
      _organization = next;
      if (_activeFolderId == folderId) _activeFolderId = null;
      _selectedDocumentIds.clear();
      return true;
    } catch (error) {
      _operationError = _messageFor(
        error,
        fallback: 'Der Ordner konnte nicht gelöscht werden.',
      );
      return false;
    } finally {
      _organizing = false;
      _safeNotify();
    }
  }

  Future<bool> moveDocuments(
    Iterable<String> documentIds,
    String? folderId,
  ) async {
    final ids = documentIds.toSet();
    if (ids.isEmpty || _organizing) return false;
    if (folderId != null && folderById(folderId) == null) {
      _operationError = 'Der Zielordner wurde nicht gefunden.';
      _safeNotify();
      return false;
    }
    final existingIds = _entries.map((entry) => entry.summary.id).toSet();
    if (!existingIds.containsAll(ids)) {
      _operationError = 'Mindestens ein Dokument wurde nicht gefunden.';
      _safeNotify();
      return false;
    }
    _organizing = true;
    _operationError = null;
    _safeNotify();
    try {
      final assignments = Map<String, String>.from(
        _organization.documentFolderIds,
      );
      for (final id in ids) {
        if (folderId == null) {
          assignments.remove(id);
        } else {
          assignments[id] = folderId;
        }
      }
      final next = LibraryOrganization(
        folders: _organization.folders,
        documentFolderIds: assignments,
      ).normalized(existingDocumentIds: existingIds);
      await _saveOrganization(next);
      _organization = next;
      _selectedDocumentIds.clear();
      return true;
    } catch (error) {
      _operationError = _messageFor(
        error,
        fallback: 'Die Dokumente konnten nicht verschoben werden.',
      );
      return false;
    } finally {
      _organizing = false;
      _safeNotify();
    }
  }

  Future<void> reload() async {
    final generation = ++_loadGeneration;
    _status = DocumentLibraryStatus.loading;
    _loadError = null;
    _safeNotify();
    try {
      final summaries = (await repository.list()).toList(growable: false)
        ..sort((first, second) => second.updatedAt.compareTo(first.updatedAt));
      if (!_isCurrent(generation)) return;
      final loadedOrganization = await _loadOrganization();
      if (!_isCurrent(generation)) return;
      _organization = loadedOrganization.normalized(
        existingDocumentIds: summaries.map((item) => item.id).toSet(),
      );
      if (_activeFolderId != null && folderById(_activeFolderId) == null) {
        _activeFolderId = null;
      }
      _selectedDocumentIds.removeWhere(
        (id) => !summaries.any((summary) => summary.id == id),
      );
      final priorEntries = <String, DocumentLibraryEntry>{
        for (final entry in _entries) entry.summary.id: entry,
      };
      _entries = List.unmodifiable(
        summaries.map((summary) {
          final prior = priorEntries[summary.id];
          if (prior == null || prior.summary.revision != summary.revision) {
            return DocumentLibraryEntry(summary: summary);
          }
          return DocumentLibraryEntry(
            summary: summary,
            previewPage: prior.previewPage,
            wasRecovered: prior.wasRecovered,
            previewError: prior.previewError,
          );
        }),
      );
      _safeNotify();
      final hydrated = await _hydrate(summaries, generation);
      if (!_isCurrent(generation)) return;
      _entries = List.unmodifiable(hydrated);
      _status = DocumentLibraryStatus.ready;
      _safeNotify();
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _loadError = _messageFor(
        error,
        fallback: 'Dokumente konnten nicht geladen werden.',
      );
      _status = DocumentLibraryStatus.error;
      _safeNotify();
    }
  }

  Future<DocumentLibraryOpenResult?> createDocument({
    String title = 'Unbenanntes Whiteboard',
  }) async {
    if (_creating) return null;
    _creating = true;
    _operationError = null;
    _safeNotify();
    try {
      final id = _documentIdFactory();
      if (id.trim().isEmpty) {
        throw const DocumentStorageException(
          'Das neue Dokument konnte keine gültige ID erhalten.',
        );
      }
      final document = WhiteboardDocument.create(
        id: id,
        title: _normalizedTitle(title),
        now: _clock().toUtc(),
      );
      await repository.save(document);
      final directory = await repository.assetDirectory(document.id);
      _upsert(document, recoveryAvailable: false);
      await _assignCreatedDocument(document.id);
      return DocumentLibraryOpenResult(
        document: document,
        assetDirectory: directory,
        recovered: false,
      );
    } catch (error) {
      _operationError = _messageFor(
        error,
        fallback: 'Das neue Whiteboard konnte nicht erstellt werden.',
      );
      return null;
    } finally {
      _creating = false;
      _safeNotify();
    }
  }

  Future<DocumentLibraryOpenResult?> openDocument(String documentId) async {
    if (!_beginDocumentOperation(documentId)) return null;
    try {
      final entry = _entryById(documentId);
      final requestedRecovery = entry?.summary.recoveryAvailable ?? false;
      WhiteboardDocument? document;
      if (requestedRecovery) {
        document = await repository.recover(documentId);
      } else {
        document = await repository.load(documentId);
        document ??= await repository.recover(documentId);
      }
      if (document == null) {
        throw DocumentStorageException(
          'Das Dokument „${entry?.summary.title ?? documentId}“ wurde nicht gefunden.',
        );
      }
      final directory = await repository.assetDirectory(documentId);
      final recovered =
          requestedRecovery || document.metadata.recoveredFromCrash;
      _upsert(document, recoveryAvailable: false);
      return DocumentLibraryOpenResult(
        document: document,
        assetDirectory: directory,
        recovered: recovered,
      );
    } catch (error) {
      _operationError = _messageFor(
        error,
        fallback: 'Das Dokument konnte nicht geöffnet werden.',
      );
      return null;
    } finally {
      _endDocumentOperation(documentId);
    }
  }

  Future<bool> renameDocument(String documentId, String title) async {
    final normalized = title.trim();
    if (normalized.isEmpty) {
      _operationError = 'Der Dokumentname darf nicht leer sein.';
      _safeNotify();
      return false;
    }
    if (!_beginDocumentOperation(documentId)) return false;
    try {
      final entry = _entryById(documentId);
      WhiteboardDocument? document = entry?.summary.recoveryAvailable == true
          ? await repository.recover(documentId)
          : await repository.load(documentId);
      document ??= await repository.recover(documentId);
      if (document == null) {
        throw const DocumentStorageException(
          'Das Dokument wurde nicht gefunden.',
        );
      }
      if (document.title == normalized) return true;
      final renamed = document.copyWith(
        title: normalized,
        updatedAt: _clock().toUtc(),
        revision: document.revision + 1,
      );
      await repository.save(renamed);
      _upsert(renamed, recoveryAvailable: false);
      return true;
    } catch (error) {
      _operationError = _messageFor(
        error,
        fallback: 'Das Dokument konnte nicht umbenannt werden.',
      );
      return false;
    } finally {
      _endDocumentOperation(documentId);
    }
  }

  Future<bool> deleteDocument(String documentId) async {
    final deleted = await deleteDocuments(<String>{documentId});
    return deleted.contains(documentId);
  }

  /// Deletes every requested document independently. Successfully deleted
  /// documents stay deleted even if another item fails; the returned IDs let
  /// callers report an exact result without repeating a destructive action.
  Future<Set<String>> deleteDocuments(Iterable<String> documentIds) async {
    final ids = documentIds
        .where((id) => _entryById(id) != null && !isBusy(id))
        .toSet();
    if (ids.isEmpty) return const <String>{};
    _operationError = null;
    _busyDocumentIds.addAll(ids);
    _safeNotify();
    final deleted = <String>{};
    Object? firstError;
    try {
      for (final id in ids) {
        try {
          await repository.delete(id);
          deleted.add(id);
        } catch (error) {
          firstError ??= error;
        }
      }
      if (deleted.isNotEmpty) {
        _loadGeneration++;
        _entries = List.unmodifiable(
          _entries.where((entry) => !deleted.contains(entry.summary.id)),
        );
        _selectedDocumentIds.removeAll(deleted);
        final assignments = Map<String, String>.from(
          _organization.documentFolderIds,
        );
        for (final id in deleted) {
          assignments.remove(id);
        }
        final next =
            LibraryOrganization(
              folders: _organization.folders,
              documentFolderIds: assignments,
            ).normalized(
              existingDocumentIds: _entries
                  .map((entry) => entry.summary.id)
                  .toSet(),
            );
        try {
          await _saveOrganization(next);
          _organization = next;
        } catch (error) {
          // Stale assignments are harmless and normalized on the next load.
          // Never retry an already successful destructive operation.
          firstError ??= error;
        }
        _status = DocumentLibraryStatus.ready;
      }
      if (firstError != null) {
        _operationError = _messageFor(
          firstError,
          fallback: deleted.isEmpty
              ? 'Die Dokumente konnten nicht gelöscht werden.'
              : '${deleted.length} Dokumente wurden gelöscht; mindestens eines konnte nicht gelöscht werden.',
        );
      }
      return Set<String>.unmodifiable(deleted);
    } finally {
      _busyDocumentIds.removeAll(ids);
      _safeNotify();
    }
  }

  void clearOperationError() {
    if (_operationError == null) return;
    _operationError = null;
    _safeNotify();
  }

  void clearLoadError() {
    if (_loadError == null) return;
    _loadError = null;
    if (_status == DocumentLibraryStatus.error && _entries.isNotEmpty) {
      _status = DocumentLibraryStatus.ready;
    }
    _safeNotify();
  }

  Future<LibraryOrganization> _loadOrganization() async {
    if (repository is! DocumentOrganizationRepository) {
      return LibraryOrganization.empty;
    }
    final organizationRepository = repository as DocumentOrganizationRepository;
    try {
      return await organizationRepository.loadOrganization();
    } catch (error) {
      // A damaged optional index must never hide or block the documents. They
      // remain accessible at the library root while the error is visible.
      _operationError = _messageFor(
        error,
        fallback:
            'Die Ordnerstruktur konnte nicht geladen werden. Die Dokumente bleiben erhalten.',
      );
      return LibraryOrganization.empty;
    }
  }

  Future<void> _saveOrganization(LibraryOrganization organization) async {
    if (repository is! DocumentOrganizationRepository) return;
    await (repository as DocumentOrganizationRepository).saveOrganization(
      organization,
    );
  }

  Future<void> _assignCreatedDocument(String documentId) async {
    final folderId = _activeFolderId;
    if (folderId == null || folderById(folderId) == null) return;
    final assignments = Map<String, String>.from(
      _organization.documentFolderIds,
    )..[documentId] = folderId;
    final next =
        LibraryOrganization(
          folders: _organization.folders,
          documentFolderIds: assignments,
        ).normalized(
          existingDocumentIds: _entries.map((e) => e.summary.id).toSet(),
        );
    try {
      await _saveOrganization(next);
      _organization = next;
    } catch (error) {
      // The new document already exists safely. Leave it at the root instead
      // of making the caller retry creation and produce a duplicate.
      _operationError = _messageFor(
        error,
        fallback:
            'Das Whiteboard wurde erstellt, konnte aber keinem Ordner zugeordnet werden.',
      );
      _activeFolderId = null;
    }
  }

  bool _validateFolderName(String name, {String? exceptFolderId}) {
    if (name.isEmpty) {
      _operationError = 'Der Ordnername darf nicht leer sein.';
      _safeNotify();
      return false;
    }
    if (name.length > 120) {
      _operationError = 'Der Ordnername darf höchstens 120 Zeichen enthalten.';
      _safeNotify();
      return false;
    }
    final duplicate = _organization.folders.any(
      (folder) =>
          folder.id != exceptFolderId &&
          folder.name.toLowerCase() == name.toLowerCase(),
    );
    if (duplicate) {
      _operationError = 'Ein Ordner mit diesem Namen existiert bereits.';
      _safeNotify();
      return false;
    }
    return true;
  }

  bool _beginDocumentOperation(String documentId) {
    if (_busyDocumentIds.contains(documentId)) return false;
    _busyDocumentIds.add(documentId);
    _operationError = null;
    _safeNotify();
    return true;
  }

  void _endDocumentOperation(String documentId) {
    _busyDocumentIds.remove(documentId);
    _safeNotify();
  }

  Future<List<DocumentLibraryEntry>> _hydrate(
    List<DocumentSummary> summaries,
    int generation,
  ) async {
    if (summaries.isEmpty) return const <DocumentLibraryEntry>[];
    final results = List<DocumentLibraryEntry?>.filled(summaries.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (_isCurrent(generation)) {
        final index = nextIndex++;
        if (index >= summaries.length) return;
        final summary = summaries[index];
        try {
          final document = await repository.load(summary.id);
          results[index] = DocumentLibraryEntry(
            summary: summary,
            previewPage: document == null
                ? null
                : document.pages[document.currentPageIndex],
            wasRecovered: document?.metadata.recoveredFromCrash ?? false,
            previewError: document == null ? 'Dokument nicht gefunden' : null,
          );
        } catch (error) {
          results[index] = DocumentLibraryEntry(
            summary: summary,
            previewError: _messageFor(
              error,
              fallback: 'Vorschau nicht verfügbar',
            ),
          );
        }
      }
    }

    final workers = mathMin(previewConcurrency, summaries.length);
    await Future.wait(List<Future<void>>.generate(workers, (_) => worker()));
    return List<DocumentLibraryEntry>.generate(
      summaries.length,
      (index) =>
          results[index] ?? DocumentLibraryEntry(summary: summaries[index]),
      growable: false,
    );
  }

  void _upsert(WhiteboardDocument document, {required bool recoveryAvailable}) {
    final next =
        _entries
            .where((entry) => entry.summary.id != document.id)
            .toList(growable: true)
          ..add(
            DocumentLibraryEntry(
              summary: DocumentSummary.fromDocument(
                document,
                recoveryAvailable: recoveryAvailable,
              ),
              previewPage: document.pages[document.currentPageIndex],
              wasRecovered: document.metadata.recoveredFromCrash,
            ),
          )
          ..sort(
            (first, second) =>
                second.summary.updatedAt.compareTo(first.summary.updatedAt),
          );
    _entries = List.unmodifiable(next);
    _loadGeneration++;
    _status = DocumentLibraryStatus.ready;
    _loadError = null;
    _safeNotify();
  }

  DocumentLibraryEntry? _entryById(String id) {
    for (final entry in _entries) {
      if (entry.summary.id == id) return entry;
    }
    return null;
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _loadGeneration;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration++;
    super.dispose();
  }
}

String _normalizedTitle(String title) {
  final normalized = title.trim();
  return normalized.isEmpty ? 'Unbenanntes Whiteboard' : normalized;
}

String _messageFor(Object error, {required String fallback}) {
  if (error case DocumentStorageException(:final message)) return message;
  return fallback;
}

int mathMin(int first, int second) => first < second ? first : second;

String _newDocumentId() => const Uuid().v4();
