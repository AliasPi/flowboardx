import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/presentation/ink_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adaptively smooths circular ink with one bounded command per edge', () {
    const radius = 80.0;
    final points = List<InkPoint>.generate(181, (index) {
      final angle = index * math.pi * 2 / 180;
      return InkPoint(x: math.cos(angle) * radius, y: math.sin(angle) * radius);
    }, growable: false);

    final commands = InkPainter.debugAdaptiveCommandCounts(points);
    expect(commands.curves, greaterThan(170));
    expect(commands.curves + commands.lines, points.length - 1);

    final path = InkPainter.debugAdaptiveCenterline(points);
    final length = path.computeMetrics().single.length;
    expect(length, closeTo(2 * math.pi * radius, 2));
    expect(path.getBounds(), const Rect.fromLTWH(-80, -80, 160, 160));
  });

  test('preserves deliberate corners instead of rounding them', () {
    const points = <InkPoint>[
      InkPoint(x: 0, y: 0),
      InkPoint(x: 10, y: 0),
      InkPoint(x: 10, y: 10),
      InkPoint(x: 20, y: 10),
    ];

    final commands = InkPainter.debugAdaptiveCommandCounts(points);
    expect(commands, (curves: 0, lines: 3));
    expect(
      InkPainter.debugAdaptiveCenterline(points).computeMetrics().single.length,
      30,
    );
  });

  test('keeps a deliberate sixty-degree turn exact', () {
    final points = <InkPoint>[
      const InkPoint(x: 0, y: 0),
      const InkPoint(x: 10, y: 0),
      InkPoint(x: 15, y: math.sqrt(75)),
    ];

    expect(InkPainter.debugAdaptiveCommandCounts(points), (
      curves: 0,
      lines: 2,
    ));
  });

  test('keeps long straight ink on the cheaper linear path', () {
    final points = List<InkPoint>.generate(
      10000,
      (index) => InkPoint(x: index / 4, y: 12),
      growable: false,
    );

    final commands = InkPainter.debugAdaptiveCommandCounts(points);
    expect(commands.curves, 0);
    expect(commands.lines, points.length - 1);
  });

  test('keeps a constant-pressure circular stroke in one contour', () {
    final points = List<InkPoint>.generate(512, (index) {
      final angle = index * math.pi * 2 / 511;
      return InkPoint(
        x: 240 + math.cos(angle) * 160,
        y: 220 + math.sin(angle) * 160,
        pressure: .62,
      );
    }, growable: false);

    expect(InkPainter.debugNormalPressureContourCount(points), 1);
  });

  test('pressure hysteresis absorbs one-bucket sensor noise', () {
    const points = <InkPoint>[
      InkPoint(x: 0, y: 0, pressure: .45),
      InkPoint(x: 10, y: 0, pressure: .45),
      InkPoint(x: 20, y: 1, pressure: .55),
      InkPoint(x: 30, y: 2, pressure: .55),
    ];

    expect(InkPainter.debugNormalPressureContourCount(points), 1);
  });

  test('material pressure changes still create separate width runs', () {
    const points = <InkPoint>[
      InkPoint(x: 0, y: 0, pressure: 0),
      InkPoint(x: 10, y: 0, pressure: 0),
      InkPoint(x: 20, y: 0, pressure: 1),
      InkPoint(x: 30, y: 0, pressure: 1),
    ];

    expect(InkPainter.debugNormalPressureContourCount(points), greaterThan(1));
  });

  test('maps normalized object ink without stretching the pen nib', () {
    final local = InkStroke(
      id: 'table-ink',
      points: const <InkPoint>[
        InkPoint(x: .25, y: .2, pressure: .5),
        InkPoint(x: .75, y: .8, pressure: .8),
      ],
      width: .04,
    );

    final painted = InkPainter.objectLocalStrokeToCanvas(
      local,
      const Size(400, 200),
    );

    expect(painted.points.first.x, 100);
    expect(painted.points.first.y, 40);
    expect(painted.points.last.x, 300);
    expect(painted.points.last.y, 160);
    expect(painted.width, 8);
    expect(painted.points.first.pressure, .5);
  });

  test('rejects invalid object extents defensively', () {
    final local = InkStroke(
      id: 'invalid-target',
      points: const <InkPoint>[InkPoint(x: .5, y: .5)],
    );

    final painted = InkPainter.objectLocalStrokeToCanvas(
      local,
      const Size(double.infinity, 100),
    );

    expect(painted.points, isEmpty);
  });

  test('renders short and degenerate dashed strokes without an exception', () {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final strokes = <InkStroke>[
      InkStroke(
        id: 'tap',
        type: InkToolType.dashed,
        width: 8,
        points: const <InkPoint>[InkPoint(x: 4, y: 7)],
      ),
      InkStroke(
        id: 'duplicates',
        type: InkToolType.dashed,
        width: 8,
        points: const <InkPoint>[
          InkPoint(x: 10, y: 10),
          InkPoint(x: 10, y: 10),
          InkPoint(x: 10.000000001, y: 10),
          InkPoint(x: 30, y: 10),
        ],
      ),
    ];

    expect(() {
      for (final stroke in strokes) {
        InkPainter.drawStroke(canvas, stroke);
      }
    }, returnsNormally);
    recorder.endRecording().dispose();
  });

  test('does not pass corrupt dashed geometry or width to the rasterizer', () {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final corrupt = InkStroke(
      id: 'corrupt-recovery-stroke',
      type: InkToolType.dashed,
      width: double.nan,
      points: const <InkPoint>[
        InkPoint(x: double.nan, y: 0, pressure: double.nan),
        InkPoint(x: double.infinity, y: 2),
        InkPoint(x: 1e100, y: 1e100),
      ],
    );

    expect(() => InkPainter.drawStroke(canvas, corrupt), returnsNormally);
    recorder.endRecording().dispose();
  });

  test('selected recovered ink keeps halo and dash work bounded', () {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final stroke = InkStroke(
      id: 'very-long-selected-dash',
      type: InkToolType.dashed,
      width: 6,
      points: List<InkPoint>.generate(
        100000,
        (index) => InkPoint(x: index.toDouble(), y: (index % 17).toDouble()),
        growable: false,
      ),
    );
    final painter = InkPainter(
      strokes: <InkStroke>[stroke],
      worldToScreenScale: 1,
      worldToScreenOffset: Offset.zero,
      selectionIds: const <String>{'very-long-selected-dash'},
    );

    expect(
      () => painter.paint(canvas, const Size(1000, 1000)),
      returnsNormally,
    );
    recorder.endRecording().dispose();
  });
}
