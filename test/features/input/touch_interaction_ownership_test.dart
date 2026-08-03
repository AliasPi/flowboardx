import 'package:flowboard_x/src/features/input/touch_interaction_ownership.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active selection owns the surface against native palm replay', () {
    final gate = TouchInteractionOwnershipGate();
    gate.observeDown(
      pointer: 7,
      globalPosition: const Offset(120, 160),
      timeStamp: const Duration(seconds: 10),
    );
    gate.claimSelection(pointer: 7);

    expect(
      gate.blocksNativeReplay(
        globalPositions: const <Offset>[Offset(132, 169)],
        timeStamps: const <Duration>[Duration(seconds: 10)],
      ),
      isTrue,
    );
  });

  test('active selection does not suppress a spatially separate palm', () {
    final gate = TouchInteractionOwnershipGate();
    gate.observeDown(
      pointer: 8,
      globalPosition: const Offset(120, 160),
      timeStamp: const Duration(seconds: 10),
    );
    gate.claimSelection(pointer: 8);

    expect(
      gate.blocksNativeReplay(
        globalPositions: const <Offset>[Offset(700, 500), Offset(760, 520)],
        timeStamps: const <Duration>[
          Duration(seconds: 10),
          Duration(milliseconds: 10100),
        ],
      ),
      isFalse,
    );
  });

  test('only the owned path, not its large bounding box, blocks replay', () {
    final gate = TouchInteractionOwnershipGate(spatialTolerance: 12);
    gate.observeDown(
      pointer: 9,
      globalPosition: const Offset(100, 100),
      timeStamp: const Duration(seconds: 10),
    );
    gate.claimSelection(pointer: 9);
    gate.observe(
      pointer: 9,
      globalPosition: const Offset(500, 500),
      timeStamp: const Duration(milliseconds: 10100),
    );

    // This point is inside the diagonal trace's axis-aligned bounds but far
    // away from the actual path.
    expect(
      gate.blocksNativeReplay(
        globalPositions: const <Offset>[Offset(450, 120)],
        timeStamps: const <Duration>[Duration(milliseconds: 10050)],
      ),
      isFalse,
    );
  });

  test('delayed native replay is matched to completed selection lifecycle', () {
    var now = DateTime(2026, 8, 3, 12);
    final gate = TouchInteractionOwnershipGate(clock: () => now);
    gate.observeDown(
      pointer: 11,
      globalPosition: const Offset(200, 220),
      timeStamp: const Duration(milliseconds: 1000),
    );
    gate.claimSelection(pointer: 11);
    gate.observe(
      pointer: 11,
      globalPosition: const Offset(320, 250),
      timeStamp: const Duration(milliseconds: 1100),
    );
    gate.complete(
      pointer: 11,
      globalPosition: const Offset(360, 260),
      timeStamp: const Duration(milliseconds: 1200),
    );

    expect(
      gate.blocksNativeReplay(
        globalPositions: const <Offset>[Offset(205, 221), Offset(355, 259)],
        timeStamps: const <Duration>[
          Duration(milliseconds: 1005),
          Duration(milliseconds: 1195),
        ],
      ),
      isTrue,
    );

    // A later real palm at the same place is a distinct interaction.
    expect(
      gate.blocksNativeReplay(
        globalPositions: const <Offset>[Offset(300, 250)],
        timeStamps: const <Duration>[Duration(milliseconds: 4000)],
      ),
      isFalse,
    );

    now = now.add(const Duration(seconds: 6));
    expect(
      gate.blocksNativeReplay(
        globalPositions: const <Offset>[Offset(300, 250)],
      ),
      isFalse,
    );
  });

  test('ordinary unclaimed touch never suppresses a genuine palm', () {
    final gate = TouchInteractionOwnershipGate();
    gate.observeDown(
      pointer: 19,
      globalPosition: const Offset(400, 300),
      timeStamp: const Duration(seconds: 2),
    );
    gate.complete(
      pointer: 19,
      globalPosition: const Offset(460, 300),
      timeStamp: const Duration(milliseconds: 2100),
    );

    expect(
      gate.blocksNativeReplay(
        globalPositions: const <Offset>[Offset(430, 300)],
        timeStamps: const <Duration>[Duration(milliseconds: 2050)],
      ),
      isFalse,
    );
  });
}
