import 'dart:io';

import 'package:flowboard_x/src/app/app.dart';
import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/platform/android_widget_bridge.dart';
import 'package:flowboard_x/src/platform/smart_board_compatibility.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('widget deep link creates a locally time-named whiteboard', (
    tester,
  ) async {
    const channel = MethodChannel('test.flowboard/widget-new-whiteboard');
    var launchConsumed = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'consumeLaunchAction' && !launchConsumed) {
            launchConsumed = true;
            return <String, Object?>{
              'type': 'newWhiteboard',
              'eventId': 'new-whiteboard-event',
            };
          }
          if (call.method == 'updateDocuments') return 0;
          return null;
        });
    final bridge = AndroidWidgetBridge(channel: channel, isSupported: true);
    await bridge.initialize();
    final assets = Directory.systemTemp.createTempSync(
      'flowboard-widget-name-test-',
    );
    final repository = _RecordingRepository(assets);
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await bridge.dispose();
      if (assets.existsSync()) assets.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      FlowboardApp(
        repository: repository,
        androidWidgetBridge: bridge,
        smartBoardCompatibility: const _NonSmartBoardCompatibility(),
        clock: () => DateTime(2026, 7, 30, 15, 57),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(repository.saved, isNotEmpty);
    expect(repository.saved.first.title, '20260730-15_57');
    expect(
      repository.saved.first.createdAt,
      DateTime(2026, 7, 30, 15, 57).toUtc(),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

final class _RecordingRepository implements DocumentRepository {
  _RecordingRepository(this.assets);

  final Directory assets;
  final List<WhiteboardDocument> saved = <WhiteboardDocument>[];

  @override
  Future<Directory> assetDirectory(String documentId) async => assets;

  @override
  Future<void> delete(String documentId) async {}

  @override
  Future<List<DocumentSummary>> list() async =>
      saved.map(DocumentSummary.fromDocument).toList(growable: false);

  @override
  Future<WhiteboardDocument?> load(String documentId) async {
    for (final document in saved.reversed) {
      if (document.id == documentId) return document;
    }
    return null;
  }

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => null;

  @override
  Future<void> save(WhiteboardDocument document) async {
    saved.add(document);
  }
}

final class _NonSmartBoardCompatibility implements SmartBoardCompatibility {
  const _NonSmartBoardCompatibility();

  @override
  Future<bool> acknowledgeSetup() async => true;

  @override
  Future<SmartBoardCompatibilityStatus> getStatus() async =>
      SmartBoardCompatibilityStatus.unsupported;

  @override
  Future<bool> openSettings() async => false;
}
