import 'dart:math' as math;

import 'package:flutter/gestures.dart';

import 'eraser_contact_geometry.dart';

/// Hardware-tolerant classification of broad touch contacts.
///
/// Android boards do not report palm and fist contacts uniformly: some expose
/// physical radii, while others only populate the normalized `size` axis. This
/// classifier is shared by board input and global gestures so that a broad
/// eraser contact can never be mistaken for a five-finger command.
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
    final pressure = _normalizedPressure(event);

    final definitelyLarge = major >= palmRadiusThreshold;
    final androidFatTouch = contactSize >= palmSizeThreshold;
    final elongatedHandEdge =
        major >= palmRadiusThreshold * .82 &&
        minor >= 5 &&
        major / minor >= 2.2;
    final broadPalmPad =
        major >= palmRadiusThreshold * .77 &&
        minor >= palmRadiusThreshold * .54;
    final firmBroadContact =
        major >= palmRadiusThreshold * .7 &&
        minor >= palmRadiusThreshold * .36 &&
        contactSize >= palmSizeThreshold * .64 &&
        pressure >= .88;
    return definitelyLarge ||
        androidFatTouch ||
        elongatedHandEdge ||
        broadPalmPad ||
        firmBroadContact;
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
    final contactSize = _positive(event.size).clamp(0.0, 1.0);
    // Keep established two-finger navigation deliberately stricter than a
    // down-time palm decision. Samsung's full-finger estimate can fluctuate
    // around .27-.29 during pinch/zoom even though a palm is usually >= .30.
    return contactSize >= math.max(.30, palmSizeThreshold * 1.07) ||
        major >= palmRadiusThreshold * 1.18 ||
        (major >= palmRadiusThreshold * .95 &&
            minor >= palmRadiusThreshold * .45);
  }

  double eraserRadiusFor(PointerEvent event) {
    final reportedRadius = math.max(
      _positive(event.radiusMajor),
      _positive(event.radiusMinor),
    );
    final contactSize = _positive(event.size).clamp(0.0, 1.0);
    final sizeRadius = contactSize > 0 ? 18 + contactSize * 60 : 0.0;
    return math
        .max(18.0, math.max(reportedRadius * 1.15, sizeRadius))
        .clamp(18.0, 72.0);
  }

  /// Returns a centred approximation of the actual physical contact area.
  ///
  /// The scalar fallback remains important for panels which only expose the
  /// normalized size axis. Whenever calibrated major/minor axes exist, their
  /// orientation is retained instead of erasing a large circle around one
  /// corner of the hand footprint.
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

  static double _normalizedPressure(PointerEvent event) {
    final range = event.pressureMax - event.pressureMin;
    if (!event.pressure.isFinite || !range.isFinite || range <= 0) return 0;
    return ((event.pressure - event.pressureMin) / range).clamp(0.0, 1.0);
  }
}
