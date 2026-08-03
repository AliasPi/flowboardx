import 'dart:math' as math;

import 'package:flowboard_x/src/features/input/eraser_contact_geometry.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EraserContactGeometry', () {
    test('contact ellipse remains centred instead of using a corner', () {
      const center = Offset(320, 240);
      final stamps = EraserContactGeometry.touchScreenFootprint(
        center: center,
        radiusMajor: 36,
        radiusMinor: 14,
        orientation: 0,
        fallbackRadius: 30,
      );

      expect(stamps, hasLength(5));
      expect(stamps.map((stamp) => stamp.center.dx), everyElement(center.dx));
      expect(
        stamps.map((stamp) => stamp.center.dy).reduce((a, b) => a + b) /
            stamps.length,
        closeTo(center.dy, 1e-9),
      );
      expect(stamps[2].center, center);
      expect(stamps.first.center.dy, lessThan(center.dy));
      expect(stamps.last.center.dy, greaterThan(center.dy));
    });

    test(
      'orientation rotates the centred footprint around its actual centre',
      () {
        const center = Offset(180, 410);
        final stamps = EraserContactGeometry.touchScreenFootprint(
          center: center,
          radiusMajor: 40,
          radiusMinor: 12,
          orientation: math.pi / 2,
          fallbackRadius: 32,
        );

        expect(
          stamps.map((stamp) => stamp.center.dy),
          everyElement(closeTo(center.dy, 1e-9)),
        );
        expect(
          stamps.map((stamp) => stamp.center.dx).reduce((a, b) => a + b) /
              stamps.length,
          closeTo(center.dx, 1e-9),
        );
        expect(stamps.first.center.dx, lessThan(center.dx));
        expect(stamps.last.center.dx, greaterThan(center.dx));
      },
    );

    test('dynamic size fallback expands one calibrated axis symmetrically', () {
      const center = Offset(75, 90);
      final stamps = EraserContactGeometry.touchScreenFootprint(
        center: center,
        radiusMajor: 28,
        radiusMinor: 0,
        orientation: -.8,
        fallbackRadius: 42,
      );

      expect(stamps, hasLength(1));
      expect(stamps.single.center, center);
      expect(stamps.single.radius, 42);
    });

    test(
      'larger contact fallback expands both ellipse axes proportionally',
      () {
        const center = Offset(180, 220);
        final compact = EraserContactGeometry.touchScreenFootprint(
          center: center,
          radiusMajor: 30,
          radiusMinor: 12,
          orientation: 0,
          fallbackRadius: 24,
        );
        final broad = EraserContactGeometry.touchScreenFootprint(
          center: center,
          radiusMajor: 30,
          radiusMinor: 12,
          orientation: 0,
          fallbackRadius: 60,
        );

        final compactRadius = EraserContactGeometry.enclosingScreenRadius(
          center: center,
          footprint: compact,
        );
        final broadRadius = EraserContactGeometry.enclosingScreenRadius(
          center: center,
          footprint: broad,
        );
        expect(broadRadius, greaterThan(compactRadius * 1.8));
        expect(broad.map((stamp) => stamp.center.dx), everyElement(center.dx));
        expect(
          broad.map((stamp) => stamp.center.dy).reduce((a, b) => a + b) /
              broad.length,
          closeTo(center.dy, 1e-9),
        );
      },
    );

    test('cursor radius contains the exact footprint used for erasing', () {
      const center = Offset(240, 180);
      final stamps = EraserContactGeometry.touchScreenFootprint(
        center: center,
        radiusMajor: 36,
        radiusMinor: 14,
        orientation: 0,
        fallbackRadius: 30,
      );
      final cursorRadius = EraserContactGeometry.enclosingScreenRadius(
        center: center,
        footprint: stamps,
      );

      final furthestErasedPoint = stamps
          .map((stamp) => (stamp.center - center).distance + stamp.radius)
          .reduce(math.max);
      expect(cursorRadius, closeTo(furthestErasedPoint, 1e-9));
      expect(
        stamps,
        everyElement(
          predicate<EraserBrushStamp>(
            (stamp) =>
                (stamp.center - center).distance + stamp.radius <= cursorRadius,
          ),
        ),
      );
    });

    test('legacy logical-width conversion remains deterministic', () {
      expect(EraserContactGeometry.stylusWorldRadius(2), 1);
      expect(EraserContactGeometry.stylusWorldRadius(32), 16);
      expect(
        EraserContactGeometry.cursorScreenRadius(
          logicalWidth: 2,
          viewportScale: .5,
        ),
        .5,
      );
      expect(
        EraserContactGeometry.cursorScreenRadius(
          logicalWidth: 32,
          viewportScale: 2,
        ),
        32,
      );
    });

    test(
      'explicit eraser size comes from live tool contact, not pen width',
      () {
        const narrow = PointerDownEvent(
          kind: PointerDeviceKind.stylus,
          pressure: .2,
          pressureMin: 0,
          pressureMax: 1,
        );
        const broadHardwareEraser = PointerDownEvent(
          kind: PointerDeviceKind.invertedStylus,
          radiusMajor: 32,
          radiusMinor: 18,
          size: .7,
          pressure: .7,
          pressureMin: 0,
          pressureMax: 1,
        );

        final narrowRadius = EraserContactGeometry.automaticToolScreenRadius(
          narrow,
        );
        final broadRadius = EraserContactGeometry.automaticToolScreenRadius(
          broadHardwareEraser,
        );

        expect(narrowRadius, inInclusiveRange(16, 25));
        expect(broadRadius, greaterThan(narrowRadius));
        expect(
          broadRadius,
          lessThanOrEqualTo(
            EraserContactGeometry.maximumAutomaticToolScreenRadius,
          ),
        );
      },
    );

    test(
      'recognized fist grows and can shrink without retaining peak forever',
      () {
        final compact = EraserContactGeometry.recognizedFistScreenRadius(
          measuredRadius: 24,
          normalizedSize: .34,
          normalizedPressure: .2,
        );
        final broad = EraserContactGeometry.recognizedFistScreenRadius(
          measuredRadius: 24,
          normalizedSize: .9,
          normalizedPressure: .8,
          contactCount: 4,
          clusterEnvelopeRadius: 82,
        );
        final attacked = EraserContactGeometry.smoothRecognizedScreenRadius(
          previousRadius: compact,
          targetRadius: broad,
          elapsed: const Duration(milliseconds: 16),
        );
        final released = EraserContactGeometry.smoothRecognizedScreenRadius(
          previousRadius: attacked,
          targetRadius: compact,
          elapsed: const Duration(milliseconds: 120),
        );

        expect(
          compact,
          EraserContactGeometry.minimumRecognizedFistScreenRadius,
        );
        expect(broad, greaterThan(compact + 40));
        expect(attacked, inExclusiveRange(compact, broad));
        expect(released, inExclusiveRange(compact, attacked));
      },
    );

    test(
      'recognized fist target uses the current contact instead of its peak',
      () {
        final broad = EraserContactGeometry.recognizedFistScreenRadius(
          measuredRadius: 68,
          normalizedSize: .92,
          normalizedPressure: .8,
          contactCount: 4,
          clusterEnvelopeRadius: 88,
        );
        final compact = EraserContactGeometry.recognizedFistScreenRadius(
          measuredRadius: 22,
          normalizedSize: .34,
          normalizedPressure: .2,
          contactCount: 1,
          clusterEnvelopeRadius: 0,
        );

        expect(broad, greaterThan(115));
        expect(
          compact,
          EraserContactGeometry.minimumRecognizedFistScreenRadius,
        );
        expect(compact, lessThan(broad * .45));
      },
    );

    test('pinned size cannot override shrinking physical touch axes', () {
      final broad = EraserContactGeometry.recognizedFistScreenRadius(
        measuredRadius: 72,
        normalizedSize: 1,
        normalizedPressure: 1,
      );
      final compact = EraserContactGeometry.recognizedFistScreenRadius(
        measuredRadius: 24,
        normalizedSize: 1,
        normalizedPressure: 1,
      );

      expect(broad, greaterThan(90));
      expect(compact, lessThan(60));
      expect(compact, lessThan(broad * .65));
    });

    test('size remains a bounded fallback when physical axes are absent', () {
      final compact = EraserContactGeometry.recognizedFistScreenRadius(
        measuredRadius: 0,
        normalizedSize: .34,
        normalizedPressure: 0,
      );
      final broad = EraserContactGeometry.recognizedFistScreenRadius(
        measuredRadius: 0,
        normalizedSize: 1,
        normalizedPressure: 0,
      );

      expect(compact, EraserContactGeometry.minimumRecognizedFistScreenRadius);
      expect(broad, greaterThan(compact + 70));
      expect(
        broad,
        lessThanOrEqualTo(
          EraserContactGeometry.maximumRecognizedFistScreenRadius,
        ),
      );
    });

    test(
      'release follows a smaller live area within a short wipe interval',
      () {
        final compact = EraserContactGeometry.recognizedFistScreenRadius(
          measuredRadius: 24,
          normalizedSize: .34,
          normalizedPressure: .2,
        );
        var filtered = EraserContactGeometry.recognizedFistScreenRadius(
          measuredRadius: 72,
          normalizedSize: .95,
          normalizedPressure: .85,
          clusterEnvelopeRadius: 92,
        );
        final peak = filtered;

        for (var frame = 0; frame < 12; frame++) {
          filtered = EraserContactGeometry.smoothRecognizedScreenRadius(
            previousRadius: filtered,
            targetRadius: compact,
            elapsed: const Duration(milliseconds: 16),
          );
        }

        expect(filtered, lessThan(peak * .55));
        expect(filtered, greaterThanOrEqualTo(compact));
        expect(filtered, closeTo(compact, 5));
      },
    );

    test(
      'attack is faster than release without overshooting either target',
      () {
        const elapsed = Duration(milliseconds: 16);
        final minimum = EraserContactGeometry.minimumRecognizedFistScreenRadius;
        const maximum = 120.0;
        final attacked = EraserContactGeometry.smoothRecognizedScreenRadius(
          previousRadius: minimum,
          targetRadius: maximum,
          elapsed: elapsed,
        );
        final released = EraserContactGeometry.smoothRecognizedScreenRadius(
          previousRadius: maximum,
          targetRadius: minimum,
          elapsed: elapsed,
        );
        final attackProgress = (attacked - minimum) / (maximum - minimum);
        final releaseProgress = (maximum - released) / (maximum - minimum);

        expect(attacked, inExclusiveRange(minimum, maximum));
        expect(released, inExclusiveRange(minimum, maximum));
        expect(attackProgress, greaterThan(releaseProgress * 2));
      },
    );

    test('small quantized jitter stays inside the adaptive dead zone', () {
      final stable = EraserContactGeometry.smoothRecognizedScreenRadius(
        previousRadius: 100,
        targetRadius: 101.5,
        elapsed: const Duration(milliseconds: 16),
      );

      expect(stable, 100);
    });

    test('contact count alone does not create a permanently huge eraser', () {
      final oneContact = EraserContactGeometry.recognizedFistScreenRadius(
        measuredRadius: 0,
        normalizedSize: 0,
        normalizedPressure: 1,
      );
      final splitContact = EraserContactGeometry.recognizedFistScreenRadius(
        measuredRadius: 0,
        normalizedSize: 0,
        normalizedPressure: 1,
        contactCount: 5,
      );

      expect(splitContact - oneContact, lessThanOrEqualTo(6));
      expect(splitContact, lessThan(55));
    });

    test('malformed smoothing inputs remain finite and board-bounded', () {
      final fromInvalidPrevious =
          EraserContactGeometry.smoothRecognizedScreenRadius(
            previousRadius: double.nan,
            targetRadius: 88,
            elapsed: const Duration(milliseconds: 16),
          );
      final fromInvalidTarget =
          EraserContactGeometry.smoothRecognizedScreenRadius(
            previousRadius: double.infinity,
            targetRadius: double.nan,
            elapsed: Duration.zero,
          );

      expect(fromInvalidPrevious, 88);
      expect(
        fromInvalidTarget,
        EraserContactGeometry.minimumRecognizedFistScreenRadius,
      );
      expect(fromInvalidPrevious.isFinite, isTrue);
      expect(fromInvalidTarget.isFinite, isTrue);
    });
  });
}
