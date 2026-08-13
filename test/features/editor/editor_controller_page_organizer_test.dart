import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'organizer operations preserve participant pages and reach autosave',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'flowboard-page-organizer-controller-',
      );
      final now = DateTime.utc(2026, 8, 13);
      final initial = WhiteboardDocument(
        id: 'organizer-controller',
        title: 'Seiten',
        createdAt: now,
        updatedAt: now,
        pages: <BoardPage>[
          BoardPage.empty(id: 'p1').copyWith(thumbnailAssetId: 'old-preview'),
          BoardPage.empty(id: 'p2'),
          BoardPage.empty(id: 'p3'),
        ],
      );
      final repository = _MemoryRepository(initial, temporary);
      final owner = EditorController(
        document: initial,
        repository: repository,
        assetDirectory: temporary,
      );
      final participant = EditorController.participantView(
        owner,
        participantId: 'right',
      );
      addTearDown(() async {
        await participant.close();
        await owner.close();
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });

      participant.goToPage(2);
      expect(participant.page.id, 'p3');
      expect(owner.reorderPages(const <String>['p3', 'p1', 'p2']), true);
      expect(owner.document.pages.map((page) => page.id), <String>[
        'p3',
        'p1',
        'p2',
      ]);
      expect(owner.page.id, 'p1');
      expect(participant.page.id, 'p3');
      expect(participant.currentPageIndex, 0);

      owner.undo();
      expect(owner.document.pages.map((page) => page.id), <String>[
        'p1',
        'p2',
        'p3',
      ]);
      expect(owner.page.id, 'p1');
      expect(participant.page.id, 'p3');

      expect(participant.duplicatePage('p1'), true);
      final duplicate = participant.page;
      expect(duplicate.id, isNot('p1'));
      expect(duplicate.name, 'Seite 1 – Kopie');
      expect(duplicate.thumbnailAssetId, isNull);
      expect(owner.page.id, 'p1');
      participant.undo();
      expect(
        participant.page.id,
        'p2',
        reason: 'Removing the active copy keeps the same local page slot.',
      );
      expect(owner.document.pages, hasLength(3));

      expect(owner.deletePages(const <String>{'p1', 'p2'}), true);
      expect(owner.document.pages.single.id, 'p3');
      expect(owner.page.id, 'p3');
      expect(participant.page.id, 'p3');
      await owner.flush();
      expect(repository.saved.pages.single.id, 'p3');
    },
  );

  test(
    'drag reorder rebases an external insertion by stable page id',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'flowboard-page-reorder-race-',
      );
      final now = DateTime.utc(2026, 8, 13);
      final initial = WhiteboardDocument(
        id: 'reorder-race',
        title: 'Seiten',
        createdAt: now,
        updatedAt: now,
        pages: <BoardPage>[
          BoardPage.empty(id: 'p1'),
          BoardPage.empty(id: 'p2'),
          BoardPage.empty(id: 'p3'),
        ],
      );
      final repository = _MemoryRepository(initial, temporary);
      final controller = EditorController(
        document: initial,
        repository: repository,
        assetDirectory: temporary,
      );
      addTearDown(() async {
        await controller.close();
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });

      const dragSnapshot = <String>['p1', 'p2', 'p3'];
      controller.addPage();
      final insertedId = controller.page.id;
      expect(controller.document.pages.map((page) => page.id), <String>[
        'p1',
        insertedId,
        'p2',
        'p3',
      ]);

      expect(
        controller.reorderPageFromDrag(
          pageId: 'p3',
          sourcePageIds: dragSnapshot,
          insertionIndex: 0,
        ),
        true,
      );
      expect(controller.document.pages.map((page) => page.id), <String>[
        'p3',
        'p1',
        insertedId,
        'p2',
      ]);

      final secondSnapshot = controller.document.pages
          .map((page) => page.id)
          .toList(growable: false);
      expect(
        controller.reorderPages(<String>['p2', 'p3', 'p1', insertedId]),
        true,
      );
      final foreignOrder = controller.document.pages
          .map((page) => page.id)
          .toList(growable: false);
      expect(
        controller.reorderPageFromDrag(
          pageId: 'p3',
          sourcePageIds: secondSnapshot,
          insertionIndex: 3,
        ),
        false,
      );
      expect(
        controller.document.pages.map((page) => page.id),
        foreignOrder,
        reason: 'A concurrent reorder must win instead of being overwritten.',
      );
      expect(controller.lastError, contains('anderweitig sortiert'));
    },
  );
}

final class _MemoryRepository implements DocumentRepository {
  _MemoryRepository(this.saved, this.directory);

  WhiteboardDocument saved;
  final Directory directory;

  @override
  Future<Directory> assetDirectory(String documentId) async => directory;

  @override
  Future<void> delete(String documentId) async {}

  @override
  Future<List<DocumentSummary>> list() async => <DocumentSummary>[
    DocumentSummary.fromDocument(saved),
  ];

  @override
  Future<WhiteboardDocument?> load(String documentId) async =>
      documentId == saved.id ? saved : null;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => null;

  @override
  Future<void> save(WhiteboardDocument document) async => saved = document;
}
