import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/features/editor/selected_pages_preview_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('returns pages in tap order and remains usable on a small view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SelectedPagesRequest? result;
    final pages = <BoardPage>[
      BoardPage.empty(id: 'one', name: 'Eins'),
      BoardPage.empty(id: 'two', name: 'Zwei'),
      BoardPage.empty(id: 'three', name: 'Drei'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await SelectedPagesPreviewDialog.show(
                context,
                pages: pages,
                thumbnails: const {},
                suggestedTitle: 'Auswahl',
              );
            },
            child: const Text('Öffnen'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();

    expect(find.byType(SelectedPagesPreviewDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    final secondPage = find.byKey(const ValueKey('selected-page-two'));
    await tester.ensureVisible(secondPage);
    await tester.pumpAndSettle();
    await tester.tap(secondPage);
    final firstPage = find.byKey(const ValueKey('selected-page-one'));
    await tester.ensureVisible(firstPage);
    await tester.pumpAndSettle();
    await tester.tap(firstPage);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('selected-pages-title')),
      'Mein neues Board',
    );
    await tester.tap(
      find.byKey(const ValueKey('create-selected-pages-document')),
    );
    await tester.pumpAndSettle();

    expect(result?.pageIds, <String>['two', 'one']);
    expect(result?.title, 'Mein neues Board');
    expect(tester.takeException(), isNull);
  });
}
