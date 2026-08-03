import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/editor/editor_pen_quick_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('colour shortcut applies a palette colour and opens free colour', (
    tester,
  ) async {
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
  });

  testWidgets('pen type shortcut exposes exactly the requested quick modes', (
    tester,
  ) async {
    InkToolType? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorPenTypeQuickButton(
            type: InkToolType.normal,
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
    expect(find.text('Gestrichelt'), findsOneWidget);
    expect(find.text('Gerade Linie'), findsOneWidget);
    expect(find.text('Marker'), findsNothing);

    await tester.tap(find.text('Gerade Linie'));
    await tester.pumpAndSettle();
    expect(selected, InkToolType.straightLine);
    expect(tester.takeException(), isNull);
  });

  test('pen type labels and icons also represent the radial marker mode', () {
    expect(editorPenTypeLabel(InkToolType.marker), 'Marker');
    expect(editorPenTypeIcon(InkToolType.marker), Icons.border_color_rounded);
  });
}
