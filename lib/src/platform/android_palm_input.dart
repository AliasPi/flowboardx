import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Source of Android palm-rejection traces which Flutter's pointer packet does
/// not expose reliably (notably MotionEvent.FLAG_CANCELED on Android 13+).
abstract interface class PalmInputSource {
  Stream<NativePalmStroke> get strokes;
}

/// Observes the native MotionEvent bridge without consuming Android input.
///
/// Coordinates are logical, Flutter-view-global coordinates. Consumers still
/// select the owning render box, which keeps split-screen participants isolated.
final class AndroidPalmInputBridge implements PalmInputSource {
  AndroidPalmInputBridge({MethodChannel? channel, bool? isSupported})
    : _channel = channel ?? const MethodChannel(channelName),
      _isSupported =
          isSupported ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    if (_isSupported) _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const String channelName = 'de.flowboardx/palm_input';
  static const String strokeMethod = 'palmTrace';
  static final AndroidPalmInputBridge instance = AndroidPalmInputBridge();

  final MethodChannel _channel;
  final bool _isSupported;
  final StreamController<NativePalmStroke> _controller =
      StreamController<NativePalmStroke>.broadcast(sync: true);
  bool _closed = false;

  @override
  Stream<NativePalmStroke> get strokes => _controller.stream;

  Future<void> _handleMethodCall(MethodCall call) async {
    if (_closed || call.method != strokeMethod) return;
    final stroke = NativePalmStroke.tryParse(call.arguments);
    if (stroke != null) _controller.add(stroke);
  }

  @visibleForTesting
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_isSupported) _channel.setMethodCallHandler(null);
    await _controller.close();
  }
}

@immutable
final class NativePalmStroke {
  const NativePalmStroke({
    required this.sessionId,
    required this.points,
    required this.radius,
    required this.contactCount,
    required this.source,
    this.startedAsPalm = false,
    this.samples = const <NativePalmSample>[],
  });

  final String sessionId;
  final List<Offset> points;
  final double radius;
  final int contactCount;

  /// Per-sample contact geometry when provided by the Android bridge.
  ///
  /// [points] remains part of the public shape for backwards compatibility
  /// with older native messages and deterministic test sources.
  final List<NativePalmSample> samples;

  /// A bounded machine token such as `flag_cancel` or `tool_palm`.
  final String source;

  /// Whether Android reported `TOOL_TYPE_PALM` on the initial DOWN packet.
  /// A later FINGER-to-PALM promotion can be a misclassified selection; an
  /// initial palm is explicit destructive intent from the device.
  final bool startedAsPalm;

  static NativePalmStroke? tryParse(Object? value) {
    if (value is! Map) return null;
    final rawId = value['traceId'];
    final rawPoints = value['points'];
    if (rawId is! String ||
        rawId.isEmpty ||
        rawId.length > 96 ||
        rawPoints is! List ||
        rawPoints.isEmpty) {
      return null;
    }
    final points = <Offset>[];
    final samples = <NativePalmSample>[];
    for (final rawPoint in rawPoints.take(192)) {
      if (rawPoint is! Map) continue;
      final x = rawPoint['x'];
      final y = rawPoint['y'];
      if (x is! num || y is! num || !x.isFinite || !y.isFinite) continue;
      final position = Offset(x.toDouble(), y.toDouble());
      points.add(position);
      final rawMajor = rawPoint['radiusMajor'] ?? rawPoint['radius'];
      final rawMinor = rawPoint['radiusMinor'];
      final rawOrientation = rawPoint['orientation'];
      final rawTimestamp = rawPoint['timestampMillis'];
      final rawSize = rawPoint['size'];
      final rawPressure = rawPoint['pressure'];
      final rawSampleContacts = rawPoint['contactCount'];
      final major = rawMajor is num && rawMajor.isFinite
          ? rawMajor.toDouble().clamp(0.0, 160.0)
          : 0.0;
      final minor = rawMinor is num && rawMinor.isFinite
          ? rawMinor.toDouble().clamp(0.0, 160.0)
          : 0.0;
      final orientation = rawOrientation is num && rawOrientation.isFinite
          ? rawOrientation.toDouble().clamp(
              -1.5707963267948966,
              1.5707963267948966,
            )
          : 0.0;
      samples.add(
        NativePalmSample(
          position: position,
          radiusMajor: major,
          radiusMinor: minor,
          orientation: orientation,
          timeStamp: rawTimestamp is num && rawTimestamp.isFinite
              ? Duration(
                  microseconds: (rawTimestamp.toDouble() * 1000).round().clamp(
                    0,
                    0x7FFFFFFFFFFFFFFF,
                  ),
                )
              : Duration.zero,
          normalizedSize: rawSize is num && rawSize.isFinite
              ? rawSize.toDouble().clamp(0.0, 1.0)
              : 0,
          normalizedPressure: rawPressure is num && rawPressure.isFinite
              ? rawPressure.toDouble().clamp(0.0, 1.0)
              : 0,
          contactCount: rawSampleContacts is num
              ? rawSampleContacts.toInt().clamp(1, 10)
              : 1,
        ),
      );
    }
    if (points.isEmpty) return null;

    final rawRadius = value['radius'];
    final radius = rawRadius is num && rawRadius.isFinite
        ? rawRadius.toDouble().clamp(18.0, 132.0)
        : 32.0;
    final rawContacts = value['contactCount'];
    final contactCount = rawContacts is num
        ? rawContacts.toInt().clamp(1, 10)
        : 1;
    final rawSource = value['reason'];
    final source =
        rawSource is String && RegExp(r'^[a-z0-9_]{1,32}$').hasMatch(rawSource)
        ? rawSource
        : 'native_palm';
    final startedAsPalm = value['startedAsPalm'] == true;
    return NativePalmStroke(
      sessionId: rawId,
      points: List<Offset>.unmodifiable(points),
      radius: radius,
      contactCount: contactCount,
      source: source,
      startedAsPalm: startedAsPalm,
      samples: List<NativePalmSample>.unmodifiable(samples),
    );
  }
}

@immutable
final class NativePalmSample {
  const NativePalmSample({
    required this.position,
    required this.radiusMajor,
    required this.radiusMinor,
    required this.orientation,
    this.timeStamp = Duration.zero,
    this.normalizedSize = 0,
    this.normalizedPressure = 0,
    this.contactCount = 1,
  });

  final Offset position;
  final double radiusMajor;
  final double radiusMinor;
  final Duration timeStamp;
  final double normalizedSize;
  final double normalizedPressure;
  final int contactCount;

  /// Contact-major-axis angle measured from positive Y, in radians.
  final double orientation;
}
