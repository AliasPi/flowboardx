import 'dart:async';
import 'dart:collection';
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
    this.previewConcurrency = 2,
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
  String? _trashError;
  bool _creating = false;
  bool _organizing = false;
  bool _trashLoading = false;
  final Set<String> _busyDocumentIds = <String>{};
  final Set<String> _busyTrashDocumentIds = <String>{};
  final Set<String> _selectedDocumentIds = <String>{};
  final Queue<String> _previewQueue = Queue<String>();
  final Set<String> _requestedPreviews = <String>{};
  final Map<String, int> _mountedPreviewCounts = <String, int>{};
  final LinkedHashSet<String> _cachedPreviews = LinkedHashSet<String>();
  static const int _maximumCachedPreviews = 24;
  int _activePreviewLoads = 0;
  int _previewGeneration = 0;
  List<DocumentLibraryEntry>? _visibleEntriesCache;
  Map<String, int>? _folderCountsCache;
  LibraryOrganization _organization = LibraryOrganization.empty;
  List<TrashedDocumentSummary> _trashedDocuments =
      const <TrashedDocumentSummary>[];
  String? _activeFolderId;
  var _loadGeneration = 0;
  var _trashLoadGeneration = 0;
  var _disposed = false;

  DocumentLibraryStatus get status => _status;
  List<DocumentLibraryEntry> get entries => _entries;
  String? get loadError => _loadError;
  String? get operationError => _operationError;
  String? get trashError => _trashError;
  bool get isCreating => _creating;
  bool get isOrganizing => _organizing;
  bool get isTrashLoading => _trashLoading;
  bool get trashSupported => repository is DocumentTrashRepository;
  List<TrashedDocumentSummary> get trashedDocuments => _trashedDocuments;
  Set<String> get busyDocumentIds => Set.unmodifiable(_busyDocumentIds);
  Set<String> get busyTrashDocumentIds =>
      Set.unmodifiable(_busyTrashDocumentIds);
  Set<String> get selectedDocumentIds =>
      Set<String>.unmodifiable(_selectedDocumentIds);
  bool get hasSelection => _selectedDocumentIds.isNotEmpty;
  List<LibraryFolder> get folders => _organization.folders;
  String? get activeFolderId => _activeFolderId;
  LibraryFolder? get activeFolder => folderById(_activeFolderId);
  List<DocumentLibraryEntry> get visibleEntries =>
      _visibleEntriesCache ??= List<DocumentLibraryEntry>.unmodifiable(
        _entries.where(
          (entry) =>
              _organization.documentFolderIds[entry.summary.id] ==
              _activeFolderId,
        ),
      );

  int documentCountInFolder(String folderId) {
    return (_folderCountsCache ??= _countDocumentsByFolder())[folderId] ?? 0;
  }

  Map<String, int> _countDocumentsByFolder() {
    final counts = <String, int>{};
    for (final entry in _entries) {
      final folderId = _organization.documentFolderIds[entry.summary.id];
      if (folderId != null) counts[folderId] = (counts[folderId] ?? 0) + 1;
    }
    return counts;
  }

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

  bool isTrashBusy(String documentId) =>
      _busyTrashDocumentIds.contains(documentId);

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
    _cancelPreviewRequests();
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
      final existingIds = summaries.map((summary) => summary.id).toSet();
      _selectedDocumentIds.removeWhere((id) => !existingIds.contains(id));
      final priorEntries = <String, DocumentLibraryEntry>{
        for (final entry in _entries) entry.summary.id: entry,
      };
      _cancelPreviewRequests();
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
      _rememberExistingPreviews();
      _status = DocumentLibraryStatus.ready;
      _safeNotify();
      await reloadTrash();
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _loadError = _messageFor(
        error,
        fallback: 'Dokumente konnten nicht geladen werden.',
      );
      _status = DocumentLibraryStatus.error;
      _safeNotify();
      await reloadTrash();
    }
  }

  /// Loads only previews whose cards have actually entered the sliver viewport.
  /// Opening the library must not decode every page of every saved document.
  void retainPreview(String documentId) {
    _mountedPreviewCounts[documentId] =
        (_mountedPreviewCounts[documentId] ?? 0) + 1;
  }

  void releasePreview(String documentId) {
    final count = _mountedPreviewCounts[documentId] ?? 0;
    if (count <= 1) {
      _mountedPreviewCounts.remove(documentId);
      if (_previewQueue.remove(documentId)) {
        _requestedPreviews.remove(documentId);
      }
    } else {
      _mountedPreviewCounts[documentId] = count - 1;
    }
  }

  void requestPreview(String documentId) {
    final entry = _entryById(documentId);
    if (entry == null ||
        entry.previewPage != null ||
        entry.previewError != null ||
        !_requestedPreviews.add(documentId)) {
      return;
    }
    _previewQueue.add(documentId);
    _pumpPreviewQueue();
  }

  void _pumpPreviewQueue() {
    while (!_disposed &&
        _activePreviewLoads < previewConcurrency &&
        _previewQueue.isNotEmpty) {
      final id = _previewQueue.removeFirst();
      final entry = _entryById(id);
      if (entry == null) continue;
      _activePreviewLoads++;
      unawaited(_loadPreview(id, entry.summary.revision, _previewGeneration));
    }
  }

  Future<void> _loadPreview(String id, int revision, int generation) async {
    BoardPage? page;
    String? error;
    bool recovered = false;
    try {
      final document = await repository.load(id);
      if (document == null) {
        error = 'Dokument nicht gefunden';
      } else {
        page = document.pages[document.currentPageIndex];
        recovered = document.metadata.recoveredFromCrash;
      }
    } catch (exception) {
      error = _messageFor(exception, fallback: 'Vorschau nicht verfügbar');
    } finally {
      if (!_disposed && generation == _previewGeneration) {
        final index = _entries.indexWhere((entry) => entry.summary.id == id);
        if (index >= 0 && _entries[index].summary.revision == revision) {
          final next = _entries.toList(growable: false);
          next[index] = DocumentLibraryEntry(
            summary: next[index].summary,
            previewPage: page,
            wasRecovered: recovered,
            previewError: error,
          );
          if (page != null) {
            _cachedPreviews.remove(id);
            _cachedPreviews.add(id);
            while (_cachedPreviews.length > _maximumCachedPreviews) {
              // A 4K board can show more cards than the cache target at once.
              // Never evict a mounted card or its widget will immediately
              // request the same document again in an endless load loop.
              final evicted = _cachedPreviews.firstWhere(
                (candidate) => !_mountedPreviewCounts.containsKey(candidate),
                orElse: () => '',
              );
              if (evicted.isEmpty) break;
              _cachedPreviews.remove(evicted);
              _requestedPreviews.remove(evicted);
              final evictedIndex = next.indexWhere(
                (entry) => entry.summary.id == evicted,
              );
              if (evictedIndex >= 0) {
                next[evictedIndex] = DocumentLibraryEntry(
                  summary: next[evictedIndex].summary,
                );
              }
            }
          }
          _entries = List.unmodifiable(next);
          _safeNotify();
        }
        _activePreviewLoads--;
        _pumpPreviewQueue();
      }
    }
  }

  void _cancelPreviewRequests() {
    _previewGeneration++;
    _previewQueue.clear();
    _requestedPreviews.clear();
    _cachedPreviews.clear();
    _activePreviewLoads = 0;
  }

  void _rememberExistingPreviews() {
    for (final entry in _entries) {
      if (entry.previewPage != null) _cachedPreviews.add(entry.summary.id);
    }
  }

  Future<void> reloadTrash() async {
    final generation = ++_trashLoadGeneration;
    if (repository is! DocumentTrashRepository) {
      _trashedDocuments = const <TrashedDocumentSummary>[];
      _trashError = null;
      _trashLoading = false;
      return;
    }
    _trashLoading = true;
    _trashError = null;
    _safeNotify();
    try {
      final items =
          (await (repository as DocumentTrashRepository).listTrashed()).toList(
            growable: true,
          );
      if (_disposed || generation != _trashLoadGeneration) return;
      items.sort((first, second) {
        final deleted = second.deletedAt.compareTo(first.deletedAt);
        return deleted != 0 ? deleted : first.id.compareTo(second.id);
      });
      _trashedDocuments = List<TrashedDocumentSummary>.unmodifiable(items);
    } catch (error) {
      if (_disposed || generation != _trashLoadGeneration) return;
      _trashError = _messageFor(
        error,
        fallback: 'Der Papierkorb konnte nicht geladen werden.',
      );
    } finally {
      if (!_disposed && generation == _trashLoadGeneration) {
        _trashLoading = false;
        _safeNotify();
      }
    }
  }

  /// Makes every snapshot started before this point ineligible to publish.
  ///
  /// Trash mutations and reloads use different repository calls, so a slow
  /// list request can otherwise overwrite a newer local move/restore/delete.
  /// Resetting the loading flag also prevents an invalidated request's guarded
  /// `finally` block from leaving the UI permanently busy.
  void _invalidateTrashReload() {
    _trashLoadGeneration++;
    _trashLoading = false;
  }

  Future<DocumentLibraryOpenResult?> createDocument({String? title}) async {
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
      final creationTime = _clock();
      final normalizedTitle = title?.trim();
      final document = WhiteboardDocument.create(
        id: id,
        title: normalizedTitle == null || normalizedTitle.isEmpty
            ? null
            : normalizedTitle,
        now: creationTime,
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
    final movedToTrash = <TrashedDocumentSummary>[];
    final trashRepository = repository is DocumentTrashRepository
        ? repository as DocumentTrashRepository
        : null;
    if (trashRepository != null) _invalidateTrashReload();
    Object? firstError;
    try {
      for (final id in ids) {
        try {
          if (trashRepository == null) {
            await repository.delete(id);
          } else {
            movedToTrash.add(
              await trashRepository.moveToTrash(
                id,
                originalFolderId: _organization.documentFolderIds[id],
              ),
            );
          }
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
        _cancelPreviewRequests();
        _rememberExistingPreviews();
        if (movedToTrash.isNotEmpty) {
          // Also reject a reload that began while the filesystem mutations
          // were in flight and may have captured only part of the batch.
          _invalidateTrashReload();
          final movedIds = movedToTrash.map((item) => item.id).toSet();
          final nextTrash =
              _trashedDocuments
                  .where((item) => !movedIds.contains(item.id))
                  .toList(growable: true)
                ..addAll(movedToTrash)
                ..sort((first, second) {
                  final deletedAt = second.deletedAt.compareTo(first.deletedAt);
                  return deletedAt != 0
                      ? deletedAt
                      : first.id.compareTo(second.id);
                });
          _trashedDocuments = List<TrashedDocumentSummary>.unmodifiable(
            nextTrash,
          );
        }
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
        } catch (error) {
          // Stale assignments are harmless and normalized on the next load.
          // Never retry an already successful destructive operation.
          firstError ??= error;
        }
        // The filesystem operation already succeeded. Keep in-memory state
        // consistent even if the optional folder index could not be updated;
        // the trash sidecar retains the original assignment for restoration.
        _organization = next;
        _status = DocumentLibraryStatus.ready;
      }
      if (firstError != null) {
        _operationError = _messageFor(
          firstError,
          fallback: deleted.isEmpty
              ? trashRepository == null
                    ? 'Die Dokumente konnten nicht gelöscht werden.'
                    : 'Die Dokumente konnten nicht in den Papierkorb verschoben werden.'
              : trashRepository == null
              ? '${deleted.length} Dokumente wurden gelöscht; mindestens eines konnte nicht gelöscht werden.'
              : '${deleted.length} Dokumente wurden in den Papierkorb verschoben; mindestens eines konnte nicht verschoben werden.',
        );
      }
      return Set<String>.unmodifiable(deleted);
    } finally {
      _busyDocumentIds.removeAll(ids);
      _safeNotify();
    }
  }

  Future<bool> restoreTrashedDocument(String documentId) async {
    if (repository is! DocumentTrashRepository ||
        isTrashBusy(documentId) ||
        _entryById(documentId) != null) {
      if (_entryById(documentId) != null) {
        _operationError =
            'Ein aktives Dokument mit derselben ID verhindert die Wiederherstellung.';
        _safeNotify();
      }
      return false;
    }
    final summary = _trashedEntryById(documentId);
    if (summary == null || !summary.recoverable) return false;
    _busyTrashDocumentIds.add(documentId);
    _invalidateTrashReload();
    _operationError = null;
    _safeNotify();
    final priorOrganization = _organization;
    final validOriginalFolderId = folderById(summary.originalFolderId)?.id;
    final assignments = Map<String, String>.from(
      priorOrganization.documentFolderIds,
    );
    if (validOriginalFolderId == null) {
      assignments.remove(documentId);
    } else {
      assignments[documentId] = validOriginalFolderId;
    }
    final nextOrganization =
        LibraryOrganization(
          folders: priorOrganization.folders,
          documentFolderIds: assignments,
        ).normalized(
          existingDocumentIds: <String>{
            ..._entries.map((entry) => entry.summary.id),
            documentId,
          },
        );
    var organizationPrepared = false;
    try {
      // Persist the destination folder before the directory rename. A process
      // death immediately after restoration therefore cannot orphan the
      // recovered board from its still-existing original folder.
      await _saveOrganization(nextOrganization);
      organizationPrepared = true;
      final restored = await (repository as DocumentTrashRepository)
          .restoreFromTrash(documentId);
      _invalidateTrashReload();
      _organization = nextOrganization;
      _trashedDocuments = List<TrashedDocumentSummary>.unmodifiable(
        _trashedDocuments.where((item) => item.id != documentId),
      );
      _upsert(restored.document, recoveryAvailable: restored.recoveryAvailable);
      return true;
    } catch (error) {
      if (organizationPrepared) {
        try {
          await _saveOrganization(priorOrganization);
        } catch (_) {
          // A stale assignment cannot remove document data and is normalized
          // on the next library load. Preserve the restoration error below.
        }
      }
      _organization = priorOrganization;
      _operationError = _messageFor(
        error,
        fallback: 'Das Whiteboard konnte nicht wiederhergestellt werden.',
      );
      return false;
    } finally {
      _busyTrashDocumentIds.remove(documentId);
      _safeNotify();
    }
  }

  Future<bool> permanentlyDeleteTrashedDocument(String documentId) async {
    if (repository is! DocumentTrashRepository ||
        isTrashBusy(documentId) ||
        _trashedEntryById(documentId) == null) {
      return false;
    }
    _busyTrashDocumentIds.add(documentId);
    _invalidateTrashReload();
    _operationError = null;
    _safeNotify();
    try {
      await (repository as DocumentTrashRepository).deletePermanentlyFromTrash(
        documentId,
      );
      _invalidateTrashReload();
      _trashedDocuments = List<TrashedDocumentSummary>.unmodifiable(
        _trashedDocuments.where((item) => item.id != documentId),
      );
      return true;
    } catch (error) {
      _operationError = _messageFor(
        error,
        fallback: 'Das Whiteboard konnte nicht endgültig gelöscht werden.',
      );
      return false;
    } finally {
      _busyTrashDocumentIds.remove(documentId);
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

  void clearTrashError() {
    if (_trashError == null) return;
    _trashError = null;
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
    _cancelPreviewRequests();
    _rememberExistingPreviews();
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

  TrashedDocumentSummary? _trashedEntryById(String id) {
    for (final entry in _trashedDocuments) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _loadGeneration;

  void _safeNotify() {
    _visibleEntriesCache = null;
    _folderCountsCache = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration++;
    _trashLoadGeneration++;
    _cancelPreviewRequests();
    super.dispose();
  }
}

String _messageFor(Object error, {required String fallback}) {
  if (error case DocumentStorageException(:final message)) return message;
  return fallback;
}

String _newDocumentId() => const Uuid().v4();
