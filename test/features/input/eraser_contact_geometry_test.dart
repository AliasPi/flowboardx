import 'dart:math' as math;

import 'package:flowboard_x/src/features/input/eraser_contact_geometry.dart';
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

    test('single calibrated axis safely stays centred and circular', () {
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
      expect(stamps.single.radius, 28);
    });

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

    test('cursor and stylus eraser use the same logical thickness', () {
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
  });
}
