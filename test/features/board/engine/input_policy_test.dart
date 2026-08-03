import 'dart:math' as math;

import 'package:flowboard_x/src/features/board/engine/input_policy.dart';
import 'package:flowboard_x/src/features/input/eraser_contact_geometry.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = PointerPolicy();

  PointerRole classify(
    PointerDownEvent event, {
    BoardTool tool = BoardTool.pen,
    bool penActive = false,
    bool selectionActive = false,
    bool fingerDrawingEnabled = false,
    int navigationTouches = 0,
  }) => policy.classifyDown(
    event,
    tool: tool,
    selectionActive: selectionActive,
    stylusCurrentlyActive: penActive,
    activeNavigationTouches: navigationTouches,
    fingerDrawingEnabled: fingerDrawingEnabled,
  );

  test('normal full-pressure Android finger remains navigation', () {
    expect(
      classify(
        const PointerDownEvent(
          kind: PointerDeviceKind.touch,
          pressure: 1,
          pressureMin: 0,
          pressureMax: 1,
          radiusMajor: 4,
        ),
      ),
      PointerRole.navigate,
    );
  });

  test('broad single touch navigates while inverted stylus erases', () {
    expect(
      classify(
        const PointerDownEvent(
          kind: PointerDeviceKind.touch,
          radiusMajor: 36,
          radiusMinor: 18,
        ),
      ),
      PointerRole.navigate,
    );
    expect(
      classify(const PointerDownEvent(kind: PointerDeviceKind.invertedStylus)),
      PointerRole.erase,
    );
  });

  test('size and elongated single-touch axes are never destructive', () {
    expect(
      classify(
        const PointerDownEvent(
          kind: PointerDeviceKind.touch,
          size: .32,
          radiusMajor: 0,
          radiusMinor: 0,
        ),
      ),
      PointerRole.navigate,
    );
    expect(
      classify(
        const PointerDownEvent(
          kind: PointerDeviceKind.touch,
          size: .19,
          radiusMajor: 30,
          radiusMinor: 8,
        ),
      ),
      PointerRole.navigate,
    );
  });

  test(
    'normalized size and ordinary finger ellipses remain non-destructive',
    () {
      expect(
        classify(
          const PointerDownEvent(
            kind: PointerDeviceKind.touch,
            size: .24,
            radiusMajor: 0,
            radiusMinor: 0,
          ),
        ),
        PointerRole.navigate,
      );
      expect(
        classify(
          const PointerDownEvent(
            kind: PointerDeviceKind.touch,
            size: 1,
            pressure: 1,
            pressureMin: 0,
            pressureMax: 1,
            radiusMajor: 22,
            radiusMinor: 10,
          ),
        ),
        PointerRole.navigate,
      );
      expect(
        classify(
          const PointerDownEvent(
            kind: PointerDeviceKind.touch,
            size: .22,
            radiusMajor: 10,
            radiusMinor: 8,
          ),
        ),
        PointerRole.navigate,
      );
      expect(
        classify(
          const PointerDownEvent(
            kind: PointerDeviceKind.touch,
            size: .20,
            radiusMajor: 19,
            radiusMinor: 3,
          ),
        ),
        PointerRole.navigate,
      );
    },
  );

  test(
    'one and two ordinary fingers preserve navigation and selection roles',
    () {
      const finger = PointerDownEvent(
        kind: PointerDeviceKind.touch,
        size: 1,
        pressure: 1,
        pressureMin: 0,
        pressureMax: 1,
        radiusMajor: 10,
        radiusMinor: 8,
      );
      expect(classify(finger), PointerRole.navigate);
      expect(classify(finger, navigationTouches: 1), PointerRole.navigate);
      expect(
        classify(finger, tool: BoardTool.selectRectangle),
        PointerRole.select,
      );
      expect(classify(finger, selectionActive: true), PointerRole.select);
    },
  );

  test('ordinary fingers and established two-finger zoom never promote', () {
    const finger = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      pressure: 1,
      pressureMin: 0,
      pressureMax: 1,
      size: .18,
      radiusMajor: 10,
      radiusMinor: 8,
    );
    expect(
      policy.shouldPromoteToEraser(
        finger,
        currentRole: PointerRole.navigate,
        activeNavigationTouches: 1,
        stylusCurrentlyActive: false,
      ),
      isFalse,
    );
    expect(
      policy.shouldPromoteToEraser(
        const PointerMoveEvent(
          kind: PointerDeviceKind.touch,
          size: .29,
          radiusMajor: 20,
          radiusMinor: 8,
        ),
        currentRole: PointerRole.navigate,
        activeNavigationTouches: 2,
        stylusCurrentlyActive: false,
      ),
      isFalse,
    );
    expect(
      policy.shouldPromoteToEraser(
        const PointerMoveEvent(
          kind: PointerDeviceKind.touch,
          size: .45,
          radiusMajor: 32,
          radiusMinor: 16,
        ),
        currentRole: PointerRole.navigate,
        activeNavigationTouches: 2,
        stylusCurrentlyActive: false,
      ),
      isFalse,
    );
  });

  test('late size and pressure spikes never promote ordinary fingers', () {
    const ordinaryMove = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: 1,
      pressure: 1,
      pressureMin: 0,
      pressureMax: 1,
      radiusMajor: 10,
      radiusMinor: 8,
    );
    const wideFingerMove = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: 1,
      pressure: 1,
      pressureMin: 0,
      pressureMax: 1,
      radiusMajor: 22,
      radiusMinor: 10,
    );
    for (final contact in <PointerMoveEvent>[ordinaryMove, wideFingerMove]) {
      for (final role in <PointerRole>[
        PointerRole.navigate,
        PointerRole.select,
        PointerRole.ignored,
      ]) {
        expect(
          policy.shouldPromoteToEraser(
            contact,
            currentRole: role,
            activeNavigationTouches: role == PointerRole.navigate ? 2 : 0,
            stylusCurrentlyActive: false,
          ),
          isFalse,
        );
      }
    }
  });

  test('late physically broad metadata never promotes a single touch', () {
    const broadMove = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: .45,
      radiusMajor: 32,
      radiusMinor: 16,
    );
    expect(
      policy.shouldPromoteToEraser(
        broadMove,
        currentRole: PointerRole.navigate,
        activeNavigationTouches: 1,
        stylusCurrentlyActive: false,
      ),
      isFalse,
    );
    expect(
      policy.shouldPromoteToEraser(
        broadMove,
        currentRole: PointerRole.ignored,
        activeNavigationTouches: 0,
        stylusCurrentlyActive: false,
      ),
      isFalse,
    );
    expect(
      policy.shouldPromoteToEraser(
        broadMove,
        currentRole: PointerRole.select,
        activeNavigationTouches: 0,
        stylusCurrentlyActive: false,
      ),
      isFalse,
    );
    expect(policy.eraserRadiusFor(broadMove), greaterThan(30));
  });

  test('normalized size only refines a calibrated contact within bounds', () {
    const center = Offset(200, 180);
    const compact = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: .24,
      radiusMajor: 26,
      radiusMinor: 12,
      pressure: .2,
      pressureMin: 0,
      pressureMax: 1,
    );
    const broad = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: .72,
      radiusMajor: 26,
      radiusMinor: 12,
      pressure: .2,
      pressureMin: 0,
      pressureMax: 1,
    );
    final compactFootprint = policy.eraserFootprintFor(compact, center: center);
    final broadFootprint = policy.eraserFootprintFor(broad, center: center);
    double enclosingRadius(Iterable<EraserBrushStamp> footprint) => footprint
        .map((stamp) => (stamp.center - center).distance + stamp.radius)
        .reduce(math.max);

    expect(
      policy.eraserRadiusFor(broad),
      greaterThan(policy.eraserRadiusFor(compact)),
    );
    final compactRadius = enclosingRadius(compactFootprint);
    final broadRadius = enclosingRadius(broadFootprint);
    expect(broadRadius, greaterThan(compactRadius));
    expect(broadRadius, lessThan(compactRadius + 8));
  });

  test('pressure does not alter the same physical eraser footprint', () {
    const center = Offset(120, 90);
    const light = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: .30,
      radiusMajor: 32,
      radiusMinor: 16,
      pressure: .2,
      pressureMin: 0,
      pressureMax: 1,
    );
    const firm = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: .30,
      radiusMajor: 32,
      radiusMinor: 16,
      pressure: 1,
      pressureMin: 0,
      pressureMax: 1,
    );
    double enclosingRadius(PointerEvent event) => policy
        .eraserFootprintFor(event, center: center)
        .map((stamp) => (stamp.center - center).distance + stamp.radius)
        .reduce(math.max);

    expect(
      policy.eraserRadiusFor(firm),
      closeTo(policy.eraserRadiusFor(light), 1e-9),
    );
    expect(enclosingRadius(firm), closeTo(enclosingRadius(light), 1e-9));
  });

  test('small resting touch is ignored while a stylus writes', () {
    expect(
      classify(
        const PointerDownEvent(kind: PointerDeviceKind.touch, radiusMajor: 5),
        penActive: true,
      ),
      PointerRole.ignored,
    );
  });

  test('broad resting palm is ignored while a stylus writes', () {
    const broadPalm = PointerDownEvent(
      kind: PointerDeviceKind.touch,
      size: .34,
      radiusMajor: 32,
      radiusMinor: 18,
    );
    expect(classify(broadPalm, penActive: true), PointerRole.ignored);
    expect(
      policy.shouldPromoteToEraser(
        const PointerMoveEvent(
          kind: PointerDeviceKind.touch,
          size: .34,
          radiusMajor: 32,
          radiusMinor: 18,
        ),
        currentRole: PointerRole.ignored,
        activeNavigationTouches: 0,
        stylusCurrentlyActive: true,
      ),
      isFalse,
    );
    expect(
      classify(
        const PointerDownEvent(kind: PointerDeviceKind.invertedStylus),
        penActive: true,
      ),
      PointerRole.erase,
    );
  });

  test('stylus follows active ink or selection tool', () {
    const stylus = PointerDownEvent(kind: PointerDeviceKind.stylus);
    expect(classify(stylus), PointerRole.ink);
    expect(classify(stylus, tool: BoardTool.selectLasso), PointerRole.select);
    expect(classify(stylus, tool: BoardTool.eraser), PointerRole.erase);
  });

  test('finger drawing is opt-in and yields to multi-touch navigation', () {
    const finger = PointerDownEvent(
      kind: PointerDeviceKind.touch,
      radiusMajor: 5,
    );
    expect(classify(finger), PointerRole.navigate);
    expect(classify(finger, fingerDrawingEnabled: true), PointerRole.ink);
    expect(
      classify(finger, fingerDrawingEnabled: true, navigationTouches: 1),
      PointerRole.navigate,
    );
    expect(
      classify(
        finger,
        tool: BoardTool.selectRectangle,
        fingerDrawingEnabled: true,
      ),
      PointerRole.select,
    );
  });
}
