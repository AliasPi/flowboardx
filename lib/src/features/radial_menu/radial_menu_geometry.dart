import 'dart:math' as math;

import 'package:flutter/widgets.dart';

enum RadialMenuLayer { none, center, primary, secondary, tertiary, thickness }

@immutable
class RadialHitTarget {
  const RadialHitTarget(this.layer, [this.index = -1]);

  static const RadialHitTarget none = RadialHitTarget(RadialMenuLayer.none);
  static const RadialHitTarget center = RadialHitTarget(RadialMenuLayer.center);
  static const RadialHitTarget thickness = RadialHitTarget(
    RadialMenuLayer.thickness,
  );

  final RadialMenuLayer layer;
  final int index;

  bool get isInteractive => layer != RadialMenuLayer.none;

  @override
  bool operator ==(Object other) {
    return other is RadialHitTarget &&
        other.layer == layer &&
        other.index == index;
  }

  @override
  int get hashCode => Object.hash(layer, index);

  @override
  String toString() => 'RadialHitTarget($layer, $index)';
}

/// Shared geometry used by painting, pointer hit testing and tests.
@immutable
class RadialMenuGeometry {
  const RadialMenuGeometry(this.size);

  static const double designDiameter = 600;
  static const double _twoPi = math.pi * 2;
  static const int primarySegmentCount = 10;
  static const int compactSubmenuSegmentSpan = 3;

  final Size size;

  double get scale => size.shortestSide / designDiameter;
  Offset get center => Offset(size.width / 2, size.height / 2);

  double get centerRadius => 58 * scale;
  double get tailInnerRadius => 51 * scale;
  double get tailOuterRadius => 55 * scale;
  double get primaryInnerRadius => 76 * scale;
  double get primaryOuterRadius => 150 * scale;
  double get secondaryInnerRadius => 158 * scale;
  double get secondaryOuterRadius => 216 * scale;
  double get tertiaryInnerRadius => 224 * scale;
  double get tertiaryOuterRadius => 286 * scale;

  double get primarySegmentSweep => _twoPi / primarySegmentCount;

  /// Submenus occupy at most the width of three primary segments. They are
  /// centered on their parent instead of creating another full-screen ring.
  double get compactSubmenuSpan =>
      primarySegmentSweep * compactSubmenuSegmentSpan;

  double primaryCenterAngle(int index) =>
      (index % primarySegmentCount) * primarySegmentSweep;

  double compactSubmenuStartAngle(int parentIndex) =>
      primaryCenterAngle(parentIndex) - compactSubmenuSpan / 2;

  /// The thickness gauge intentionally owns most of the outer pen fan. The
  /// four pen types stay grouped in the remaining compact block, matching the
  /// visual hierarchy of a wide physical thickness control beside four quick
  /// mode buttons.
  static const double penThicknessSpanFraction = .58;
  double get thicknessSpan => compactSubmenuSpan * penThicknessSpanFraction;
  double get thicknessStartAngle => compactSubmenuStartAngle(0);
  double get penTypesStartAngle => thicknessStartAngle + thicknessSpan;
  double get penTypesSpan => compactSubmenuSpan - thicknessSpan;

  double angleFor(Offset position) {
    final delta = position - center;
    var angle = math.atan2(delta.dy, delta.dx) + math.pi / 2;
    if (angle < 0) angle += _twoPi;
    return angle % _twoPi;
  }

  double radiusFor(Offset position) => (position - center).distance;

  Offset polarPoint(double radius, double topClockwiseAngle) {
    final canvasAngle = topClockwiseAngle - math.pi / 2;
    return center +
        Offset(math.cos(canvasAngle) * radius, math.sin(canvasAngle) * radius);
  }

  Offset pointForSegment({
    required int index,
    required int count,
    required double radius,
    double startAngle = 0,
    double span = _twoPi,
  }) {
    final sweep = span / count;
    return polarPoint(radius, startAngle + (index + .5) * sweep);
  }

  int segmentIndexAt(
    Offset position, {
    required int count,
    required double innerRadius,
    required double outerRadius,
    double startAngle = 0,
    double span = _twoPi,
    double gapRadians = .035,
  }) {
    if (count <= 0) return -1;
    final radius = radiusFor(position);
    if (radius < innerRadius || radius > outerRadius) return -1;

    var relative = angleFor(position) - startAngle;
    while (relative < 0) {
      relative += _twoPi;
    }
    relative %= _twoPi;
    if (relative >= span) return -1;
    final sweep = span / count;
    final index = (relative / sweep).floor();
    final within = relative - index * sweep;
    if (within < gapRadians / 2 || within > sweep - gapRadians / 2) {
      return -1;
    }
    return index.clamp(0, count - 1);
  }

  RadialHitTarget hitTest(
    Offset position, {
    required bool isOpen,
    required int secondaryCount,
    required int tertiaryCount,
    required bool hasThicknessSlider,
    double? secondaryStartAngle,
    double secondarySpan = _twoPi,
    double? tertiaryStartAngle,
    double tertiarySpan = _twoPi,
    double? thicknessStartAngle,
    double? thicknessSpan,
    double openProgress = 1,
    double submenuProgress = 1,
  }) {
    final radius = radiusFor(position);
    if (radius <= centerRadius) return RadialHitTarget.center;
    if (!isOpen) return RadialHitTarget.none;

    final opened = openProgress.clamp(0.0, 1.0);
    final submenu = submenuProgress.clamp(0.0, 1.0);
    final primaryCollapsed = tailOuterRadius + 4 * scale;
    final animatedPrimaryInner = _lerp(
      primaryCollapsed,
      primaryInnerRadius,
      opened,
    );
    final animatedPrimaryOuter = _lerp(
      primaryCollapsed + scale,
      primaryOuterRadius,
      opened,
    );
    // Keep the final ring footprint interactive while it animates out. This
    // makes the first deliberate tap after an editor rebuild land on the
    // requested item instead of being discarded by a temporarily collapsed
    // painter radius.
    final primaryInner = math.min(animatedPrimaryInner, primaryInnerRadius);
    final primaryOuter = math.max(animatedPrimaryOuter, primaryOuterRadius);
    final secondaryCollapsed = primaryOuterRadius + 4 * scale;
    final animatedSecondaryInner = _lerp(
      secondaryCollapsed,
      secondaryInnerRadius,
      submenu,
    );
    final animatedSecondaryOuter = _lerp(
      secondaryCollapsed + scale,
      secondaryOuterRadius,
      submenu,
    );
    final secondaryInner = math.min(
      animatedSecondaryInner,
      secondaryInnerRadius,
    );
    final secondaryOuter = math.max(
      animatedSecondaryOuter,
      secondaryOuterRadius,
    );
    final tertiaryCollapsed = secondaryOuterRadius + 4 * scale;
    final animatedTertiaryInner = _lerp(
      tertiaryCollapsed,
      tertiaryInnerRadius,
      submenu,
    );
    final animatedTertiaryOuter = _lerp(
      tertiaryCollapsed + scale,
      tertiaryOuterRadius,
      submenu,
    );
    final tertiaryInner = math.min(animatedTertiaryInner, tertiaryInnerRadius);
    final tertiaryOuter = math.max(animatedTertiaryOuter, tertiaryOuterRadius);

    if (radius >= tertiaryInner && radius <= tertiaryOuter) {
      if (hasThicknessSlider) {
        final sliderStart = thicknessStartAngle ?? this.thicknessStartAngle;
        final sliderSpan = thicknessSpan ?? this.thicknessSpan;
        if (_isAngleInArc(
          angleFor(position),
          sliderStart + .035 / 2,
          math.max(0, sliderSpan - .035),
        )) {
          return RadialHitTarget.thickness;
        }
      }
      final index = segmentIndexAt(
        position,
        count: tertiaryCount,
        innerRadius: tertiaryInner,
        outerRadius: tertiaryOuter,
        startAngle: tertiaryStartAngle ?? -math.pi / math.max(1, tertiaryCount),
        span: tertiarySpan,
        gapRadians: 0,
      );
      if (index >= 0) {
        return RadialHitTarget(RadialMenuLayer.tertiary, index);
      }
    }

    final secondaryIndex = segmentIndexAt(
      position,
      count: secondaryCount,
      innerRadius: secondaryInner,
      outerRadius: secondaryOuter,
      startAngle: secondaryStartAngle ?? -math.pi / math.max(1, secondaryCount),
      span: secondarySpan,
      gapRadians: 0,
    );
    if (secondaryIndex >= 0) {
      return RadialHitTarget(RadialMenuLayer.secondary, secondaryIndex);
    }

    final primaryIndex = segmentIndexAt(
      position,
      count: primarySegmentCount,
      innerRadius: primaryInner,
      outerRadius: primaryOuter,
      startAngle: -math.pi / primarySegmentCount,
      gapRadians: 0,
    );
    if (primaryIndex >= 0) {
      return RadialHitTarget(RadialMenuLayer.primary, primaryIndex);
    }

    return RadialHitTarget.none;
  }

  double _lerp(double from, double to, double progress) =>
      from + (to - from) * progress;

  double thicknessFractionFor(Offset position) {
    return arcFractionFor(
      position,
      startAngle: thicknessStartAngle,
      span: thicknessSpan,
    );
  }

  double arcFractionFor(
    Offset position, {
    required double startAngle,
    required double span,
  }) {
    if (span <= 0) return 0;
    var relative = angleFor(position) - startAngle;
    while (relative < 0) {
      relative += _twoPi;
    }
    relative %= _twoPi;
    return (relative / span).clamp(0, 1);
  }

  Path ringSegmentPath({
    required int index,
    required int count,
    required double innerRadius,
    required double outerRadius,
    double startAngle = 0,
    double span = _twoPi,
    double gapRadians = .035,
    double cornerRadius = 0,
  }) {
    final sweep = span / count;
    return roundedArcSegmentPath(
      startAngle: startAngle + index * sweep + gapRadians / 2,
      sweepAngle: sweep - gapRadians,
      innerRadius: innerRadius,
      outerRadius: outerRadius,
      cornerRadius: cornerRadius,
    );
  }

  /// A ring sector with rounded radial and circular-edge joins. The radius is
  /// clamped for narrow fan entries so adjacent targets can never overlap.
  Path roundedArcSegmentPath({
    required double startAngle,
    required double sweepAngle,
    required double innerRadius,
    required double outerRadius,
    double cornerRadius = 0,
  }) {
    if (cornerRadius <= 0 || sweepAngle <= 0 || innerRadius <= 0) {
      return arcSegmentPath(
        startAngle: startAngle,
        sweepAngle: sweepAngle,
        innerRadius: innerRadius,
        outerRadius: outerRadius,
      );
    }
    final radialWidth = math.max(0, outerRadius - innerRadius);
    final radius = math.min(
      cornerRadius,
      math.min(
        radialWidth * .28,
        math.min(innerRadius, outerRadius) * sweepAngle * .22,
      ),
    );
    if (radius < .1) {
      return arcSegmentPath(
        startAngle: startAngle,
        sweepAngle: sweepAngle,
        innerRadius: innerRadius,
        outerRadius: outerRadius,
      );
    }

    final endAngle = startAngle + sweepAngle;
    final innerInset = math.min(sweepAngle * .24, radius / innerRadius);
    final outerInset = math.min(sweepAngle * .24, radius / outerRadius);
    final outerRect = Rect.fromCircle(center: center, radius: outerRadius);
    final innerRect = Rect.fromCircle(center: center, radius: innerRadius);

    Offset point(double radial, double angle) => polarPoint(radial, angle);
    final path = Path()
      ..moveTo(
        point(innerRadius, startAngle + innerInset).dx,
        point(innerRadius, startAngle + innerInset).dy,
      )
      ..quadraticBezierTo(
        point(innerRadius, startAngle).dx,
        point(innerRadius, startAngle).dy,
        point(innerRadius + radius, startAngle).dx,
        point(innerRadius + radius, startAngle).dy,
      )
      ..lineTo(
        point(outerRadius - radius, startAngle).dx,
        point(outerRadius - radius, startAngle).dy,
      )
      ..quadraticBezierTo(
        point(outerRadius, startAngle).dx,
        point(outerRadius, startAngle).dy,
        point(outerRadius, startAngle + outerInset).dx,
        point(outerRadius, startAngle + outerInset).dy,
      )
      ..arcTo(
        outerRect,
        startAngle + outerInset - math.pi / 2,
        math.max(0, sweepAngle - outerInset * 2),
        false,
      )
      ..quadraticBezierTo(
        point(outerRadius, endAngle).dx,
        point(outerRadius, endAngle).dy,
        point(outerRadius - radius, endAngle).dx,
        point(outerRadius - radius, endAngle).dy,
      )
      ..lineTo(
        point(innerRadius + radius, endAngle).dx,
        point(innerRadius + radius, endAngle).dy,
      )
      ..quadraticBezierTo(
        point(innerRadius, endAngle).dx,
        point(innerRadius, endAngle).dy,
        point(innerRadius, endAngle - innerInset).dx,
        point(innerRadius, endAngle - innerInset).dy,
      )
      ..arcTo(
        innerRect,
        endAngle - innerInset - math.pi / 2,
        -math.max(0.0, sweepAngle - innerInset * 2),
        false,
      )
      ..close();
    return path;
  }

  Path arcSegmentPath({
    required double startAngle,
    required double sweepAngle,
    required double innerRadius,
    required double outerRadius,
  }) {
    final startCanvas = startAngle - math.pi / 2;
    final endCanvas = startCanvas + sweepAngle;
    final outerRect = Rect.fromCircle(center: center, radius: outerRadius);
    final innerRect = Rect.fromCircle(center: center, radius: innerRadius);

    return Path()
      ..moveTo(
        center.dx + math.cos(startCanvas) * innerRadius,
        center.dy + math.sin(startCanvas) * innerRadius,
      )
      ..lineTo(
        center.dx + math.cos(startCanvas) * outerRadius,
        center.dy + math.sin(startCanvas) * outerRadius,
      )
      ..arcTo(outerRect, startCanvas, sweepAngle, false)
      ..lineTo(
        center.dx + math.cos(endCanvas) * innerRadius,
        center.dy + math.sin(endCanvas) * innerRadius,
      )
      ..arcTo(innerRect, endCanvas, -sweepAngle, false)
      ..close();
  }

  bool _isAngleInArc(double angle, double startAngle, double span) {
    if (span <= 0) return false;
    if (span >= _twoPi) return true;
    var relative = angle - startAngle;
    while (relative < 0) {
      relative += _twoPi;
    }
    relative %= _twoPi;
    return relative <= span;
  }
}
