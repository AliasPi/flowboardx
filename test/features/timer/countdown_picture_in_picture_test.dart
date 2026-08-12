import 'package:flowboard_x/src/app/app_theme.dart';
import 'package:flowboard_x/src/features/timer/countdown_timer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AndroidCountdownPictureInPicture.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'bridge synchronizes active state and receives native mode changes',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return <String, Object?>{
          'supported': true,
          'inPictureInPicture': false,
        };
      });
      final bridge = AndroidCountdownPictureInPicture(
        channel: channel,
        isAndroid: true,
      );
      addTearDown(bridge.dispose);

      await bridge.refresh();
      expect(bridge.isSupported, isTrue);

      await bridge.setTimerActive(true);
      expect(calls.last.method, 'setTimerActive');
      expect(calls.last.arguments, <String, Object?>{'active': true});

      final message = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('pictureInPictureChanged', true),
      );
      await messenger.handlePlatformMessage(channel.name, message, (_) {});

      expect(bridge.isInPictureInPictureMode, isTrue);
    },
  );

  test('explicit entry degrades safely when Android declines it', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'enterNow' ? false : null,
    );
    final bridge = AndroidCountdownPictureInPicture(
      channel: channel,
      isAndroid: true,
    );
    addTearDown(bridge.dispose);

    expect(await bridge.enterNow(), isFalse);
  });

  testWidgets('PiP surface renders only the synchronized countdown', (
    tester,
  ) async {
    final controller = CountdownTimerController(
      initialDuration: const Duration(minutes: 10),
    );
    addTearDown(controller.dispose);
    controller.start();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: CountdownTimerPictureInPictureView(controller: controller),
      ),
    );

    expect(
      find.byKey(const ValueKey('countdown-picture-in-picture')),
      findsOneWidget,
    );
    expect(find.text('10:00'), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    controller.dispose();
  });
}
