import 'dart:convert';

import 'package:flowboard_x/src/domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InkStroke point serialization', () {
    test('computes and caches bounds for a long curved stroke', () {
      final stroke = InkStroke(
        id: 'curved-bounds',
        width: 8,
        points: List<InkPoint>.generate(
          4096,
          (index) => InkPoint(
            x: index.isEven ? -120 : 340,
            y: index % 3 == 0 ? -80 : 260,
          ),
          growable: false,
        ),
      );

      final first = stroke.bounds;
      final second = stroke.bounds;

      expect(first.left, -124);
      expect(first.top, -84);
      expect(first.width, 468);
      expect(first.height, 348);
      expect(identical(first, second), isTrue);
    });

    test('writes a flat numeric array and round-trips every point field', () {
      final stroke = InkStroke(
        id: 'compact',
        points: const <InkPoint>[
          InkPoint(
            x: 1.25,
            y: -2.5,
            pressure: .35,
            timestampMicros: 123456789,
            tiltX: -.2,
            tiltY: .4,
          ),
          InkPoint(
            x: 8,
            y: 13,
            pressure: .9,
            timestampMicros: 123456999,
            tiltX: .1,
            tiltY: -.7,
          ),
        ],
      );

      final encoded = stroke.toJson();
      final points = encoded['points']! as List<Object?>;
      final decoded = InkStroke.fromJson(
        Map<String, Object?>.from(
          jsonDecode(jsonEncode(encoded)) as Map<Object?, Object?>,
        ),
      );

      expect(points, hasLength(12));
      expect(points, everyElement(isA<num>()));
      expect(decoded.points, hasLength(2));
      expect(decoded.points[0].x, 1.25);
      expect(decoded.points[0].y, -2.5);
      expect(decoded.points[0].pressure, .35);
      expect(decoded.points[0].timestampMicros, 123456789);
      expect(decoded.points[0].tiltX, -.2);
      expect(decoded.points[0].tiltY, .4);
      expect(decoded.points[1].timestampMicros, 123456999);
    });

    test('continues to read the legacy map-per-point representation', () {
      final stroke = InkStroke.fromJson(<String, Object?>{
        'id': 'legacy',
        'points': <Object?>[
          <String, Object?>{
            'x': 4,
            'y': 7,
            'pressure': .6,
            'timestampMicros': 42,
            'tiltX': .2,
            'tiltY': -.3,
          },
        ],
      });

      expect(stroke.points.single.x, 4);
      expect(stroke.points.single.y, 7);
      expect(stroke.points.single.pressure, .6);
      expect(stroke.points.single.timestampMicros, 42);
      expect(stroke.points.single.tiltX, .2);
      expect(stroke.points.single.tiltY, -.3);
    });

    test('compact encoding stays materially smaller than legacy JSON', () {
      final points = List<InkPoint>.generate(
        4000,
        (index) => InkPoint(
          x: (index % 800).toDouble(),
          y: (index % 500).toDouble(),
          pressure: (index % 10) / 10,
          timestampMicros: 1700000000000000 + index * 8000,
          tiltX: 0,
          tiltY: 0,
        ),
        growable: false,
      );
      final stroke = InkStroke(id: 'size', points: points);
      final compact = jsonEncode(stroke.toJson());
      final legacy = jsonEncode(<String, Object?>{
        ...stroke.toJson(),
        'points': points.map((point) => point.toJson()).toList(growable: false),
      });

      expect(
        compact.length,
        lessThan((legacy.length * .55).floor()),
        reason:
            'Repeated point field names must not return to persisted documents.',
      );
    });
  });
}
