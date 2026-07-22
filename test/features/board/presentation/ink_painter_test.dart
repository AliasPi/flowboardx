import 'dart:ui' as ui;

import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/presentation/ink_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
