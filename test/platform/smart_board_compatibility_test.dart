import 'package:flowboard_x/src/platform/smart_board_compatibility.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses SMART status and forwards supported setup actions', () async {
    const channel = MethodChannel('smart-board-compatibility-test');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'getStatus' => <String, Object?>{
              'isSmartBoard': true,
              'setupAcknowledged': false,
              'manufacturer': 'SMART Technologies',
              'model': 'MX286 Pro',
              'androidSdk': 30,
            },
            'openSettings' || 'acknowledgeSetup' => true,
            _ => null,
          };
        });
    final bridge = SmartBoardCompatibilityBridge(
      channel: channel,
      isSupported: true,
    );
    addTearDown(() {
      bridge.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final status = await bridge.getStatus();
    expect(status.isSmartBoard, isTrue);
    expect(status.setupAcknowledged, isFalse);
    expect(status.deviceLabel, 'SMART Technologies · MX286 Pro');
    expect(status.androidSdk, 30);
    expect(await bridge.openSettings(), isTrue);
    expect(await bridge.acknowledgeSetup(), isTrue);
    expect(calls, <String>['getStatus', 'openSettings', 'acknowledgeSetup']);
  });

  test(
    'malformed status fails closed without showing SMART guidance',
    () async {
      const channel = MethodChannel('smart-board-malformed-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => <String, Object?>{'isSmartBoard': 'yes'},
          );
      final bridge = SmartBoardCompatibilityBridge(
        channel: channel,
        isSupported: true,
      );
      addTearDown(() {
        bridge.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      expect((await bridge.getStatus()).isSmartBoard, isFalse);
    },
  );
}
