import 'dart:io';

import 'package:flowboard_x/src/app/app.dart';
import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/platform/smart_board_compatibility.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SMART hardware gets the documented per-app setup flow', (
    tester,
  ) async {
    final compatibility = _FakeSmartBoardCompatibility();
    await tester.pumpWidget(
      FlowboardApp(
        repository: _EmptyRepository(),
        smartBoardCompatibility: compatibility,
      ),
    );
    await tester.pump();

    expect(find.text('SMART Board für Flowboard X einrichten'), findsOneWidget);
    expect(find.textContaining('Annotation auswählen'), findsOneWidget);
    expect(find.textContaining('Flowboard X suchen'), findsOneWidget);

    await tester.tap(find.text('Einstellungen öffnen'));
    await tester.pump();
    expect(compatibility.openSettingsCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(find.text('SMART-Anmerkung ausgeschaltet?'), findsOneWidget);

    await tester.tap(find.text('Ja, erledigt'));
    await tester.pump();
    expect(compatibility.acknowledgeCalls, 1);
    expect(find.text('SMART-Anmerkung ausgeschaltet?'), findsNothing);
  });

  testWidgets('other Android and desktop devices get no SMART setup dialog', (
    tester,
  ) async {
    final compatibility = _FakeSmartBoardCompatibility(isSmartBoard: false);
    await tester.pumpWidget(
      FlowboardApp(
        repository: _EmptyRepository(),
        smartBoardCompatibility: compatibility,
      ),
    );
    await tester.pump();

    expect(find.text('SMART Board für Flowboard X einrichten'), findsNothing);
    expect(compatibility.openSettingsCalls, 0);
  });
}

final class _FakeSmartBoardCompatibility implements SmartBoardCompatibility {
  _FakeSmartBoardCompatibility({this.isSmartBoard = true});

  final bool isSmartBoard;
  int openSettingsCalls = 0;
  int acknowledgeCalls = 0;

  @override
  Future<SmartBoardCompatibilityStatus> getStatus() async =>
      SmartBoardCompatibilityStatus(
        isSmartBoard: isSmartBoard,
        setupAcknowledged: false,
        manufacturer: isSmartBoard ? 'SMART Technologies' : 'Other',
        model: isSmartBoard ? 'MX286 Pro' : 'Tablet',
        androidSdk: 30,
      );

  @override
  Future<bool> openSettings() async {
    openSettingsCalls++;
    return true;
  }

  @override
  Future<bool> acknowledgeSetup() async {
    acknowledgeCalls++;
    return true;
  }
}

final class _EmptyRepository implements DocumentRepository {
  @override
  Future<Directory> assetDirectory(String documentId) async =>
      Directory.current;

  @override
  Future<void> delete(String documentId) async {}

  @override
  Future<List<DocumentSummary>> list() async => const <DocumentSummary>[];

  @override
  Future<WhiteboardDocument?> load(String documentId) async => null;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => null;

  @override
  Future<void> save(WhiteboardDocument document) async {}
}
