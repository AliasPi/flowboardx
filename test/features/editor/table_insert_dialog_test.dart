import 'package:flowboard_x/src/features/editor/table_insert_dialog.dart';
import 'package:flowboard_x/src/features/radial_menu/radial_menu_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('configures rows and columns before committing the table', (
    tester,
  ) async {
    RadialTableSize? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await TableInsertDialog.show(
                  context,
                  initialSize: const RadialTableSize(3, 4),
                );
              },
              child: const Text('Öffnen'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('table-insert-preview')), findsOneWidget);

    await tester.tap(find.byTooltip('Zeilen erhöhen'));
    await tester.tap(find.byTooltip('Spalten verringern'));
    await tester.pump();
    await tester.tap(find.text('Tabelle einfügen').last);
    await tester.pumpAndSettle();

    expect(result, const RadialTableSize(4, 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('remains overflow-free on a compact display with large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 650);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: const Scaffold(
          body: TableInsertDialog(initialSize: RadialTableSize(12, 16)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Tabelle einfügen'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
