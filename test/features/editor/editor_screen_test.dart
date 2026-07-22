import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/features/editor/editor_screen.dart';
import 'package:flowboard_x/src/features/templates/user_template.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('template sheet stays overflow-free with large system text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 760);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2.5)),
          child: child!,
        ),
        home: Scaffold(
          body: TemplateLibrarySheet(
            userTemplates: const [],
            onSaveCurrentPage: () {},
            onBuiltInTemplateSelected: (_) {},
            onUserTemplateSelected: (_) {},
            onUserTemplateDeleted: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Neue Seite aus Vorlage'), findsOneWidget);
    expect(find.text('Flowboard-Vorlagen'), findsOneWidget);
    expect(find.text('Aktuelle Seite speichern'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
    await tester.pump();
    expect(find.text('Vorlagen von Nutzern'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('own template dialog shows a real preview and deletes in place', (
    tester,
  ) async {
    final template = UserTemplate(
      id: 'own-template',
      name: 'Meine Klasse',
      createdAt: DateTime.utc(2026, 7, 22),
      page: BoardPage.empty(id: 'page', name: 'Vorlage'),
    );
    var deleteCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserTemplateLibraryDialog(
            userTemplates: <UserTemplate>[template],
            onDelete: (_) async {
              deleteCalls++;
              return true;
            },
          ),
        ),
      ),
    );

    expect(find.text('Eigene Vorlagen'), findsOneWidget);
    expect(find.text('Meine Klasse'), findsOneWidget);
    expect(find.byKey(const ValueKey('document-preview-page')), findsOneWidget);

    await tester.tap(find.byTooltip('Vorlage löschen'));
    await tester.pumpAndSettle();
    expect(find.text('Eigene Vorlage löschen?'), findsOneWidget);
    await tester.tap(find.text('Löschen'));
    await tester.pumpAndSettle();

    expect(deleteCalls, 1);
    expect(find.text('Noch keine eigenen Vorlagen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final deviceKind in <PointerDeviceKind>[
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.mouse,
  ]) {
    testWidgets('page tray scrolls by ${deviceKind.name} drag on its cards', (
      tester,
    ) async {
      final controller = ScrollController();
      var cardTapCount = 0;
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 700,
                height: 260,
                child: HorizontalPageTray(
                  controller: controller,
                  itemCount: 8,
                  itemBuilder: (context, index) => SizedBox(
                    key: ValueKey('page-card-$index'),
                    width: 260,
                    child: Material(
                      color: index.isEven ? Colors.blueGrey : Colors.teal,
                      child: InkWell(
                        onTap: () => cardTapCount++,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(controller.hasClients, isTrue);
      expect(controller.position.maxScrollExtent, greaterThan(0));
      expect(controller.offset, 0);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('page-card-1'))),
        kind: deviceKind,
      );
      // The first move resolves the InkWell-vs-scroll gesture arena; following
      // moves carry the actual swipe, just like a physical pointer stream.
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-330, 0));
      await tester.pump();

      // Exactly one 360 px translation proves neither the native Scrollable nor
      // the scrollbar applied the same pointer movement a second time.
      expect(controller.offset, closeTo(360, .01));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(cardTapCount, 0);
      expect(tester.takeException(), isNull);
    });
  }
}
