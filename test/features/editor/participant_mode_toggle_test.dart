import 'package:flowboard_x/src/features/editor/participant_mode_toggle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('participant mode toggle exposes and selects both modes', (
    tester,
  ) async {
    var mode = EditorParticipantMode.onePerson;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ParticipantModeToggle(
              mode: mode,
              onChanged: (value) => setState(() => mode = value),
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('Eine Person'), findsOneWidget);
    expect(find.byTooltip('Zwei Personen'), findsOneWidget);

    await tester.tap(find.byTooltip('Zwei Personen'));
    await tester.pump();

    expect(mode, EditorParticipantMode.twoPeople);
    final control = tester.widget<SegmentedButton<EditorParticipantMode>>(
      find.byType(SegmentedButton<EditorParticipantMode>),
    );
    expect(control.selected, <EditorParticipantMode>{mode});
  });
}
