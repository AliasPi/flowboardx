import 'dart:math' as math;

import 'package:flowboard_x/src/features/input/eraser_contact_geometry.dart';
import 'package:flowboard_x/src/features/input/touch_contact_classifier.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const classifier = TouchContactClassifier();

  test(
    'size and pressure alone never classify an ordinary finger as broad',
    () {
      const ordinaryFinger = PointerMoveEvent(
        kind: PointerDeviceKind.touch,
        size: 1,
        pressure: 1,
        pressureMin: 0,
        pressureMax: 1,
        radiusMajor: 10,
        radiusMinor: 8,
      );
      const sizeOnlyContact = PointerMoveEvent(
        kind: PointerDeviceKind.touch,
        size: 1,
        pressure: 1,
        pressureMin: 0,
        pressureMax: 1,
      );

      expect(classifier.isBroadTouch(ordinaryFinger), isFalse);
      expect(classifier.isStrongBroadTouch(ordinaryFinger), isFalse);
      expect(classifier.isBroadTouch(sizeOnlyContact), isFalse);
      expect(classifier.isStrongBroadTouch(sizeOnlyContact), isFalse);
      expect(classifier.eraserRadiusFor(sizeOnlyContact), 18);

      const wideFinger = PointerMoveEvent(
        kind: PointerDeviceKind.touch,
        size: 1,
        pressure: 1,
        pressureMin: 0,
        pressureMax: 1,
        radiusMajor: 22,
        radiusMinor: 10,
      );
      expect(classifier.isBroadTouch(wideFinger), isFalse);
      expect(classifier.isStrongBroadTouch(wideFinger), isFalse);
    },
  );

  test(
    'a physically broad palm remains detectable without pressure evidence',
    () {
      const broadPalm = PointerMoveEvent(
        kind: PointerDeviceKind.touch,
        size: .12,
        pressure: 0,
        pressureMin: 0,
        pressureMax: 1,
        radiusMajor: 36,
        radiusMinor: 18,
      );

      expect(classifier.isBroadTouch(broadPalm), isTrue);
      expect(classifier.isStrongBroadTouch(broadPalm), isTrue);
    },
  );

  test('larger physical palm contact produces a larger centred footprint', () {
    const center = Offset(240, 180);
    const compactPalm = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: .34,
      radiusMajor: 22,
      radiusMinor: 13,
    );
    const spreadPalm = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: .6,
      radiusMajor: 44,
      radiusMinor: 24,
      orientation: math.pi / 2,
    );

    double enclosingRadius(PointerEvent event) {
      final footprint = classifier.eraserFootprintFor(event, center: center);
      return EraserContactGeometry.enclosingScreenRadius(
        center: center,
        footprint: footprint,
      );
    }

    expect(classifier.isBroadTouch(compactPalm), isTrue);
    expect(classifier.isBroadTouch(spreadPalm), isTrue);
    expect(
      classifier.eraserRadiusFor(spreadPalm),
      greaterThan(classifier.eraserRadiusFor(compactPalm)),
    );
    expect(
      enclosingRadius(spreadPalm),
      greaterThan(enclosingRadius(compactPalm)),
    );

    final spreadFootprint = classifier.eraserFootprintFor(
      spreadPalm,
      center: center,
    );
    expect(
      spreadFootprint.map((stamp) => stamp.center.dx).reduce(math.min),
      lessThan(center.dx),
    );
    expect(
      spreadFootprint.map((stamp) => stamp.center.dx).reduce(math.max),
      greaterThan(center.dx),
    );
  });

  test('pressure changes do not change identical physical footprints', () {
    const light = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: .4,
      pressure: .1,
      pressureMin: 0,
      pressureMax: 1,
      radiusMajor: 32,
      radiusMinor: 16,
    );
    const firm = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: .4,
      pressure: 1,
      pressureMin: 0,
      pressureMax: 1,
      radiusMajor: 32,
      radiusMinor: 16,
    );

    expect(
      classifier.eraserRadiusFor(firm),
      closeTo(classifier.eraserRadiusFor(light), 1e-9),
    );
  });

  test('pinned size follows shrinking physical axes instead of dominating', () {
    const broad = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: 1,
      pressure: 1,
      pressureMin: 0,
      pressureMax: 1,
      radiusMajor: 48,
      radiusMinor: 22,
    );
    const compact = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: 1,
      pressure: 1,
      pressureMin: 0,
      pressureMax: 1,
      radiusMajor: 30,
      radiusMinor: 14,
    );

    final broadRadius = classifier.eraserRadiusFor(broad);
    final compactRadius = classifier.eraserRadiusFor(compact);
    expect(classifier.isStrongBroadTouch(broad), isTrue);
    expect(classifier.isStrongBroadTouch(compact), isTrue);
    expect(broadRadius, greaterThan(compactRadius + 15));
    expect(compactRadius, lessThan(45));
  });
}
