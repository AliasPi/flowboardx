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
  }) => policy.classifyDown(
    event,
    tool: tool,
    selectionActive: selectionActive,
    stylusCurrentlyActive: penActive,
    activeNavigationTouches: 0,
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
  });
}
