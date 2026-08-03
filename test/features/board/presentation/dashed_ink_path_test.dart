import 'dart:ui';

import 'package:flowboard_x/src/features/board/presentation/dashed_ink_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DashedInkPathBuilder', () {
    test('keeps one continuous pattern across short source segments', () {
      final result = DashedInkPathBuilder.build(
        points: const <Offset>[
          Offset.zero,
          Offset(1, 0),
          Offset(2, 0),
          Offset(4.999999999, 0),
          Offset(5, 0),
          Offset(5, 0),
          Offset(8, 0),
          Offset(13, 0),
        ],
        dashLength: 5,
        gapLength: 3,
      );

      expect(result.commandCount, greaterThan(0));
      expect(result.wasTruncated, isFalse);
      expect(result.path.getBounds(), const Rect.fromLTRB(0, 0, 13, 0));
    });

    test('builds directly from primitive coordinate models', () {
      const points = <({double x, double y})>[
        (x: 0, y: 0),
        (x: 4, y: 0),
        (x: 8, y: 0),
        (x: 13, y: 0),
      ];
      final result = DashedInkPathBuilder.buildMapped(
        points: points,
        xOf: (point) => point.x,
        yOf: (point) => point.y,
        dashLength: 5,
        gapLength: 3,
      );

      expect(result.commandCount, greaterThan(0));
      expect(result.wasTruncated, isFalse);
      expect(result.path.getBounds(), const Rect.fromLTRB(0, 0, 13, 0));
    });

    test('breaks safely around non-finite and extreme recovered points', () {
      final result = DashedInkPathBuilder.build(
        points: const <Offset>[
          Offset.zero,
          Offset(double.nan, 2),
          Offset(1, 4),
          Offset(6, 4),
          Offset(double.infinity, 4),
          Offset(20000000, 4),
          Offset(10, 8),
          Offset(14, 8),
        ],
        dashLength: 5,
        gapLength: 3,
      );

      expect(result.commandCount, 2);
      expect(result.wasTruncated, isFalse);
      expect(result.path.getBounds().left, 1);
      expect(result.path.getBounds().right, 14);
    });

    test('bounds pathological dash work instead of hanging raster thread', () {
      final stopwatch = Stopwatch()..start();
      final result = DashedInkPathBuilder.build(
        points: const <Offset>[Offset.zero, Offset(9999999, 0)],
        dashLength: 5,
        gapLength: 3,
      );
      stopwatch.stop();

      expect(result.commandCount, DashedInkPathBuilder.maxPathCommands);
      expect(result.wasTruncated, isTrue);
      // This is deliberately generous for slower CI machines.  The old loop
      // performed more than a million draw calls and produced an AppHangB1.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('rejects invalid patterns without entering a loop', () {
      for (final pattern in <(double, double)>[
        (0, 3),
        (5, 0),
        (double.nan, 3),
        (5, double.infinity),
      ]) {
        final result = DashedInkPathBuilder.build(
          points: const <Offset>[Offset.zero, Offset(100, 0)],
          dashLength: pattern.$1,
          gapLength: pattern.$2,
        );
        expect(result.commandCount, 0);
        expect(result.wasTruncated, isFalse);
      }
    });
  });
}
