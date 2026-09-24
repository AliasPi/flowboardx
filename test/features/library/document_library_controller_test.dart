import 'dart:async';
import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/library_organization.dart';
import 'package:flowboard_x/src/features/library/document_library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory assets;
  late _FakeDocumentRepository repository;

  setUp(() {
    assets = Directory.systemTemp.createTempSync('flowboard-library-test-');
    repository = _FakeDocumentRepository(assets);
  });

  tearDown(() {
    if (assets.existsSync()) assets.deleteSync(recursive: true);
  });

  test(
    'reload is ready without decoding documents and previews are bounded',
    () async {
      final older = WhiteboardDocument.create(
        id: 'older',
        title: 'Älter',
        now: DateTime.utc(2025, 1, 1),
      );
      final newer = WhiteboardDocument.create(
        id: 'newer',
        title: 'Neuer',
        now: DateTime.utc(2026, 1, 1),
      );
      repository
        ..documents[older.id] = older
        ..documents[newer.id] = newer
        ..loadDelay = const Duration(milliseconds: 5);
      final controller = DocumentLibraryController(
        repository: repository,
        previewConcurrency: 1,
      );
      addTearDown(controller.dispose);

      await controller.reload();

      expect(controller.status, DocumentLibraryStatus.ready);
      expect(controller.entries.map((entry) => entry.summary.id), <String>[
        'newer',
        'older',
      ]);
      expect(repository.loadCalls, isEmpty);
      controller.requestPreview('newer');
      controller.requestPreview('older');
      await _waitForPreview(controller, 'older');
      expect(controller.entries.first.previewPage?.id, 'newer_page_1');
      expect(repository.maximumConcurrentLoads, 1);
    },
  );

  test('large libraries decode only explicitly requested previews', () async {
    for (var index = 0; index < 100; index++) {
      final document = WhiteboardDocument.create(id: 'board-$index');
      repository.documents[document.id] = document;
    }
    final controller = DocumentLibraryController(repository: repository);
    addTearDown(controller.dispose);

    await controller.reload();

    expect(controller.status, DocumentLibraryStatus.ready);
    expect(controller.entries, hasLength(100));
    expect(repository.loadCalls, isEmpty);
    controller.requestPreview('board-42');
    await _waitForPreview(controller, 'board-42');
    expect(repository.loadCalls, <String>['board-42']);
  });

  test(
    'previews use a bounded cache instead of retaining every board',
    () async {
      for (var index = 0; index < 30; index++) {
        final document = WhiteboardDocument.create(id: 'board-$index');
        repository.documents[document.id] = document;
      }
      final controller = DocumentLibraryController(repository: repository);
      addTearDown(controller.dispose);
      await controller.reload();

      for (var index = 0; index < 30; index++) {
        final id = 'board-$index';
        controller.requestPreview(id);
        await _waitForPreview(controller, id);
      }

      expect(
        controller.entries.where((entry) => entry.previewPage != null),
        hasLength(24),
      );
      expect(
        controller.entries
            .singleWhere((entry) => entry.summary.id == 'board-0')
            .previewPage,
        isNull,
      );
      controller.requestPreview('board-0');
      await _waitForPreview(controller, 'board-0');
      expect(repository.loadCalls.where((id) => id == 'board-0'), hasLength(2));
    },
  );

  test('mounted cards are not evicted on a large display', () async {
    for (var index = 0; index < 30; index++) {
      final document = WhiteboardDocument.create(id: 'board-$index');
      repository.documents[document.id] = document;
    }
    final controller = DocumentLibraryController(repository: repository);
    addTearDown(controller.dispose);
    await controller.reload();

    for (var index = 0; index < 30; index++) {
      final id = 'board-$index';
      controller.retainPreview(id);
      controller.requestPreview(id);
      await _waitForPreview(controller, id);
    }

    expect(
      controller.entries.where((entry) => entry.previewPage != null),
      hasLength(30),
    );
    for (var index = 0; index < 30; index++) {
      controller.releasePreview('board-$index');
    }
    controller.requestPreview('board-0');
    expect(repository.loadCalls.where((id) => id == 'board-0'), hasLength(1));
  });

  test('offscreen queued previews are skipped while scrolling', () async {
    for (final id in <String>['visible', 'offscreen']) {
      repository.documents[id] = WhiteboardDocument.create(id: id);
    }
    repository.loadDelay = const Duration(milliseconds: 20);
    final controller = DocumentLibraryController(
      repository: repository,
      previewConcurrency: 1,
    );
    addTearDown(controller.dispose);
    await controller.reload();

    controller.retainPreview('visible');
    controller.requestPreview('visible');
    controller.retainPreview('offscreen');
    controller.requestPreview('offscreen');
    controller.releasePreview('offscreen');
    await _waitForPreview(controller, 'visible');
    await Future<void>.delayed(const Duration(milliseconds: 1));

    expect(repository.loadCalls, <String>['visible']);
    controller.retainPreview('offscreen');
    controller.requestPreview('offscreen');
    await _waitForPreview(controller, 'offscreen');
    expect(repository.loadCalls, <String>['visible', 'offscreen']);
  });

  test(
    'create saves a UUID document before returning its asset directory',
    () async {
      final now = DateTime(2026, 7, 21, 12, 5);
      final controller = DocumentLibraryController(
        repository: repository,
        documentIdFactory: () => '8f225af4-2321-49ca-b41b-68f728d17a8f',
        clock: () => now,
      );
      addTearDown(controller.dispose);

      final result = await controller.createDocument();

      expect(result, isNotNull);
      expect(result!.document.id, '8f225af4-2321-49ca-b41b-68f728d17a8f');
      expect(result.document.title, '20260721-12_05');
      expect(result.document.createdAt, now.toUtc());
      expect(result.document.pages, hasLength(1));
      expect(repository.savedIds, <String>[result.document.id]);
      expect(repository.assetRequests, <String>[result.document.id]);
      expect(
        controller.entries.single.previewPage,
        same(result.document.currentPage),
      );
    },
  );

  test('open uses recovery when a crash journal is advertised', () async {
    final primary = WhiteboardDocument.create(id: 'recover-me', title: 'Tafel');
    final recovered = primary.copyWith(
      revision: 3,
      metadata: primary.metadata.copyWith(recoveredFromCrash: true),
    );
    repository
      ..documents[primary.id] = primary
      ..recoveryAvailable.add(primary.id)
      ..recoveries[primary.id] = recovered;
    final controller = DocumentLibraryController(repository: repository);
    addTearDown(controller.dispose);
    await controller.reload();
    repository
      ..loadCalls.clear()
      ..recoverCalls.clear();

    final result = await controller.openDocument(primary.id);

    expect(result?.document, same(recovered));
    expect(result?.recovered, isTrue);
    expect(repository.recoverCalls, <String>[primary.id]);
    expect(repository.loadCalls, isEmpty);
    expect(controller.entries.single.summary.recoveryAvailable, isFalse);
  });

  test('rename persists revision and delete removes the card', () async {
    final document = WhiteboardDocument.create(
      id: 'rename-me',
      title: 'Vorher',
      now: DateTime.utc(2026, 1, 1),
    );
    repository.documents[document.id] = document;
    final controller = DocumentLibraryController(
      repository: repository,
      clock: () => DateTime.utc(2026, 2, 2),
    );
    addTearDown(controller.dispose);
    await controller.reload();

    expect(await controller.renameDocument(document.id, '  Nachher  '), isTrue);
    final renamed = repository.documents[document.id]!;
    expect(renamed.title, 'Nachher');
    expect(renamed.revision, document.revision + 1);
    expect(renamed.updatedAt, DateTime.utc(2026, 2, 2));

    expect(await controller.deleteDocument(document.id), isTrue);
    expect(repository.deletedIds, <String>[document.id]);
    expect(controller.entries, isEmpty);
  });

  test('documents may safely share the same display name', () async {
    final first = WhiteboardDocument.create(id: 'first', title: 'Tafel A');
    final second = WhiteboardDocument.create(id: 'second', title: 'Tafel B');
    repository.documents
      ..[first.id] = first
      ..[second.id] = second;
    final controller = DocumentLibraryController(repository: repository);
    addTearDown(controller.dispose);
    await controller.reload();

    expect(await controller.renameDocument(first.id, 'Gleicher Name'), isTrue);
    expect(await controller.renameDocument(second.id, 'Gleicher Name'), isTrue);

    expect(repository.documents, hasLength(2));
    expect(
      repository.documents.values.map((item) => item.title),
      everyElement('Gleicher Name'),
    );
    expect(controller.entries.map((entry) => entry.summary.id).toSet(), {
      'first',
      'second',
    });
  });

  test('storage failures become safe user-visible operation errors', () async {
    final document = WhiteboardDocument.create(id: 'broken', title: 'Defekt');
    repository.documents[document.id] = document;
    final controller = DocumentLibraryController(repository: repository);
    addTearDown(controller.dispose);
    await controller.reload();
    repository.loadError = const DocumentStorageException(
      'Die Sicherung ist beschädigt.',
    );

    final result = await controller.openDocument(document.id);

    expect(result, isNull);
    expect(controller.operationError, 'Die Sicherung ist beschädigt.');
    expect(controller.isBusy(document.id), isFalse);
  });

  test(
    'folders, assignments and persistent multi-selection stay consistent',
    () async {
      final first = WhiteboardDocument.create(id: 'one', title: 'Eins');
      final second = WhiteboardDocument.create(id: 'two', title: 'Zwei');
      repository.documents
        ..[first.id] = first
        ..[second.id] = second;
      final controller = DocumentLibraryController(
        repository: repository,
        folderIdFactory: () => 'folder-mathe',
        clock: () => DateTime.utc(2026, 7, 22),
      );
      addTearDown(controller.dispose);
      await controller.reload();

      final folder = await controller.createFolder('Mathematik');
      expect(folder?.id, 'folder-mathe');
      controller
        ..selectDocument(first.id)
        ..selectDocument(second.id);
      expect(controller.selectedDocumentIds, {first.id, second.id});

      expect(
        await controller.moveDocuments(
          controller.selectedDocumentIds,
          folder!.id,
        ),
        isTrue,
      );
      expect(controller.selectedDocumentIds, isEmpty);
      controller.openFolder(folder.id);
      expect(
        controller.visibleEntries.map((entry) => entry.summary.id).toSet(),
        {first.id, second.id},
      );
      expect(repository.organization.documentFolderIds, {
        first.id: folder.id,
        second.id: folder.id,
      });

      expect(await controller.renameFolder(folder.id, 'Analysis'), isTrue);
      expect(controller.activeFolder?.name, 'Analysis');
      expect(await controller.deleteFolder(folder.id), isTrue);
      expect(controller.activeFolder, isNull);
      expect(controller.visibleEntries, hasLength(2));
      expect(repository.documents, hasLength(2));
      expect(repository.organization.documentFolderIds, isEmpty);
      expect(repository.organizationSaves, greaterThanOrEqualTo(3));
    },
  );

  test(
    'batch delete commits successes once and leaves failures selected',
    () async {
      final first = WhiteboardDocument.create(id: 'delete-one');
      final second = WhiteboardDocument.create(id: 'keep-two');
      repository.documents
        ..[first.id] = first
        ..[second.id] = second;
      repository.deleteErrorIds.add(second.id);
      final controller = DocumentLibraryController(repository: repository);
      addTearDown(controller.dispose);
      await controller.reload();
      controller
        ..selectDocument(first.id)
        ..selectDocument(second.id);

      final deleted = await controller.deleteDocuments({first.id, second.id});

      expect(deleted, {first.id});
      expect(controller.entries.single.summary.id, second.id);
      expect(controller.selectedDocumentIds, {second.id});
      expect(controller.operationError, isNotNull);
    },
  );

  test('trash restore keeps an existing original folder', () async {
    final document = WhiteboardDocument.create(id: 'restore-folder');
    final folder = LibraryFolder(
      id: 'folder-a',
      name: 'Biologie',
      createdAt: DateTime.utc(2026, 7, 1),
      updatedAt: DateTime.utc(2026, 7, 1),
    );
    repository
      ..documents[document.id] = document
      ..organization = LibraryOrganization(
        folders: <LibraryFolder>[folder],
        documentFolderIds: <String, String>{document.id: folder.id},
      );
    final controller = DocumentLibraryController(repository: repository);
    addTearDown(controller.dispose);
    await controller.reload();

    expect(await controller.deleteDocument(document.id), isTrue);
    expect(controller.trashedDocuments.single.originalFolderId, folder.id);
    expect(await controller.restoreTrashedDocument(document.id), isTrue);

    expect(controller.entries.single.summary.id, document.id);
    expect(controller.trashedDocuments, isEmpty);
    expect(controller.folderIdForDocument(document.id), folder.id);
    expect(repository.organization.documentFolderIds[document.id], folder.id);
  });

  test(
    'trash restore falls back to root after original folder is gone',
    () async {
      final document = WhiteboardDocument.create(id: 'restore-root');
      final folder = LibraryFolder(
        id: 'removed-folder',
        name: 'Geschichte',
        createdAt: DateTime.utc(2026, 7, 1),
        updatedAt: DateTime.utc(2026, 7, 1),
      );
      repository
        ..documents[document.id] = document
        ..organization = LibraryOrganization(
          folders: <LibraryFolder>[folder],
          documentFolderIds: <String, String>{document.id: folder.id},
        );
      final controller = DocumentLibraryController(repository: repository);
      addTearDown(controller.dispose);
      await controller.reload();

      expect(await controller.deleteDocument(document.id), isTrue);
      expect(await controller.deleteFolder(folder.id), isTrue);
      expect(await controller.restoreTrashedDocument(document.id), isTrue);

      expect(controller.folderIdForDocument(document.id), isNull);
      expect(repository.organization.documentFolderIds[document.id], isNull);
    },
  );

  test(
    'organization save failure never retries an already trashed document',
    () async {
      final document = WhiteboardDocument.create(id: 'trash-once');
      final folder = LibraryFolder(
        id: 'folder-a',
        name: 'Mathematik',
        createdAt: DateTime.utc(2026, 7, 1),
        updatedAt: DateTime.utc(2026, 7, 1),
      );
      repository
        ..documents[document.id] = document
        ..organization = LibraryOrganization(
          folders: <LibraryFolder>[folder],
          documentFolderIds: <String, String>{document.id: folder.id},
        );
      final controller = DocumentLibraryController(repository: repository);
      addTearDown(controller.dispose);
      await controller.reload();
      repository.organizationSaveError = const DocumentStorageException(
        'Ordnerindex ist gesperrt.',
      );

      expect(await controller.deleteDocument(document.id), isTrue);
      expect(controller.entries, isEmpty);
      expect(controller.trashedDocuments.single.id, document.id);
      expect(repository.trashMoveIds, <String>[document.id]);
      expect(controller.operationError, 'Ordnerindex ist gesperrt.');

      expect(await controller.deleteDocument(document.id), isFalse);
      expect(repository.trashMoveIds, <String>[document.id]);
    },
  );

  test(
    'stale trash reloads cannot overwrite move restore or permanent delete',
    () async {
      final document = WhiteboardDocument.create(id: 'trash-reload-race');
      repository.documents[document.id] = document;
      final controller = DocumentLibraryController(repository: repository);
      addTearDown(controller.dispose);
      await controller.reload();

      var gate = Completer<void>();
      var started = Completer<void>();
      repository
        ..trashListGate = gate
        ..trashListStarted = started;
      final staleBeforeMove = controller.reloadTrash();
      await started.future;
      expect(await controller.deleteDocument(document.id), isTrue);
      expect(controller.trashedDocuments.single.id, document.id);
      expect(controller.isTrashLoading, isFalse);
      repository.trashListGate = null;
      gate.complete();
      await staleBeforeMove;
      expect(controller.trashedDocuments.single.id, document.id);

      gate = Completer<void>();
      started = Completer<void>();
      repository
        ..trashListGate = gate
        ..trashListStarted = started;
      final staleBeforeRestore = controller.reloadTrash();
      await started.future;
      expect(await controller.restoreTrashedDocument(document.id), isTrue);
      expect(controller.trashedDocuments, isEmpty);
      expect(controller.isTrashLoading, isFalse);
      repository.trashListGate = null;
      gate.complete();
      await staleBeforeRestore;
      expect(controller.trashedDocuments, isEmpty);

      expect(await controller.deleteDocument(document.id), isTrue);
      gate = Completer<void>();
      started = Completer<void>();
      repository
        ..trashListGate = gate
        ..trashListStarted = started;
      final staleBeforePermanentDelete = controller.reloadTrash();
      await started.future;
      expect(
        await controller.permanentlyDeleteTrashedDocument(document.id),
        isTrue,
      );
      expect(controller.trashedDocuments, isEmpty);
      expect(controller.isTrashLoading, isFalse);
      repository.trashListGate = null;
      gate.complete();
      await staleBeforePermanentDelete;
      expect(controller.trashedDocuments, isEmpty);
    },
  );

  test('direct drag selection replaces an unrelated multi-selection', () async {
    final first = WhiteboardDocument.create(id: 'selected-one');
    final second = WhiteboardDocument.create(id: 'selected-two');
    final dragged = WhiteboardDocument.create(id: 'dragged-alone');
    repository.documents
      ..[first.id] = first
      ..[second.id] = second
      ..[dragged.id] = dragged;
    final controller = DocumentLibraryController(repository: repository);
    addTearDown(controller.dispose);
    await controller.reload();
    controller
      ..selectDocument(first.id)
      ..selectDocument(second.id);

    controller.selectOnlyDocument(dragged.id);

    expect(controller.selectedDocumentIds, <String>{dragged.id});
  });
}

Future<void> _waitForPreview(
  DocumentLibraryController controller,
  String documentId,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final entry = controller.entries.where(
      (entry) => entry.summary.id == documentId,
    );
    if (entry.isNotEmpty && entry.single.previewPage != null) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Vorschau für $documentId wurde nicht geladen.');
}

class _FakeDocumentRepository
    implements
        DocumentRepository,
        DocumentOrganizationRepository,
        DocumentTrashRepository {
  _FakeDocumentRepository(this.assets);

  final Directory assets;
  final Map<String, WhiteboardDocument> documents =
      <String, WhiteboardDocument>{};
  final Map<String, WhiteboardDocument> recoveries =
      <String, WhiteboardDocument>{};
  final Set<String> recoveryAvailable = <String>{};
  final List<String> savedIds = <String>[];
  final List<String> deletedIds = <String>[];
  final List<String> loadCalls = <String>[];
  final List<String> recoverCalls = <String>[];
  final List<String> assetRequests = <String>[];
  final Set<String> deleteErrorIds = <String>{};
  final Map<String, WhiteboardDocument> trashedDocuments =
      <String, WhiteboardDocument>{};
  final Map<String, TrashedDocumentSummary> trash =
      <String, TrashedDocumentSummary>{};
  final List<String> trashMoveIds = <String>[];
  final List<String> permanentlyDeletedTrashIds = <String>[];
  LibraryOrganization organization = LibraryOrganization.empty;
  int organizationSaves = 0;
  Object? organizationSaveError;
  Completer<void>? trashListGate;
  Completer<void>? trashListStarted;
  Duration loadDelay = Duration.zero;
  Object? listError;
  Object? loadError;
  int concurrentLoads = 0;
  int maximumConcurrentLoads = 0;

  @override
  Future<Directory> assetDirectory(String documentId) async {
    assetRequests.add(documentId);
    return assets;
  }

  @override
  Future<void> delete(String documentId) async {
    if (deleteErrorIds.contains(documentId)) {
      throw const DocumentStorageException('Datei ist gesperrt.');
    }
    deletedIds.add(documentId);
    documents.remove(documentId);
    recoveries.remove(documentId);
  }

  @override
  Future<LibraryOrganization> loadOrganization() async => organization;

  @override
  Future<void> saveOrganization(LibraryOrganization organization) async {
    organizationSaves++;
    if (organizationSaveError case final error?) throw error;
    this.organization = organization;
  }

  @override
  Future<TrashedDocumentSummary> moveToTrash(
    String documentId, {
    String? originalFolderId,
  }) async {
    if (deleteErrorIds.contains(documentId)) {
      throw const DocumentStorageException('Datei ist gesperrt.');
    }
    final document = documents.remove(documentId);
    if (document == null) {
      throw const DocumentStorageException('Dokument fehlt.');
    }
    deletedIds.add(documentId);
    trashMoveIds.add(documentId);
    trashedDocuments[documentId] = document;
    final summary = TrashedDocumentSummary(
      id: documentId,
      title: document.title,
      deletedAt: DateTime.utc(2026, 8, 1),
      pageCount: document.pages.length,
      revision: document.revision,
      recoverable: true,
      originalFolderId: originalFolderId,
    );
    trash[documentId] = summary;
    return summary;
  }

  @override
  Future<List<TrashedDocumentSummary>> listTrashed() async {
    final snapshot = trash.values.toList(growable: false);
    final started = trashListStarted;
    if (started != null && !started.isCompleted) started.complete();
    final gate = trashListGate;
    if (gate != null) await gate.future;
    return snapshot;
  }

  @override
  Future<RestoredTrashDocument> restoreFromTrash(String documentId) async {
    final document = trashedDocuments.remove(documentId);
    final summary = trash.remove(documentId);
    if (document == null || summary == null) {
      throw const DocumentStorageException('Dokument fehlt im Papierkorb.');
    }
    documents[documentId] = document;
    return RestoredTrashDocument(
      document: document,
      originalFolderId: summary.originalFolderId,
    );
  }

  @override
  Future<void> deletePermanentlyFromTrash(String documentId) async {
    if (!trash.containsKey(documentId)) {
      throw const DocumentStorageException('Dokument fehlt im Papierkorb.');
    }
    trash.remove(documentId);
    trashedDocuments.remove(documentId);
    permanentlyDeletedTrashIds.add(documentId);
  }

  @override
  Future<List<DocumentSummary>> list() async {
    if (listError case final error?) throw error;
    return documents.values
        .map(
          (document) => DocumentSummary.fromDocument(
            document,
            recoveryAvailable: recoveryAvailable.contains(document.id),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<WhiteboardDocument?> load(String documentId) async {
    loadCalls.add(documentId);
    concurrentLoads++;
    maximumConcurrentLoads = maximumConcurrentLoads < concurrentLoads
        ? concurrentLoads
        : maximumConcurrentLoads;
    try {
      if (loadDelay > Duration.zero) await Future<void>.delayed(loadDelay);
      if (loadError case final error?) throw error;
      return documents[documentId];
    } finally {
      concurrentLoads--;
    }
  }

  @override
  Future<WhiteboardDocument?> recover(String documentId) async {
    recoverCalls.add(documentId);
    return recoveries[documentId] ?? documents[documentId];
  }

  @override
  Future<void> save(WhiteboardDocument document) async {
    savedIds.add(document.id);
    documents[document.id] = document;
  }
}
