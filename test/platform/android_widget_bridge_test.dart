import 'package:flowboard_x/src/platform/android_widget_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('serializes, sorts, and de-duplicates recent documents', () async {
    const channel = MethodChannel('test.flowboard/widget');
    List<Object?>? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'consumeLaunchAction') return null;
          if (call.method == 'updateDocuments') {
            final arguments = Map<Object?, Object?>.from(call.arguments as Map);
            captured = List<Object?>.from(arguments['documents']! as List);
            return captured!.length;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final bridge = AndroidWidgetBridge(channel: channel, isSupported: true);
    addTearDown(bridge.dispose);

    final count = await bridge.updateRecentDocuments([
      WidgetDocument(
        id: 'a',
        title: 'Alt',
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(10),
      ),
      WidgetDocument(
        id: 'b',
        title: 'Neu',
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(30),
      ),
      WidgetDocument(
        id: 'a',
        title: 'Aktualisiert',
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(20),
      ),
    ]);

    expect(count, 2);
    final first = Map<Object?, Object?>.from(captured!.first! as Map);
    final second = Map<Object?, Object?>.from(captured![1]! as Map);
    expect(first['id'], 'b');
    expect(second['title'], 'Aktualisiert');
  });

  test('queues a cold-start widget launch action', () async {
    const channel = MethodChannel('test.flowboard/widget-launch');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'consumeLaunchAction') {
            return <String, Object?>{
              'type': 'openDocument',
              'documentId': 'board-42',
              'eventId': 'event-1',
            };
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final bridge = AndroidWidgetBridge(channel: channel, isSupported: true);
    addTearDown(bridge.dispose);

    await bridge.initialize();
    final action = bridge.consumePendingLaunchAction();
    expect(action?.type, WidgetLaunchActionType.openDocument);
    expect(action?.documentId, 'board-42');
    expect(bridge.hasPendingLaunchAction, isFalse);
  });

  test('validates widget payloads defensively', () {
    expect(
      () =>
          WidgetLaunchAction.fromMap({'type': 'openDocument', 'eventId': 'x'}),
      throwsFormatException,
    );
    expect(
      () => WidgetDocument.fromMap({
        'id': 'a',
        'title': 'Board',
        'updatedAtEpochMillis': -1,
      }),
      throwsFormatException,
    );
  });
}
