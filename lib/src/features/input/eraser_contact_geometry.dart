import 'dart:math' as math;

import 'package:flutter/gestures.dart';
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
  /// Board-scale radius used only after a palm/fist gate has established
  /// destructive intent. Ordinary fingers never receive this minimum.
  static const double minimumRecognizedFistScreenRadius = 44;
  static const double maximumRecognizedFistScreenRadius = 132;

  static const double minimumAutomaticToolScreenRadius = 16;
  static const double maximumAutomaticToolScreenRadius = 48;

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

  /// Resolves an explicitly selected or hardware-reported eraser in screen
  /// pixels without consulting the current pen width.
  ///
  /// Calibrated contact axes are the primary signal. Selected stylus erasers
  /// often expose no useful axes, so normalized pressure is used only as a
  /// small, bounded size refinement after eraser intent is already known.
  /// Inverted stylus / hardware eraser contacts receive a slightly larger
  /// fallback because large interactive displays commonly use that Android
  /// tool type for the physical pen eraser or Object Awareness contact.
  static double automaticToolScreenRadius(PointerEvent event) {
    final firstRadius = _positive(event.radiusMajor);
    final secondRadius = _positive(event.radiusMinor);
    final measuredRadius = math.max(firstRadius, secondRadius);
    final baseRadius = event.kind == PointerDeviceKind.invertedStylus
        ? 22.0
        : minimumAutomaticToolScreenRadius;
    final physicalRadius = measuredRadius > 0 ? measuredRadius * 1.12 : 0.0;
    final size = _unit(event.size);
    final sizeRadius =
        size > 0 &&
            (measuredRadius > 0 ||
                event.kind == PointerDeviceKind.invertedStylus)
        ? baseRadius + size * 22
        : 0.0;
    final pressure = _normalizedPressure(event);
    final pressureRadius = baseRadius + pressure * 9;
    return math
        .max(
          baseRadius,
          math.max(physicalRadius, math.max(sizeRadius, pressureRadius)),
        )
        .clamp(
          minimumAutomaticToolScreenRadius,
          maximumAutomaticToolScreenRadius,
        )
        .toDouble();
  }

  /// Stabilizes live stylus/hardware eraser geometry without introducing a
  /// perceptible delay when the physical contact grows.
  static double smoothAutomaticToolScreenRadius({
    required double previousRadius,
    required double targetRadius,
    required Duration elapsed,
  }) {
    final previous = previousRadius.isFinite && previousRadius > 0
        ? previousRadius.clamp(
            minimumAutomaticToolScreenRadius,
            maximumAutomaticToolScreenRadius,
          )
        : targetRadius;
    final target = targetRadius.isFinite && targetRadius > 0
        ? targetRadius.clamp(
            minimumAutomaticToolScreenRadius,
            maximumAutomaticToolScreenRadius,
          )
        : previous;
    if ((target - previous).abs() <= .75) return previous.toDouble();
    final milliseconds = elapsed.inMicroseconds / 1000;
    final safeMilliseconds = milliseconds.isFinite && milliseconds > 0
        ? milliseconds.clamp(1.0, 80.0)
        : 16.0;
    final growing = target > previous;
    final timeConstant = growing ? 10.0 : 80.0;
    final alpha = (1 - math.exp(-safeMilliseconds / timeConstant)).clamp(
      growing ? .65 : .10,
      growing ? .97 : .50,
    );
    return (previous + (target - previous) * alpha)
        .clamp(
          minimumAutomaticToolScreenRadius,
          maximumAutomaticToolScreenRadius,
        )
        .toDouble();
  }

  /// Fuses physical and vendor-specific signals after a contact has already
  /// been recognized as a palm/fist.
  ///
  /// [clusterEnvelopeRadius] is the contact-centred hull of a fist which an IR
  /// board reported as several fingertips. Pressure never participates in
  /// recognition; here it can add only a small fallback refinement. This keeps
  /// the destructive decision conservative while making the accepted eraser
  /// match the area actually resting on the glass.
  static double recognizedFistScreenRadius({
    required double measuredRadius,
    required double normalizedSize,
    required double normalizedPressure,
    int contactCount = 1,
    double clusterEnvelopeRadius = 0,
  }) {
    final reported = _positive(measuredRadius);
    final size = _unit(normalizedSize);
    final pressure = _unit(normalizedPressure);
    final contacts = contactCount.clamp(1, 8);
    final clusterEnvelope = _positive(clusterEnvelopeRadius);

    // TOUCH_MAJOR/MINOR and the split-contact hull are current physical
    // measurements. A small ergonomic margin makes the wipe feel like the
    // lower surface of the fist without turning the reported radius into a
    // permanent maximum.
    final measuredTarget = reported > 0 ? reported * 1.12 + 6 : 0.0;
    final clusterTarget = clusterEnvelope > 0
        ? clusterEnvelope * 1.08 + 6
        : 0.0;

    // Vendor-normalized SIZE is useful after fist intent is known, but it is
    // noisy around the resting value. A dead zone followed by smoothstep gives
    // fine control in the middle without cursor flicker near the minimum.
    final rawSizeProgress = ((size - .34) / .66).clamp(0.0, 1.0);
    final sizeProgress =
        rawSizeProgress * rawSizeProgress * (3 - 2 * rawSizeProgress);
    final physicalTarget = math.max(
      minimumRecognizedFistScreenRadius,
      math.max(measuredTarget, clusterTarget),
    );
    final hasPhysicalArea = reported > 0 || clusterEnvelope > 0;
    final sizeTarget = hasPhysicalArea
        // `SIZE` is commonly pinned to 1.0 on SMART-class panels. When a real
        // TOUCH axis or cluster hull exists it may refine that measurement,
        // but can never replace it with the full normalized-size range.
        ? physicalTarget +
              sizeProgress * math.min(10.0, math.max(4.0, physicalTarget * .15))
        // Some native palm packets expose no calibrated TOUCH axes at all. In
        // that explicit post-classification case SIZE remains the best bounded
        // fallback available.
        : minimumRecognizedFistScreenRadius + sizeProgress * 78;

    final areaTarget = math.max(physicalTarget, sizeTarget);
    var target = areaTarget;

    // Contact count is not an area measurement. Use it only as a conservative
    // fallback if a split-contact driver supplies no usable axes, SIZE or hull.
    // In the normal clustered path the real envelope above is authoritative.
    if (reported == 0 && clusterEnvelope == 0 && size <= .34 && contacts > 1) {
      target = math.max(
        target,
        minimumRecognizedFistScreenRadius + math.min(6, (contacts - 1) * 2),
      );
    }

    // Pressure can be pinned to one on classroom panels. It therefore gets
    // only a tiny bounded refinement and can never dominate the live area.
    final pressureProgress = ((pressure - .22) / .78).clamp(0.0, 1.0);
    final dynamicExtent = math.max(
      0.0,
      areaTarget - minimumRecognizedFistScreenRadius,
    );
    target += pressureProgress * math.min(6.0, 3.0 + dynamicExtent * .05);
    return target
        .clamp(
          minimumRecognizedFistScreenRadius,
          maximumRecognizedFistScreenRadius,
        )
        .toDouble();
  }

  /// Attack/release filtering for an already recognized eraser footprint.
  ///
  /// Growth follows a settling fist quickly. Shrinkage is deliberately slower
  /// so one quantized packet cannot make the cursor pulse, but unlike the old
  /// running maximum it still follows a hand which reduces its contact area.
  static double smoothRecognizedScreenRadius({
    required double previousRadius,
    required double targetRadius,
    required Duration elapsed,
  }) {
    final validTarget = targetRadius.isFinite && targetRadius > 0
        ? targetRadius
        : minimumRecognizedFistScreenRadius;
    final target = validTarget
        .clamp(
          minimumRecognizedFistScreenRadius,
          maximumRecognizedFistScreenRadius,
        )
        .toDouble();
    final previous =
        (previousRadius.isFinite && previousRadius > 0
                ? previousRadius
                : target)
            .clamp(
              minimumRecognizedFistScreenRadius,
              maximumRecognizedFistScreenRadius,
            )
            .toDouble();
    final delta = target - previous;
    final deadZone = (previous * .018).clamp(.9, 2.2).toDouble();
    if (delta.abs() <= deadZone) return previous;
    final milliseconds = elapsed.inMicroseconds / 1000;
    final safeMilliseconds = milliseconds.isFinite && milliseconds > 0
        ? milliseconds.clamp(1.0, 80.0)
        : 16.0;
    final growing = delta > 0;
    final timeConstant = growing ? 18.0 : 65.0;
    final calculatedAlpha = 1 - math.exp(-safeMilliseconds / timeConstant);
    final alpha = calculatedAlpha.clamp(
      growing ? .50 : .10,
      growing ? .92 : .55,
    );
    return (previous + delta * alpha)
        .clamp(
          minimumRecognizedFistScreenRadius,
          maximumRecognizedFistScreenRadius,
        )
        .toDouble();
  }

  /// Best available radius of one reported screen contact.
  ///
  /// This is non-destructive geometry only. Callers must complete their
  /// separate palm/fist arbitration before using it to erase.
  static double reportedContactScreenRadius(
    PointerEvent event, {
    double fallback = 10,
  }) {
    final measured = math.max(
      _positive(event.radiusMajor),
      _positive(event.radiusMinor),
    );
    if (measured > 0) return measured.clamp(2.0, 80.0).toDouble();
    return _safeRadius(fallback, fallback: 10).clamp(2.0, 80.0).toDouble();
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

    // The normalized Android size axis frequently reacts to a larger resting
    // area even when touchMajor/touchMinor stay quantized at one small value.
    // [fallbackRadius] already fuses those signals in PointerPolicy (and in
    // the native palm bridge). Use it as a minimum physical extent and scale
    // both measured axes proportionally, so the visible cursor and the actual
    // partial eraser grow together without changing the contact's centre.
    if (fallback > major) {
      final scale = fallback / major;
      major = fallback;
      minor *= scale;
    }
    major = major.clamp(1.0, maximumRecognizedFistScreenRadius);
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

  static double _unit(double value) =>
      value.isFinite && value > 0 ? value.clamp(0.0, 1.0).toDouble() : 0;

  static double _normalizedPressure(PointerEvent event) {
    final range = event.pressureMax - event.pressureMin;
    if (!range.isFinite ||
        range <= .05 ||
        !event.pressure.isFinite ||
        !event.pressureMin.isFinite) {
      return 0;
    }
    return ((event.pressure - event.pressureMin) / range)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  static double _safeRadius(double value, {required double fallback}) =>
      value.isFinite && value > 0
      ? value.clamp(1.0, maximumRecognizedFistScreenRadius).toDouble()
      : fallback;
}
