import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flowboard_x/src/features/editor/page_organizer_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('organizer renames, reorders and deletes selected pages', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    final temporary = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('flowboard-page-organizer-ui-'),
    ))!;
    final now = DateTime.utc(2026, 8, 13);
    final document = WhiteboardDocument(
      id: 'organizer-ui',
      title: 'Seiten',
      createdAt: now,
      updatedAt: now,
      pages: <BoardPage>[
        BoardPage.empty(id: 'p1', name: 'Eins'),
        BoardPage.empty(id: 'p2', name: 'Zwei'),
        BoardPage.empty(id: 'p3', name: 'Drei'),
      ],
    );
    final repository = _MemoryRepository(document, temporary);
    final controller = EditorController(
      document: document,
      repository: repository,
      assetDirectory: temporary,
    );
    addTearDown(() async {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      await controller.close();
      await tester.runAsync(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => PageOrganizerDialog.show(
                  context,
                  controller: controller,
                  thumbnails: const {},
                ),
                child: const Text('Organizer öffnen'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Organizer öffnen'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('page-organizer-dialog')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('page-organizer-item-p1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('page-organizer-item-p3')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('page-organizer-rename-p1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('page-organizer-rename-field')),
      'Startseite',
    );
    await tester.tap(
      find.byKey(const ValueKey('page-organizer-confirm-rename')),
    );
    await tester.pumpAndSettle();
    expect(controller.document.pageById('p1')!.name, 'Startseite');

    await tester.drag(
      find.byKey(const ValueKey('page-organizer-drag-p3')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(controller.document.pages.first.id, 'p3');

    await tester.tap(find.byKey(const ValueKey('page-organizer-select-p1')));
    await tester.tap(find.byKey(const ValueKey('page-organizer-select-p2')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('page-organizer-delete-selected')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('page-organizer-confirm-delete')),
    );
    await tester.pumpAndSettle();

    expect(controller.document.pages.single.id, 'p3');
    expect(
      find.byKey(const ValueKey('page-organizer-item-p3')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('page-organizer-item-p1')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag keeps its page identity across an external page insertion', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    final temporary = (await tester.runAsync(
      () => Directory.systemTemp.createTemp(
        'flowboard-page-organizer-drag-race-',
      ),
    ))!;
    final now = DateTime.utc(2026, 8, 13);
    final document = WhiteboardDocument(
      id: 'organizer-drag-race',
      title: 'Seiten',
      createdAt: now,
      updatedAt: now,
      pages: <BoardPage>[
        BoardPage.empty(id: 'p1', name: 'Eins'),
        BoardPage.empty(id: 'p2', name: 'Zwei'),
        BoardPage.empty(id: 'p3', name: 'Drei'),
      ],
    );
    final repository = _MemoryRepository(document, temporary);
    final controller = EditorController(
      document: document,
      repository: repository,
      assetDirectory: temporary,
    );
    addTearDown(() async {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      await controller.close();
      await tester.runAsync(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PageOrganizerDialog(controller: controller, thumbnails: const {}),
      ),
    );
    await tester.pump();

    final handle = find.byKey(const ValueKey('page-organizer-drag-p3'));
    final firstCard = find.byKey(const ValueKey('page-organizer-item-p1'));
    final drag = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    await drag.moveBy(const Offset(0, -48));
    await tester.pump();

    // Simulate the other participant inserting a page while the reorderable
    // list still reports indices from the drag's original three-page snapshot.
    controller.addPage();
    final insertedId = controller.page.id;
    await tester.pump();
    await drag.moveTo(tester.getCenter(firstCard) - const Offset(0, 30));
    await tester.pump();
    await drag.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(controller.document.pageById(insertedId), isNotNull);
    expect(controller.document.pages.map((page) => page.id).toSet(), <String>{
      'p1',
      'p2',
      'p3',
      insertedId,
    });
    expect(tester.takeException(), isNull);

    // Flutter may safely cancel a platform drag whose backing list changed.
    // In that case the frozen snapshot still has to be released so the very
    // next ordinary drag works and moves the intended stable page identity.
    if (controller.document.pages.first.id != 'p3') {
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('page-organizer-item-$insertedId')),
        findsOneWidget,
        reason: 'A cancelled drag must release its frozen page snapshot.',
      );
      final retry = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('page-organizer-drag-p3'))),
      );
      await tester.pump();
      await retry.moveTo(
        tester.getTopLeft(
              find.byKey(const ValueKey('page-organizer-item-p1')),
            ) +
            const Offset(24, -100),
      );
      await tester.pump();
      await retry.up();
      await tester.pumpAndSettle();
    }
    expect(
      controller.document.pages.first.id,
      'p3',
      reason:
          'order=${controller.document.pages.map((page) => page.id).toList()}, '
          'error=${controller.lastError}',
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}

final class _MemoryRepository implements DocumentRepository {
  _MemoryRepository(this.document, this.directory);

  WhiteboardDocument document;
  final Directory directory;

  @override
  Future<Directory> assetDirectory(String documentId) async => directory;

  @override
  Future<void> delete(String documentId) async {}

  @override
  Future<List<DocumentSummary>> list() async => <DocumentSummary>[
    DocumentSummary.fromDocument(document),
  ];

  @override
  Future<WhiteboardDocument?> load(String documentId) async => document;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => null;

  @override
  Future<void> save(WhiteboardDocument value) async => document = value;
}
