import 'package:flowboard_x/src/app/app_theme.dart';
import 'package:flowboard_x/src/features/editor/editor_help_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('offers an explicit sanitized diagnostics export', (
    tester,
  ) async {
    var exports = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: Scaffold(
          body: FlowboardHelpDialog(onExportDiagnostics: () async => exports++),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('export-diagnostics-button')));
    await tester.pump();

    expect(exports, 1);
  });
}
