import 'dart:math' as math;

import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/handwriting/handwriting_recognition_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bundled Android handwriting engine survives real requests', (
    tester,
  ) async {
    const service = PlatformHandwritingRecognitionService();
    expect(await service.isAvailable(), isTrue);

    final requests = <HandwritingRecognitionRequest>[
      HandwritingRecognitionRequest(strokes: _blockLetterStrokes()),
      HandwritingRecognitionRequest(strokes: _denseRoundedStrokes()),
      HandwritingRecognitionRequest(strokes: _multiLineStrokes()),
    ];

    for (final request in requests) {
      final result = await service
          .recognize(request)
          .timeout(const Duration(seconds: 25));
      expect(
        result.status,
        anyOf(
          HandwritingRecognitionStatus.recognized,
          HandwritingRecognitionStatus.notRecognized,
        ),
      );
    }
  });
}

List<InkStroke> _blockLetterStrokes() => <InkStroke>[
  _stroke('h-left', const <InkPoint>[
    InkPoint(x: 20, y: 20),
    InkPoint(x: 20, y: 120),
  ]),
  _stroke('h-right', const <InkPoint>[
    InkPoint(x: 80, y: 20),
    InkPoint(x: 80, y: 120),
  ]),
  _stroke('h-center', const <InkPoint>[
    InkPoint(x: 20, y: 70),
    InkPoint(x: 80, y: 70),
  ]),
  _stroke('i', const <InkPoint>[
    InkPoint(x: 125, y: 20),
    InkPoint(x: 125, y: 120),
  ]),
];

List<InkStroke> _denseRoundedStrokes() {
  const pointCount = 6000;
  final points = <InkPoint>[
    for (var index = 0; index < pointCount; index++)
      InkPoint(
        x: 180 + math.cos(index / (pointCount - 1) * math.pi * 2) * 150,
        y: 180 + math.sin(index / (pointCount - 1) * math.pi * 2) * 120,
        timestampMicros: index * 1000,
      ),
  ];
  return <InkStroke>[_stroke('dense-loop', points)];
}

List<InkStroke> _multiLineStrokes() => <InkStroke>[
  _stroke('line-1-a', const <InkPoint>[
    InkPoint(x: 10, y: 25),
    InkPoint(x: 70, y: 25),
    InkPoint(x: 120, y: 30),
  ]),
  _stroke('line-1-b', const <InkPoint>[
    InkPoint(x: 140, y: 20),
    InkPoint(x: 140, y: 75),
  ]),
  _stroke('line-2-a', const <InkPoint>[
    InkPoint(x: 15, y: 150),
    InkPoint(x: 65, y: 210),
    InkPoint(x: 120, y: 150),
  ]),
  _stroke('line-2-b', const <InkPoint>[
    InkPoint(x: 145, y: 150),
    InkPoint(x: 205, y: 210),
  ]),
];

InkStroke _stroke(String id, List<InkPoint> points) =>
    InkStroke(id: id, points: points, width: 8);
