import 'dart:math' as math;

import 'package:flutter/gestures.dart';

import 'eraser_contact_geometry.dart';

/// Hardware-tolerant classification of broad touch contacts.
///
/// Android boards do not report palm and fist contacts uniformly. Normalized
/// `size` and pressure are too ambiguous for destructive input, so this layer
/// requires physical contact axes and only uses `size` as corroboration. Native
/// palm signals and coherent multi-contact fallback detection cover devices
/// which do not expose usable axes.
final class TouchContactClassifier {
  const TouchContactClassifier({
    this.palmRadiusThreshold = 20,
    this.palmSizeThreshold = .24,
  });

  final double palmRadiusThreshold;
  final double palmSizeThreshold;

  bool isBroadTouch(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) return false;

    final firstRadius = _positive(event.radiusMajor);
    final secondRadius = _positive(event.radiusMinor);
    final major = math.max(firstRadius, secondRadius);
    final minor = math.min(firstRadius, secondRadius);
    final contactSize = _positive(event.size).clamp(0.0, 1.0);

    // `size` and `pressure` are not physical measurements on many Android
    // boards. Some drivers report 1.0 for every ordinary fingertip, and using
    // either value alone made taps, selection drags and pinch gestures
    // destructive. A broad decision therefore always needs calibrated contact
    // radius evidence. `size` may only corroborate a plausible ellipse.
    final oversizedSingleAxis =
        minor == 0 && major >= math.max(32.0, palmRadiusThreshold * 1.6);
    final elongatedHandEdge =
        major >= math.max(24.0, palmRadiusThreshold * 1.2) &&
        minor >= math.max(6.0, palmRadiusThreshold * .3) &&
        major / minor >= 2.5;
    final broadPalmPad =
        major >= math.max(20.0, palmRadiusThreshold) &&
        minor >= math.max(13.0, palmRadiusThreshold * .65);
    final sizeCorroboratedPad =
        major >= math.max(26.0, palmRadiusThreshold * 1.3) &&
        minor >= math.max(12.0, palmRadiusThreshold * .6) &&
        contactSize >= math.max(.48, palmSizeThreshold * 2);
    return oversizedSingleAxis ||
        elongatedHandEdge ||
        broadPalmPad ||
        sizeCorroboratedPad;
  }

  /// A deliberately conservative subset used to take over an established
  /// multi-touch navigation gesture. Normal finger zoom must never become
  /// destructive merely because its contact estimate fluctuates slightly.
  bool isStrongBroadTouch(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) return false;
    final firstRadius = _positive(event.radiusMajor);
    final secondRadius = _positive(event.radiusMinor);
    final major = math.max(firstRadius, secondRadius);
    final minor = math.min(firstRadius, secondRadius);
    // Taking over an established two-finger gesture is stricter again. Size
    // and pressure are ignored completely here; even values pinned at 1 must
    // never turn two normal finger ellipses into an eraser.
    final oversizedSingleAxis =
        minor == 0 && major >= math.max(38.0, palmRadiusThreshold * 1.9);
    final unmistakablePalm =
        major >= math.max(30.0, palmRadiusThreshold * 1.5) &&
        minor >= math.max(14.0, palmRadiusThreshold * .7);
    final unmistakableEdge =
        major >= math.max(30.0, palmRadiusThreshold * 1.5) &&
        minor >= math.max(8.0, palmRadiusThreshold * .4) &&
        major / minor >= 2.5;
    return oversizedSingleAxis || unmistakablePalm || unmistakableEdge;
  }

  double eraserRadiusFor(PointerEvent event) {
    final reportedRadius = math.max(
      _positive(event.radiusMajor),
      _positive(event.radiusMinor),
    );
    final contactSize = _positive(event.size).clamp(0.0, 1.0);
    final measuredRadius = reportedRadius * 1.15;
    // Once physical axes establish a broad contact, normalized size may only
    // refine their current extent. SMART-class drivers can pin size to 1.0;
    // tying the cap to the live measured radius lets a shrinking contact
    // shrink immediately instead of retaining a large normalized-size brush.
    final sizeRadius =
        reportedRadius > 0 && contactSize > 0 && isBroadTouch(event)
        ? measuredRadius +
              contactSize * math.min(10.0, math.max(4.0, measuredRadius * .22))
        : 0.0;
    return math
        .max(18.0, math.max(measuredRadius, sizeRadius))
        .clamp(18.0, 72.0);
  }

  /// Returns a centred approximation of the actual physical contact area.
  ///
  /// The scalar fallback fills incomplete or quantized axes after physical
  /// measurements have established a broad contact. Their orientation is
  /// retained instead of erasing a large circle around one corner of the hand
  /// footprint.
  List<EraserBrushStamp> eraserFootprintFor(
    PointerEvent event, {
    required Offset center,
  }) {
    return EraserContactGeometry.touchScreenFootprint(
      center: center,
      radiusMajor: event.radiusMajor,
      radiusMinor: event.radiusMinor,
      orientation: event.orientation,
      fallbackRadius: eraserRadiusFor(event),
    );
  }

  static double _positive(double value) =>
      value.isFinite && value > 0 ? value : 0;
}
