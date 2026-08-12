import 'package:flowboard_x/src/features/timer/countdown_timer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const alarmChannel = MethodChannel('de.flowboardx/countdown_alarm');

  test('Android alarm delegates play and stop to native alarm audio', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(alarmChannel, (call) async {
      calls.add(call);
      return call.method == 'play' ? true : null;
    });
    try {
      await SystemCountdownAlarm.play();
      await SystemCountdownAlarm.stop();

      expect(calls.map((call) => call.method), <String>['play', 'stop']);
    } finally {
      messenger.setMockMethodCallHandler(alarmChannel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test(
    'Android alarm has an audible fallback when native audio fails',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final platformCalls = <MethodCall>[];
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(alarmChannel, (_) async => false);
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call);
        return null;
      });
      try {
        await SystemCountdownAlarm.play();

        expect(
          platformCalls,
          contains(
            isMethodCall(
              'SystemSound.play',
              arguments: SystemSoundType.click.toString(),
            ),
          ),
        );
      } finally {
        messenger.setMockMethodCallHandler(alarmChannel, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test(
    'desktop alarm keeps using the supported Flutter system alert',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final nativeCalls = <MethodCall>[];
      final platformCalls = <MethodCall>[];
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      messenger.setMockMethodCallHandler(alarmChannel, (call) async {
        nativeCalls.add(call);
        return true;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call);
        return null;
      });
      try {
        await SystemCountdownAlarm.play();
        await SystemCountdownAlarm.stop();

        expect(nativeCalls, isEmpty);
        expect(
          platformCalls,
          contains(
            isMethodCall(
              'SystemSound.play',
              arguments: SystemSoundType.alert.toString(),
            ),
          ),
        );
      } finally {
        messenger.setMockMethodCallHandler(alarmChannel, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
