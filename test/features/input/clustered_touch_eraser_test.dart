import 'package:flowboard_x/src/features/input/clustered_touch_eraser.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PointerDownEvent down(
    int pointer,
    Offset position,
    int milliseconds, {
    double radiusMajor = 7,
    double radiusMinor = 5,
  }) => PointerDownEvent(
    pointer: pointer,
    device: pointer,
    kind: PointerDeviceKind.touch,
    position: position,
    timeStamp: Duration(milliseconds: milliseconds),
    radiusMajor: radiusMajor,
    radiusMinor: radiusMinor,
    size: .1,
  );

  PointerMoveEvent move(
    int pointer,
    Offset position,
    int milliseconds, {
    double radiusMajor = 7,
    double radiusMinor = 5,
  }) => PointerMoveEvent(
    pointer: pointer,
    device: pointer,
    kind: PointerDeviceKind.touch,
    position: position,
    timeStamp: Duration(milliseconds: milliseconds),
    buttons: kPrimaryButton,
    radiusMajor: radiusMajor,
    radiusMinor: radiusMinor,
    size: .1,
  );

  test('two close fingers never become a clustered eraser', () {
    final tracker = ClusteredTouchEraserTracker();
    tracker
      ..add(down(1, const Offset(100, 100), 0), const Offset(100, 100))
      ..add(down(2, const Offset(140, 110), 12), const Offset(140, 110));

    expect(
      tracker.update(
        move(1, const Offset(140, 125), 40),
        const Offset(140, 125),
      ),
      isNull,
    );
    expect(
      tracker.update(
        move(2, const Offset(180, 135), 48),
        const Offset(180, 135),
      ),
      isNull,
    );
  });

  test('compact coherent three-contact movement is a fist fallback', () {
    final tracker = ClusteredTouchEraserTracker();
    tracker
      ..add(down(1, const Offset(200, 200), 0), const Offset(200, 200))
      ..add(down(2, const Offset(228, 212), 14), const Offset(228, 212))
      ..add(down(3, const Offset(252, 196), 27), const Offset(252, 196));

    expect(
      tracker.update(
        move(1, const Offset(220, 210), 50),
        const Offset(220, 210),
      ),
      isNull,
    );
    final match = tracker.update(
      move(2, const Offset(248, 222), 58),
      const Offset(248, 222),
    );

    expect(match, isNotNull);
    expect(match!.positions.keys, unorderedEquals(<int>[1, 2, 3]));
    expect(match.center.dx, closeTo(240, 1e-9));
    expect(match.center.dy, closeTo(209.33333333333334, 1e-9));
    expect(match.brushRadius, inInclusiveRange(44, 60));
  });

  test('larger current cluster envelope produces a broader fist brush', () {
    final compactTracker = ClusteredTouchEraserTracker();
    compactTracker
      ..add(down(1, const Offset(200, 200), 0), const Offset(200, 200))
      ..add(down(2, const Offset(228, 212), 14), const Offset(228, 212))
      ..add(down(3, const Offset(252, 196), 27), const Offset(252, 196));
    compactTracker.update(
      move(1, const Offset(220, 210), 50),
      const Offset(220, 210),
    );
    final compact = compactTracker.update(
      move(2, const Offset(248, 222), 58),
      const Offset(248, 222),
    )!;

    final broadTracker = ClusteredTouchEraserTracker();
    broadTracker
      ..add(
        down(11, const Offset(200, 200), 0, radiusMajor: 20, radiusMinor: 14),
        const Offset(200, 200),
      )
      ..add(
        down(12, const Offset(250, 210), 14, radiusMajor: 20, radiusMinor: 14),
        const Offset(250, 210),
      )
      ..add(
        down(13, const Offset(285, 195), 27, radiusMajor: 20, radiusMinor: 14),
        const Offset(285, 195),
      );
    broadTracker.update(
      move(11, const Offset(220, 210), 50, radiusMajor: 20, radiusMinor: 14),
      const Offset(220, 210),
    );
    final broad = broadTracker.update(
      move(12, const Offset(270, 220), 58, radiusMajor: 20, radiusMinor: 14),
      const Offset(270, 220),
    )!;

    expect(broad.brushRadius, greaterThan(compact.brushRadius + 20));
    expect(broad.brushRadius, lessThanOrEqualTo(100));
  });

  test('distributed five-finger wheel contacts are never a fist cluster', () {
    final tracker = ClusteredTouchEraserTracker();
    final positions = <Offset>[
      const Offset(400, 150),
      const Offset(540, 250),
      const Offset(490, 420),
      const Offset(310, 420),
      const Offset(260, 250),
    ];
    for (var index = 0; index < positions.length; index++) {
      tracker.add(
        down(index + 1, positions[index], index * 8),
        positions[index],
      );
    }

    for (var index = 0; index < positions.length; index++) {
      final moved = positions[index] + const Offset(18, 10);
      expect(
        tracker.update(move(index + 1, moved, 80 + index * 8), moved),
        isNull,
      );
    }
  });

  test('compact but divergent pinch movement is rejected', () {
    final tracker = ClusteredTouchEraserTracker();
    tracker
      ..add(down(1, const Offset(300, 300), 0), const Offset(300, 300))
      ..add(down(2, const Offset(340, 300), 10), const Offset(340, 300))
      ..add(down(3, const Offset(320, 335), 20), const Offset(320, 335));

    expect(
      tracker.update(
        move(1, const Offset(286, 300), 50),
        const Offset(286, 300),
      ),
      isNull,
    );
    expect(
      tracker.update(
        move(2, const Offset(354, 300), 58),
        const Offset(354, 300),
      ),
      isNull,
    );
  });

  test('contacts beginning too far apart in time are rejected', () {
    final tracker = ClusteredTouchEraserTracker();
    tracker
      ..add(down(1, const Offset(200, 200), 0), const Offset(200, 200))
      ..add(down(2, const Offset(225, 210), 20), const Offset(225, 210))
      ..add(down(3, const Offset(250, 200), 260), const Offset(250, 200));

    tracker.update(
      move(1, const Offset(220, 210), 300),
      const Offset(220, 210),
    );
    expect(
      tracker.update(
        move(2, const Offset(245, 220), 310),
        const Offset(245, 220),
      ),
      isNull,
    );
  });
}
