import 'package:flowboard_x/src/features/pages/editor_page_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('page controls expose navigation, creation and deletion', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorPageControls(
            controlId: 'left',
            participantLabel: 'Links',
            currentPageIndex: 1,
            pageCount: 4,
            onPrevious: () => actions.add('previous'),
            onNext: () => actions.add('next'),
            onAdd: () => actions.add('add'),
            onDelete: () => actions.add('delete'),
          ),
        ),
      ),
    );

    expect(find.text('2 / 4'), findsOneWidget);
    expect(find.text('Links'), findsOneWidget);
    for (final action in <String>['previous', 'next', 'add', 'delete']) {
      await tester.tap(find.byKey(ValueKey<String>('page-left-$action')));
      await tester.pump();
    }
    expect(actions, <String>['previous', 'next', 'add', 'delete']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('last page and page limit disable destructive controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorPageControls(
            controlId: 'single',
            currentPageIndex: 0,
            pageCount: 1,
            canAdd: false,
            onPrevious: () {},
            onNext: () {},
            onAdd: () {},
            onDelete: () {},
          ),
        ),
      ),
    );

    IconButton button(String action) => tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(ValueKey<String>('page-single-$action')),
        matching: find.byType(IconButton),
      ),
    );

    expect(button('previous').onPressed, isNull);
    expect(button('next').onPressed, isNull);
    expect(button('add').onPressed, isNull);
    expect(button('delete').onPressed, isNull);
    expect(find.text('1 / 1'), findsOneWidget);
  });
}
