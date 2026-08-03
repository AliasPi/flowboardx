import 'dart:async';

import 'package:flowboard_x/src/platform/android_palm_input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses the exact bounded native palmTrace schema', () async {
    const channel = MethodChannel('flowboard_test/palm_input');
    final bridge = AndroidPalmInputBridge(channel: channel, isSupported: true);
    addTearDown(bridge.close);
    final received = bridge.strokes.first;

    final encoded = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('palmTrace', <String, Object?>{
        'traceId': '4:900:2',
        'reason': 'system_canceled',
        'startedAsPalm': true,
        'radius': 34.5,
        'contactCount': 3,
        'points': <Object?>[
          <String, Object?>{'x': 120.0, 'y': 240.0, 'radius': 24.0},
          <String, Object?>{
            'x': 160.0,
            'y': 250.0,
            'radiusMajor': 34.5,
            'radiusMinor': 12.5,
            'orientation': .4,
            'timestampMillis': 944,
            'size': .72,
            'pressure': .63,
            'contactCount': 4,
          },
        ],
      }),
    );
    final response = Completer<void>();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          encoded,
          (_) => response.complete(),
        );
    await response.future;

    final stroke = await received;
    expect(stroke.sessionId, '4:900:2');
    expect(stroke.source, 'system_canceled');
    expect(stroke.startedAsPalm, isTrue);
    expect(stroke.radius, 34.5);
    expect(stroke.contactCount, 3);
    expect(stroke.points, const <Offset>[Offset(120, 240), Offset(160, 250)]);
    expect(stroke.samples, hasLength(2));
    expect(stroke.samples.first.position, const Offset(120, 240));
    expect(stroke.samples.first.radiusMajor, 24);
    expect(stroke.samples.first.radiusMinor, 0);
    expect(stroke.samples.last.position, const Offset(160, 250));
    expect(stroke.samples.last.radiusMajor, 34.5);
    expect(stroke.samples.last.radiusMinor, 12.5);
    expect(stroke.samples.last.orientation, .4);
    expect(stroke.samples.last.timeStamp, const Duration(milliseconds: 944));
    expect(stroke.samples.last.normalizedSize, .72);
    expect(stroke.samples.last.normalizedPressure, .63);
    expect(stroke.samples.last.contactCount, 4);
  });

  test('malformed native messages are ignored without stream errors', () async {
    const channel = MethodChannel('flowboard_test/palm_input_invalid');
    final bridge = AndroidPalmInputBridge(channel: channel, isSupported: true);
    addTearDown(bridge.close);
    var emissions = 0;
    final subscription = bridge.strokes.listen((_) => emissions++);
    addTearDown(subscription.cancel);

    final encoded = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('palmTrace', <String, Object?>{
        'traceId': '',
        'reason': 'system_canceled',
        'points': <Object?>[
          <String, Object?>{'x': double.nan, 'y': 10.0},
        ],
      }),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, encoded, (_) {});
    await Future<void>.delayed(Duration.zero);
    expect(emissions, 0);
  });
}
