import 'dart:math' as math;

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
          pressure: .5,
        ),
      )
      ..add(
        const StrokeSample(
          position: Offset(2, 0),
          timestampMicros: 3,
          pressure: .5,
        ),
      );

    expect(sampler.samples, hasLength(2));
    expect(sampler.samples.first.position, Offset.zero);
    expect(sampler.smoothedPositions().last, const Offset(2, 0));
  });

  test(
    'slow high-rate movement preserves endpoints without dense collinear data',
    () {
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
      expect(sampler.samples.length, lessThanOrEqualTo(3));
    },
  );

  test('adaptively bounds a high-rate line independent of packet count', () {
    final sampler = StrokeSampler(minimumDistance: .2)
      ..add(
        const StrokeSample(
          position: Offset.zero,
          timestampMicros: 1,
          pressure: 1,
        ),
      );

    for (var index = 1; index <= 5000; index++) {
      sampler.add(
        StrokeSample(
          position: Offset(index / 10, 0),
          timestampMicros: index + 1,
          pressure: 1,
        ),
      );
    }

    expect(sampler.samples.first.position, Offset.zero);
    expect(sampler.samples.last.position, const Offset(500, 0));
    expect(
      sampler.samples.length,
      lessThan(150),
      reason: '240 Hz packets must not become 240 Hz persisted geometry',
    );
  });

  test('keeps circular interpolation below a sub-pixel screen error', () {
    const radius = 80.0;
    const sampleCount = 1440;
    final sampler = StrokeSampler(minimumDistance: .1);
    for (var index = 0; index <= sampleCount; index++) {
      final angle = index / sampleCount * math.pi * 2;
      sampler.add(
        StrokeSample(
          position: Offset(math.cos(angle) * radius, math.sin(angle) * radius),
          timestampMicros: index + 1,
          pressure: 1,
        ),
      );
    }

    expect(sampler.samples.length, lessThan(180));
    var maximumSagitta = 0.0;
    for (var index = 1; index < sampler.samples.length; index++) {
      final midpoint =
          (sampler.samples[index - 1].position +
              sampler.samples[index].position) /
          2;
      maximumSagitta = math.max(
        maximumSagitta,
        (radius - midpoint.distance).abs(),
      );
    }
    expect(maximumSagitta, lessThan(.4));
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
