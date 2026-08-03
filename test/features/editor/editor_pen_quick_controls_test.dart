import 'package:flowboard_x/src/features/editor/editor_pen_quick_controls.dart';
import 'package:flowboard_x/src/features/radial_menu/radial_menu_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'colour shortcut applies a palette colour and opens free colour',
    (tester) async {
      Color? selected;
      var customRequests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EditorPenColorQuickButton(
              color: Colors.black,
              onColorSelected: (value) => selected = value,
              onCustomColorRequested: () => customRequests++,
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('editor-pen-color-quick-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rot'));
      await tester.pumpAndSettle();
      expect(selected, const Color(0xFFF44336));

      await tester.tap(
        find.byKey(const ValueKey('editor-pen-color-quick-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Freie Farbe …'));
      await tester.pumpAndSettle();
      expect(customRequests, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pen type shortcut exposes every pen and eraser mode', (
    tester,
  ) async {
    RadialPenType? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorPenTypeQuickButton(
            type: RadialPenType.normal,
            onTypeSelected: (value) => selected = value,
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('editor-pen-type-quick-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('Marker'), findsOneWidget);
    expect(find.text('Gestrichelt'), findsOneWidget);
    expect(find.text('Gerade Linie'), findsOneWidget);
    expect(find.text('Radiergummi'), findsOneWidget);

    await tester.tap(find.text('Marker'));
    await tester.pumpAndSettle();
    expect(selected, RadialPenType.marker);

    await tester.tap(
      find.byKey(const ValueKey('editor-pen-type-quick-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Radiergummi'));
    await tester.pumpAndSettle();
    expect(selected, RadialPenType.eraser);
    expect(tester.takeException(), isNull);
  });

  test('pen type labels and icons represent marker and eraser modes', () {
    expect(editorPenTypeLabel(RadialPenType.marker), 'Marker');
    expect(editorPenTypeIcon(RadialPenType.marker), Icons.border_color_rounded);
    expect(editorPenTypeLabel(RadialPenType.eraser), 'Radiergummi');
    expect(
      editorPenTypeIcon(RadialPenType.eraser),
      Icons.cleaning_services_rounded,
    );
  });
}
