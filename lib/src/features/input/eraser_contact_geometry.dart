import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// One circular stamp used to approximate a physical contact ellipse.
///
/// The ink eraser operates on swept circles. Representing an elongated palm
/// contact as several symmetric stamps keeps the erased area centred under the
/// hand instead of turning the major axis into one oversized circular brush.
@immutable
final class EraserBrushStamp {
  const EraserBrushStamp({required this.center, required this.radius});

  final Offset center;
  final double radius;
}

/// Shared, deterministic geometry for stylus and broad-touch erasers.
abstract final class EraserContactGeometry {
  /// Converts the configured logical stroke/eraser diameter to a world radius.
  static double stylusWorldRadius(double logicalWidth) {
    final safeWidth = logicalWidth.isFinite && logicalWidth > 0
        ? logicalWidth
        : 8.0;
    return (safeWidth / 2).clamp(.25, 40.0);
  }

  /// Screen-space cursor radius for a world-space brush at the current zoom.
  static double cursorScreenRadius({
    required double logicalWidth,
    required double viewportScale,
  }) {
    final safeScale = viewportScale.isFinite && viewportScale > 0
        ? viewportScale
        : 1.0;
    return (stylusWorldRadius(logicalWidth) * safeScale).clamp(.5, 160.0);
  }

  /// Approximates the contact ellipse reported by Flutter/Android.
  ///
  /// [center] is already the centre of the physical contact area according to
  /// both Flutter's PointerEvent contract and Android's AXIS_X/AXIS_Y
  /// contract. Stamps are deliberately symmetric around it; neither contact
  /// radius is ever added to X or Y as if the coordinate were a top-left
  /// corner.
  ///
  /// Flutter measures touch [orientation] from the positive Y axis, hence the
  /// major-axis vector `(sin(angle), cos(angle))`.
  static List<EraserBrushStamp> touchScreenFootprint({
    required Offset center,
    required double radiusMajor,
    required double radiusMinor,
    required double orientation,
    required double fallbackRadius,
  }) {
    if (!center.dx.isFinite || !center.dy.isFinite) {
      return const <EraserBrushStamp>[];
    }
    final fallback = _safeRadius(fallbackRadius, fallback: 18);
    final reportedMajor = _positive(radiusMajor);
    final reportedMinor = _positive(radiusMinor);
    var major = math.max(reportedMajor, reportedMinor);
    var minor = reportedMajor > 0 && reportedMinor > 0
        ? math.min(reportedMajor, reportedMinor)
        : 0.0;
    if (major <= 0) {
      major = fallback;
      minor = fallback;
    } else if (minor <= 0) {
      // A number of Android panels expose only one calibrated axis. Treat it
      // as a circular contact instead of inventing an off-centre hand shape.
      minor = major;
    }
    major = major.clamp(1.0, 96.0);
    minor = minor.clamp(1.0, major);

    if (major / minor < 1.22) {
      return <EraserBrushStamp>[
        EraserBrushStamp(center: center, radius: major),
      ];
    }

    final safeOrientation = orientation.isFinite ? orientation : 0.0;
    final axis = Offset(math.sin(safeOrientation), math.cos(safeOrientation));
    // Five cross-sections give a close, bounded approximation while keeping
    // live erasing inexpensive. The fractions are symmetric, so their centre
    // of mass remains the actual hardware contact centre.
    const fractions = <double>[-.875, -.5, 0, .5, .875];
    return <EraserBrushStamp>[
      for (final fraction in fractions)
        EraserBrushStamp(
          center: center + axis * (major * fraction),
          radius: math.max(
            1.0,
            minor * math.sqrt(math.max(0, 1 - fraction * fraction)),
          ),
        ),
    ];
  }

  /// Radius of the smallest contact-centred circle containing every stamp.
  ///
  /// The UI cursor uses this exact value, so it always communicates the
  /// furthest point the current physical contact can erase.
  static double enclosingScreenRadius({
    required Offset center,
    required Iterable<EraserBrushStamp> footprint,
    double fallback = 18,
  }) {
    var maximum = 0.0;
    for (final stamp in footprint) {
      if (!stamp.center.dx.isFinite ||
          !stamp.center.dy.isFinite ||
          !stamp.radius.isFinite ||
          stamp.radius <= 0) {
        continue;
      }
      maximum = math.max(
        maximum,
        (stamp.center - center).distance + stamp.radius,
      );
    }
    return _safeRadius(maximum, fallback: fallback);
  }

  static double _positive(double value) =>
      value.isFinite && value > 0 ? value : 0;

  static double _safeRadius(double value, {required double fallback}) =>
      value.isFinite && value > 0 ? value.clamp(1.0, 96.0) : fallback;
}
