import 'package:flowboard_x/src/features/board/engine/stroke_sampler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sampler coalesces sub-pixel moves and preserves endpoints', () {
    final sampler = StrokeSampler(minimumDistance: 1)
      ..add(
        const StrokeSample(
          position: Offset.zero,
          timestampMicros: 1,
          pressure: .5,
        ),
      )
      ..add(
        const StrokeSample(
          position: Offset(.2, 0),
          timestampMicros: 2,
          pressure: .7,
        ),
      )
      ..add(
        const StrokeSample(
          position: Offset(2, 0),
          timestampMicros: 3,
          pressure: 1,
        ),
      );

    expect(sampler.samples, hasLength(2));
    expect(sampler.samples.first.position, Offset.zero);
    expect(sampler.smoothedPositions().last, const Offset(2, 0));
  });

  test('slow high-rate movement accumulates from the last accepted anchor', () {
    final sampler = StrokeSampler(minimumDistance: 1)
      ..add(
        const StrokeSample(
          position: Offset.zero,
          timestampMicros: 1,
          pressure: 1,
        ),
      );

    for (var index = 1; index <= 20; index++) {
      sampler.add(
        StrokeSample(
          position: Offset(index / 10, 0),
          timestampMicros: index + 1,
          pressure: 1,
        ),
      );
    }

    expect(sampler.samples.first.position, Offset.zero);
    expect(sampler.samples.last.position, const Offset(2, 0));
    expect(
      sampler.samples.map((sample) => sample.position.dx),
      containsAllInOrder(<double>[0, 1, 2]),
    );
  });

  test('drops invalid positions and sanitizes persisted pointer metadata', () {
    final sampler = StrokeSampler()
      ..add(
        const StrokeSample(
          position: Offset(double.nan, 4),
          timestampMicros: 1,
          pressure: double.nan,
        ),
      )
      ..add(
        const StrokeSample(
          position: Offset(4, 8),
          timestampMicros: 2,
          pressure: double.nan,
          tilt: Offset(double.infinity, double.nan),
        ),
      );

    expect(sampler.samples, hasLength(1));
    expect(sampler.samples.single.position, const Offset(4, 8));
    expect(sampler.samples.single.pressure, 1);
    expect(sampler.samples.single.tilt, Offset.zero);
  });
}
