import 'package:flowboard_x/src/app/app_theme.dart';
import 'package:flowboard_x/src/app/brand_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app theme and brand mark render', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: const Scaffold(body: Center(child: FlowboardMark())),
      ),
    );

    expect(find.byType(FlowboardMark), findsOneWidget);
    expect(find.bySemanticsLabel('Flowboard X'), findsOneWidget);
  });
}
