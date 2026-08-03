import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/engine/ink_stroke_eraser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String fragmentId(String sourceId, int index) => '$sourceId.part.$index';

  test('splits a sparse stroke at the exact circular eraser boundary', () {
    final stroke = InkStroke(
      id: 'source',
      points: const <InkPoint>[
        InkPoint(x: 0, y: 0, pressure: .2, timestampMicros: 100),
        InkPoint(x: 100, y: 0, pressure: .8, timestampMicros: 1100),
      ],
      colorArgb: 0xFF123456,
      width: 8,
      type: InkToolType.marker,
      zIndex: 7,
      authorId: 'student-a',
      pointerId: 42,
    );

    final result = InkStrokeEraser.eraseCapsule(
      stroke: stroke,
      eraserStart: const Vec2(50, 0),
      eraserEnd: const Vec2(50, 0),
      radius: 10,
      idFactory: fragmentId,
    );

    expect(result.changed, isTrue);
    expect(result.fragments, hasLength(2));
    expect(result.fragments[0].id, 'source');
    expect(result.fragments[1].id, 'source.part.1');
    expect(result.fragments[0].points.last.x, closeTo(40, 1e-7));
    expect(result.fragments[1].points.first.x, closeTo(60, 1e-7));
    expect(result.fragments[0].points.last.pressure, closeTo(.44, 1e-7));
    expect(result.fragments[1].points.first.timestampMicros, 700);
    for (final fragment in result.fragments) {
      expect(fragment.colorArgb, stroke.colorArgb);
      expect(fragment.width, stroke.width);
      expect(fragment.type, stroke.type);
      expect(fragment.zIndex, stroke.zIndex);
      expect(fragment.authorId, stroke.authorId);
      expect(fragment.pointerId, stroke.pointerId);
      expect(fragment.createdAt, stroke.createdAt);
    }
  });

  test('swept eraser removes the capsule between sparse input events', () {
    final stroke = InkStroke(
      id: 'vertical',
      points: const <InkPoint>[
        InkPoint(x: 50, y: -100),
        InkPoint(x: 50, y: 100),
      ],
    );

    final result = InkStrokeEraser.eraseCapsule(
      stroke: stroke,
      eraserStart: const Vec2(20, 0),
      eraserEnd: const Vec2(80, 0),
      radius: 12,
      idFactory: fragmentId,
    );

    expect(result.fragments, hasLength(2));
    expect(result.fragments.first.points.last.y, closeTo(-12, 1e-7));
    expect(result.fragments.last.points.first.y, closeTo(12, 1e-7));
  });

  test(
    'preserves an untouched stroke by identity and does not allocate IDs',
    () {
      final stroke = InkStroke(
        id: 'untouched',
        points: const <InkPoint>[InkPoint(x: 0, y: 0), InkPoint(x: 100, y: 0)],
      );
      var allocations = 0;

      final result = InkStrokeEraser.eraseCapsule(
        stroke: stroke,
        eraserStart: const Vec2(0, 100),
        eraserEnd: const Vec2(100, 100),
        radius: 5,
        idFactory: (sourceId, index) {
          allocations++;
          return '$sourceId.$index';
        },
      );

      expect(result.changed, isFalse);
      expect(result.fragments.single, same(stroke));
      expect(allocations, 0);
    },
  );

  test('fully covered stroke and covered dot produce no fragments', () {
    final line = InkStroke(
      id: 'line',
      points: const <InkPoint>[InkPoint(x: 40, y: 0), InkPoint(x: 60, y: 0)],
    );
    final dot = InkStroke(
      id: 'dot',
      points: const <InkPoint>[InkPoint(x: 50, y: 0)],
    );

    for (final stroke in <InkStroke>[line, dot]) {
      final result = InkStrokeEraser.eraseCapsule(
        stroke: stroke,
        eraserStart: const Vec2(50, 0),
        eraserEnd: const Vec2(50, 0),
        radius: 20,
        idFactory: fragmentId,
      );
      expect(result.changed, isTrue);
      expect(result.fragments, isEmpty);
    }
  });

  test('projection supports normalized object-bound ink', () {
    final stroke = InkStroke(
      id: 'annotation',
      points: const <InkPoint>[InkPoint(x: 0, y: .5), InkPoint(x: 1, y: .5)],
      width: .01,
    );

    final result = InkStrokeEraser.eraseCapsule(
      stroke: stroke,
      eraserStart: const Vec2(150, 140),
      eraserEnd: const Vec2(150, 160),
      radius: 10,
      project: (point) => Vec2(100 + point.x * 100, 100 + point.y * 100),
      idFactory: fragmentId,
    );

    expect(result.fragments, hasLength(2));
    expect(result.fragments.first.points.last.x, closeTo(.4, 1e-7));
    expect(result.fragments.last.points.first.x, closeTo(.6, 1e-7));
  });

  test('repeated subtraction can split an already-created fragment', () {
    final stroke = InkStroke(
      id: 'source',
      points: const <InkPoint>[InkPoint(x: 0, y: 0), InkPoint(x: 100, y: 0)],
    );
    final first = InkStrokeEraser.eraseCapsule(
      stroke: stroke,
      eraserStart: const Vec2(30, 0),
      eraserEnd: const Vec2(30, 0),
      radius: 5,
      idFactory: fragmentId,
    );
    final right = first.fragments.last;
    final second = InkStrokeEraser.eraseCapsule(
      stroke: right,
      eraserStart: const Vec2(70, 0),
      eraserEnd: const Vec2(70, 0),
      radius: 5,
      idFactory: fragmentId,
    );

    expect(first.fragments.first.points.last.x, closeTo(25, 1e-7));
    expect(second.fragments, hasLength(2));
    expect(second.fragments.first.points.first.x, closeTo(35, 1e-7));
    expect(second.fragments.first.points.last.x, closeTo(65, 1e-7));
    expect(second.fragments.last.points.first.x, closeTo(75, 1e-7));
  });

  test('horizontal partition clips the destructive half of the capsule', () {
    final stroke = InkStroke(
      id: 'cross-divider',
      points: const <InkPoint>[InkPoint(x: 900, y: 0), InkPoint(x: 1020, y: 0)],
    );

    final result = InkStrokeEraser.eraseCapsule(
      stroke: stroke,
      eraserStart: const Vec2(950, 0),
      eraserEnd: const Vec2(970, 0),
      radius: 80,
      eraseMaximumX: 960,
      idFactory: fragmentId,
    );

    expect(result.changed, isTrue);
    expect(result.fragments, hasLength(1));
    expect(result.fragments.single.points.first.x, closeTo(960, 1e-7));
    expect(result.fragments.single.points.last.x, 1020);
  });
}
