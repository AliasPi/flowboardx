import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/domain/model/library_organization.dart';
import 'package:flowboard_x/src/features/library/document_library.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory assets;
  late _WidgetRepository repository;

  setUp(() {
    assets = Directory.systemTemp.createTempSync(
      'flowboard-library-widget-test-',
    );
    repository = _WidgetRepository(assets);
  });

  tearDown(() {
    if (assets.existsSync()) assets.deleteSync(recursive: true);
  });

  Widget app({
    required DocumentLibraryOpenCallback onOpen,
    DocumentRepository? documentRepository,
    DocumentIdFactory? idFactory,
    FolderIdFactory? folderIdFactory,
    DocumentLibraryClock? clock,
    LibraryArchiveService? archiveService,
  }) {
    return MaterialApp(
      home: DocumentLibraryScreen(
        repository: documentRepository ?? repository,
        onOpen: onOpen,
        documentIdFactory: idFactory,
        folderIdFactory: folderIdFactory,
        clock: clock,
        archiveService: archiveService,
      ),
    );
  }

  testWidgets('shows loading and then the production empty state', (
    tester,
  ) async {
    repository.listGate = Future<void>.delayed(
      const Duration(milliseconds: 30),
    );
    await tester.pumpWidget(app(onOpen: (_, _) {}));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('library-loading')),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('library-empty')), findsOneWidget);
    expect(find.text('Noch kein Whiteboard'), findsOneWidget);
  });

  testWidgets('creates, saves and opens a new document', (tester) async {
    WhiteboardDocument? opened;
    Directory? openedAssets;
    await tester.pumpWidget(
      app(
        idFactory: () => 'new-id',
        clock: () => DateTime(2026, 7, 30, 15, 57),
        onOpen: (document, directory) {
          opened = document;
          openedAssets = directory;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('new-document-button')));
    await tester.pumpAndSettle();

    expect(repository.saved.single.id, 'new-id');
    expect(repository.saved.single.title, '20260730-15_57');
    expect(opened?.id, 'new-id');
    expect(openedAssets?.path, assets.path);
  });

  testWidgets('renders metadata, a real page preview and recovery status', (
    tester,
  ) async {
    final document = _contentDocument('board-1', 'Physik');
    repository
      ..documents[document.id] = document
      ..recoveryAvailable.add(document.id);

    await tester.pumpWidget(app(onOpen: (_, _) {}));
    await tester.pumpAndSettle();

    expect(find.text('Physik'), findsOneWidget);
    expect(find.textContaining('1 Seite'), findsWidgets);
    expect(find.text('Wiederherstellen'), findsOneWidget);
    final preview = find.byKey(
      const ValueKey<String>('document-preview-board-1_page_1'),
    );
    expect(preview, findsOneWidget);
    final customPaint = tester.widget<CustomPaint>(preview);
    final painter = customPaint.painter! as DocumentPagePreviewPainter;
    expect(painter.page.strokes, isNotEmpty);
    expect(painter.page.objects, hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('many document cards request previews only near the viewport', (
    tester,
  ) async {
    for (var index = 0; index < 80; index++) {
      final document = WhiteboardDocument.create(
        id: 'board-${index.toString().padLeft(3, '0')}',
        title: 'Tafel $index',
      );
      repository.documents[document.id] = document;
    }

    await tester.pumpWidget(app(onOpen: (_, _) {}));
    await tester.pumpAndSettle();

    expect(find.textContaining('80 Dokumente'), findsOneWidget);
    expect(repository.loadCalls, isNotEmpty);
    expect(repository.loadCalls.length, lessThan(20));
  });

  testWidgets('opens recovery data and reports the matching asset directory', (
    tester,
  ) async {
    final primary = WhiteboardDocument.create(id: 'recover', title: 'Mathe');
    final recovered = primary.copyWith(
      revision: 5,
      metadata: primary.metadata.copyWith(recoveredFromCrash: true),
    );
    repository
      ..documents[primary.id] = primary
      ..recoveries[primary.id] = recovered
      ..recoveryAvailable.add(primary.id);
    WhiteboardDocument? opened;

    await tester.pumpWidget(app(onOpen: (document, _) => opened = document));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('document-card-recover')),
    );
    await tester.pumpAndSettle();

    expect(opened, same(recovered));
    expect(repository.recoverCalls, <String>['recover']);
  });

  testWidgets('renames through the card menu', (tester) async {
    final document = WhiteboardDocument.create(id: 'rename', title: 'Alt');
    repository.documents[document.id] = document;
    await tester.pumpWidget(app(onOpen: (_, _) {}));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('document-menu-rename')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('rename-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('rename-document-field')),
      'Neu benannt',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('confirm-rename-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.documents['rename']?.title, 'Neu benannt');
    expect(find.text('Neu benannt'), findsOneWidget);
  });

  testWidgets('deletes only after explicit confirmation', (tester) async {
    final document = WhiteboardDocument.create(id: 'delete', title: 'Löschen');
    repository.documents[document.id] = document;
    await tester.pumpWidget(app(onOpen: (_, _) {}));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('document-menu-delete')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('delete-delete')));
    await tester.pumpAndSettle();
    expect(repository.deletedIds, isEmpty);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(repository.deletedIds, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('document-card-delete')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('document-menu-delete')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('delete-delete')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('confirm-delete-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.deletedIds, <String>['delete']);
    expect(
      find.byKey(const ValueKey<String>('document-card-delete')),
      findsNothing,
    );
  });

  testWidgets('hides trash wording for repositories without that capability', (
    tester,
  ) async {
    final legacy = _LegacyWidgetRepository(assets);
    final document = WhiteboardDocument.create(
      id: 'legacy-delete',
      title: 'Legacy',
    );
    legacy.documents[document.id] = document;
    await tester.pumpWidget(app(onOpen: (_, _) {}, documentRepository: legacy));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('library-trash-button')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('document-menu-legacy-delete')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('delete-legacy-delete')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('dauerhaft gelöscht'), findsOneWidget);
    expect(find.text('In Papierkorb'), findsNothing);
  });

  testWidgets(
    'trash restores and permanently deletes only after confirmation',
    (tester) async {
      final document = WhiteboardDocument.create(
        id: 'trash-actions',
        title: 'Papierkorb-Test',
      );
      repository.documents[document.id] = document;
      await tester.pumpWidget(app(onOpen: (_, _) {}));
      await tester.pumpAndSettle();

      Future<void> moveDocumentToTrash() async {
        await tester.tap(
          find.byKey(const ValueKey<String>('document-menu-trash-actions')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('delete-trash-actions')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('confirm-delete-button')),
        );
        await tester.pumpAndSettle();
      }

      await moveDocumentToTrash();
      await tester.tap(
        find.byKey(const ValueKey<String>('library-trash-button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Papierkorb'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('trash-item-trash-actions')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('trash-restore-trash-actions')),
      );
      await tester.pumpAndSettle();
      expect(repository.documents.containsKey(document.id), isTrue);
      expect(repository.trash, isEmpty);

      await tester.tap(find.text('Schließen'));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await moveDocumentToTrash();
      await tester.tap(
        find.byKey(const ValueKey<String>('library-trash-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('trash-delete-trash-actions')),
      );
      await tester.pumpAndSettle();
      expect(repository.permanentlyDeletedTrashIds, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey<String>('confirm-trash-delete-button')),
      );
      await tester.pumpAndSettle();

      expect(repository.permanentlyDeletedTrashIds, <String>[document.id]);
      expect(repository.documents, isEmpty);
      expect(repository.trash, isEmpty);
      expect(find.text('Der Papierkorb ist leer.'), findsOneWidget);
    },
  );

  testWidgets('shows list and open errors without throwing', (tester) async {
    repository.listError = const DocumentStorageException(
      'Speicher ist nicht erreichbar.',
    );
    await tester.pumpWidget(app(onOpen: (_, _) {}));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('library-error')), findsOneWidget);
    expect(find.text('Speicher ist nicht erreichbar.'), findsOneWidget);
  });

  testWidgets('shows document-open failures inline', (tester) async {
    final document = WhiteboardDocument.create(
      id: 'open-error',
      title: 'Fehler',
    );
    repository
      ..documents[document.id] = document
      ..loadError = const DocumentStorageException('Dokument ist beschädigt.');
    await tester.pumpWidget(app(onOpen: (_, _) {}));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('document-card-open-error')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('library-operation-error')),
      findsOneWidget,
    );
    expect(find.text('Dokument ist beschädigt.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps touch controls usable on a narrow viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final document = WhiteboardDocument.create(id: 'narrow', title: 'Mobil');
    repository.documents[document.id] = document;

    await tester.pumpWidget(app(onOpen: (_, _) {}));
    await tester.pumpAndSettle();

    expect(find.text('Mobil'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('new-document-button')))
          .height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('long press enables multi-select and batch delete confirmation', (
    tester,
  ) async {
    final first = WhiteboardDocument.create(id: 'multi-a', title: 'A');
    final second = WhiteboardDocument.create(id: 'multi-b', title: 'B');
    repository.documents
      ..[first.id] = first
      ..[second.id] = second;
    await tester.pumpWidget(app(onOpen: (_, _) {}));
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey<String>('document-card-multi-a')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('document-selection-toolbar')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('document-card-multi-b')),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 Dokumente ausgewählt'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('delete-selected-button')),
    );
    await tester.pumpAndSettle();
    expect(repository.deletedIds, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey<String>('confirm-batch-delete-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.deletedIds.toSet(), {'multi-a', 'multi-b'});
    expect(find.text('Noch kein Whiteboard'), findsOneWidget);
  });

  testWidgets('creates a folder, moves a document and opens the folder', (
    tester,
  ) async {
    final document = WhiteboardDocument.create(id: 'move-me', title: 'Chemie');
    repository.documents[document.id] = document;
    await tester.pumpWidget(
      app(onOpen: (_, _) {}, folderIdFactory: () => 'school-folder'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('new-folder-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('folder-name-field')),
      'Schule',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('confirm-folder-name-button')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('folder-card-school-folder')),
      findsOneWidget,
    );

    // The pinned destination strip intentionally uses part of the viewport;
    // scroll the card into a clear touch position after the creation snackbar.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('document-card-move-me')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('document-menu-move-me')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('move-move-me')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('move-target-school-folder')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('document-card-move-me')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('folder-card-school-folder')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Schule'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('document-card-move-me')),
      findsOneWidget,
    );
  });

  testWidgets(
    'dragging a selected document onto a folder moves the whole selection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final first = WhiteboardDocument.create(id: 'drag-a', title: 'A');
      final second = WhiteboardDocument.create(id: 'drag-b', title: 'B');
      repository.documents
        ..[first.id] = first
        ..[second.id] = second;
      final now = DateTime.utc(2026, 7, 22);
      repository.organization = LibraryOrganization(
        folders: <LibraryFolder>[
          LibraryFolder(
            id: 'drop-folder',
            name: 'Klasse 8',
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );

      await tester.pumpWidget(app(onOpen: (_, _) {}));
      await tester.pumpAndSettle();
      await tester.longPress(
        find.byKey(const ValueKey<String>('document-card-drag-a')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('document-card-drag-b')),
      );
      await tester.pumpAndSettle();

      final source = find.byKey(const ValueKey<String>('document-drag-drag-a'));
      final target = find.byKey(
        const ValueKey<String>('folder-card-drop-folder'),
      );
      final gesture = await tester.startGesture(tester.getCenter(source));
      await tester.pump(const Duration(milliseconds: 450));
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 180));
      expect(find.text('Hier ablegen'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(repository.organization.documentFolderIds, <String, String>{
        'drag-a': 'drop-folder',
        'drag-b': 'drop-folder',
      });
      expect(
        find.byKey(const ValueKey<String>('document-card-drag-a')),
        findsNothing,
      );
      expect(find.textContaining('2 Dokumente in'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mouse drag moves a document without a long-press delay', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final document = WhiteboardDocument.create(
      id: 'direct-drag',
      title: 'Direkt ziehen',
    );
    repository.documents[document.id] = document;
    final now = DateTime.utc(2026, 7, 22);
    repository.organization = LibraryOrganization(
      folders: <LibraryFolder>[
        LibraryFolder(
          id: 'direct-folder',
          name: 'Direktziel',
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );

    await tester.pumpWidget(app(onOpen: (_, _) {}));
    await tester.pumpAndSettle();
    final source = find.byKey(
      const ValueKey<String>('document-drag-direct-drag'),
    );
    final target = find.byKey(
      const ValueKey<String>('folder-card-direct-folder'),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(source),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(24, 0));
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('Hier ablegen'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(repository.organization.documentFolderIds, <String, String>{
      'direct-drag': 'direct-folder',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dragging from an open folder moves a document to another folder',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final document = WhiteboardDocument.create(
        id: 'inside-source',
        title: 'Aus dem Ordner',
      );
      repository.documents[document.id] = document;
      final now = DateTime.utc(2026, 7, 23);
      repository.organization = LibraryOrganization(
        folders: <LibraryFolder>[
          LibraryFolder(
            id: 'source-folder',
            name: 'Quelle',
            createdAt: now,
            updatedAt: now,
          ),
          LibraryFolder(
            id: 'destination-folder',
            name: 'Zielordner',
            createdAt: now,
            updatedAt: now,
          ),
        ],
        documentFolderIds: const <String, String>{
          'inside-source': 'source-folder',
        },
      );

      await tester.pumpWidget(app(onOpen: (_, _) {}));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('folder-card-source-folder')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('folder-drop-target-strip')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('folder-drop-target-root')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('folder-drop-target-source-folder')),
        findsNothing,
      );
      final target = find.byKey(
        const ValueKey<String>('folder-drop-target-destination-folder'),
      );
      expect(target, findsOneWidget);

      final source = find.byKey(
        const ValueKey<String>('document-drag-inside-source'),
      );
      final gesture = await tester.startGesture(tester.getCenter(source));
      await tester.pump(const Duration(milliseconds: 450));
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 180));
      expect(find.text('Hier ablegen'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(repository.organization.documentFolderIds, <String, String>{
        'inside-source': 'destination-folder',
      });
      expect(
        find.byKey(const ValueKey<String>('document-card-inside-source')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pinned folder target remains reachable for a vertically scrolled document',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final base = DateTime.utc(2026, 7, 23, 8);
      for (var index = 0; index < 12; index++) {
        final document = WhiteboardDocument.create(
          id: 'scroll-$index',
          title: 'Dokument $index',
          now: base.add(Duration(minutes: index)),
        );
        repository.documents[document.id] = document;
      }
      repository.organization = LibraryOrganization(
        folders: <LibraryFolder>[
          LibraryFolder(
            id: 'sticky-target',
            name: 'Immer erreichbar',
            createdAt: base,
            updatedAt: base,
          ),
        ],
      );

      await tester.pumpWidget(app(onOpen: (_, _) {}));
      await tester.pumpAndSettle();
      final source = find.byKey(
        const ValueKey<String>('document-drag-scroll-0'),
      );
      final verticalScrollable = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        source,
        600,
        scrollable: verticalScrollable,
      );
      await tester.pumpAndSettle();

      final target = find.byKey(
        const ValueKey<String>('folder-drop-target-sticky-target'),
      );
      expect(source.hitTestable(), findsOneWidget);
      expect(target.hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(target).dy, lessThan(100));

      final gesture = await tester.startGesture(tester.getCenter(source));
      await tester.pump(const Duration(milliseconds: 450));
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 180));
      expect(find.text('Hier ablegen'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(repository.organization.documentFolderIds, <String, String>{
        'scroll-0': 'sticky-target',
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dragging an unselected card moves only that card', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final id in const <String>['kept-a', 'kept-b', 'dragged-c']) {
      repository.documents[id] = WhiteboardDocument.create(id: id, title: id);
    }
    final now = DateTime.utc(2026, 7, 22);
    repository.organization = LibraryOrganization(
      folders: <LibraryFolder>[
        LibraryFolder(
          id: 'drop-only-c',
          name: 'Ziel',
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );

    await tester.pumpWidget(app(onOpen: (_, _) {}));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey<String>('document-card-kept-a')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('document-card-kept-b')),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey<String>('document-drag-dragged-c')),
      ),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(24, 0));
    await gesture.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey<String>('folder-card-drop-only-c')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(repository.organization.documentFolderIds, <String, String>{
      'dragged-c': 'drop-only-c',
    });
    expect(
      find.byKey(const ValueKey<String>('document-card-kept-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('document-card-kept-b')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ZIP action offers local, Quick Share and WLAN targets', (
    tester,
  ) async {
    final document = WhiteboardDocument.create(id: 'zip', title: 'ZIP');
    repository.documents[document.id] = document;
    await tester.pumpWidget(app(onOpen: (_, _) {}));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('document-menu-zip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('share-zip')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('archive-share-save')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('archive-share-quick')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('archive-share-wlan')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

WhiteboardDocument _contentDocument(String id, String title) {
  final page = BoardPage(
    id: '${id}_page_1',
    name: 'Seite 1',
    strokes: <InkStroke>[
      InkStroke(
        id: 'stroke',
        points: const <InkPoint>[
          InkPoint(x: 100, y: 120),
          InkPoint(x: 500, y: 320),
        ],
      ),
    ],
    objects: <BoardObject>[
      ShapeObject(
        id: 'shape',
        transform: const ObjectTransform(
          x: 600,
          y: 160,
          width: 300,
          height: 220,
        ),
      ),
      ImageObject(
        id: 'image',
        transform: const ObjectTransform(
          x: 980,
          y: 100,
          width: 340,
          height: 260,
        ),
        assetId: 'image-asset',
      ),
      PdfObject(
        id: 'pdf',
        transform: const ObjectTransform(
          x: 200,
          y: 500,
          width: 300,
          height: 420,
        ),
        assetId: 'pdf-asset',
        pageIndices: const <int>[0],
      ),
      TableObject(
        id: 'table',
        transform: const ObjectTransform(
          x: 700,
          y: 520,
          width: 600,
          height: 360,
        ),
        rows: 3,
        columns: 4,
      ),
    ],
  );
  return WhiteboardDocument.create(
    id: id,
    title: title,
  ).copyWith(pages: <BoardPage>[page]);
}

class _WidgetRepository
    implements
        DocumentRepository,
        DocumentOrganizationRepository,
        DocumentTrashRepository {
  _WidgetRepository(this.assets);

  final Directory assets;
  final Map<String, WhiteboardDocument> documents =
      <String, WhiteboardDocument>{};
  final Map<String, WhiteboardDocument> recoveries =
      <String, WhiteboardDocument>{};
  final Set<String> recoveryAvailable = <String>{};
  final List<WhiteboardDocument> saved = <WhiteboardDocument>[];
  final List<String> deletedIds = <String>[];
  final List<String> recoverCalls = <String>[];
  final List<String> loadCalls = <String>[];
  final Map<String, WhiteboardDocument> trashedDocuments =
      <String, WhiteboardDocument>{};
  final Map<String, TrashedDocumentSummary> trash =
      <String, TrashedDocumentSummary>{};
  final List<String> permanentlyDeletedTrashIds = <String>[];
  Future<void>? listGate;
  Object? listError;
  Object? loadError;
  LibraryOrganization organization = LibraryOrganization.empty;

  @override
  Future<Directory> assetDirectory(String documentId) async => assets;

  @override
  Future<void> delete(String documentId) async {
    deletedIds.add(documentId);
    documents.remove(documentId);
  }

  @override
  Future<TrashedDocumentSummary> moveToTrash(
    String documentId, {
    String? originalFolderId,
  }) async {
    final document = documents.remove(documentId);
    if (document == null) {
      throw const DocumentStorageException('Dokument fehlt.');
    }
    deletedIds.add(documentId);
    trashedDocuments[documentId] = document;
    final summary = TrashedDocumentSummary(
      id: document.id,
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
  Future<List<TrashedDocumentSummary>> listTrashed() async =>
      trash.values.toList(growable: false);

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
    await listGate;
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
    if (loadError case final error?) throw error;
    return documents[documentId];
  }

  @override
  Future<WhiteboardDocument?> recover(String documentId) async {
    recoverCalls.add(documentId);
    return recoveries[documentId] ?? documents[documentId];
  }

  @override
  Future<void> save(WhiteboardDocument document) async {
    saved.add(document);
    documents[document.id] = document;
  }

  @override
  Future<LibraryOrganization> loadOrganization() async => organization;

  @override
  Future<void> saveOrganization(LibraryOrganization organization) async {
    this.organization = organization;
  }
}

class _LegacyWidgetRepository implements DocumentRepository {
  _LegacyWidgetRepository(this.assets);

  final Directory assets;
  final Map<String, WhiteboardDocument> documents =
      <String, WhiteboardDocument>{};

  @override
  Future<Directory> assetDirectory(String documentId) async => assets;

  @override
  Future<void> delete(String documentId) async {
    documents.remove(documentId);
  }

  @override
  Future<List<DocumentSummary>> list() async => documents.values
      .map(DocumentSummary.fromDocument)
      .toList(growable: false);

  @override
  Future<WhiteboardDocument?> load(String documentId) async =>
      documents[documentId];

  @override
  Future<WhiteboardDocument?> recover(String documentId) async =>
      documents[documentId];

  @override
  Future<void> save(WhiteboardDocument document) async {
    documents[document.id] = document;
  }
}
