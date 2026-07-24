import 'package:flowboard_x/src/features/board/engine/input_policy.dart';
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

  test('broad palm and inverted stylus erase', () {
    expect(
      classify(
        const PointerDownEvent(kind: PointerDeviceKind.touch, radiusMajor: 30),
      ),
      PointerRole.erase,
    );
    expect(
      classify(const PointerDownEvent(kind: PointerDeviceKind.invertedStylus)),
      PointerRole.erase,
    );
  });

  test('Android fat-touch size and an elongated hand edge erase', () {
    expect(
      classify(
        const PointerDownEvent(
          kind: PointerDeviceKind.touch,
          size: .32,
          radiusMajor: 0,
          radiusMinor: 0,
        ),
      ),
      PointerRole.erase,
    );
    expect(
      classify(
        const PointerDownEvent(
          kind: PointerDeviceKind.touch,
          size: .19,
          radiusMajor: 20,
          radiusMinor: 6,
        ),
      ),
      PointerRole.erase,
    );
  });

  test('Samsung-sized palm threshold stays above a full ordinary finger', () {
    expect(
      classify(
        const PointerDownEvent(
          kind: PointerDeviceKind.touch,
          size: .24,
          radiusMajor: 0,
          radiusMinor: 0,
        ),
      ),
      PointerRole.erase,
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
  });

  test('ordinary fingers do not promote but a strong late palm takes zoom', () {
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
      ),
      isFalse,
    );
    expect(
      policy.shouldPromoteToEraser(
        const PointerMoveEvent(
          kind: PointerDeviceKind.touch,
          size: .31,
          radiusMajor: 26,
          radiusMinor: 10,
        ),
        currentRole: PointerRole.navigate,
        activeNavigationTouches: 2,
      ),
      isTrue,
    );
  });

  test('late broad contact promotes a single touch or ignored palm', () {
    const broadMove = PointerMoveEvent(
      kind: PointerDeviceKind.touch,
      size: .31,
    );
    expect(
      policy.shouldPromoteToEraser(
        broadMove,
        currentRole: PointerRole.navigate,
        activeNavigationTouches: 1,
      ),
      isTrue,
    );
    expect(
      policy.shouldPromoteToEraser(
        broadMove,
        currentRole: PointerRole.ignored,
        activeNavigationTouches: 0,
      ),
      isTrue,
    );
    expect(
      policy.shouldPromoteToEraser(
        broadMove,
        currentRole: PointerRole.select,
        activeNavigationTouches: 0,
      ),
      isTrue,
    );
    expect(policy.eraserRadiusFor(broadMove), greaterThan(30));
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
