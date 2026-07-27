import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/handwriting/handwriting_recognition_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flowboard_test/handwriting');
  const service = PlatformHandwritingRecognitionService(channel: channel);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('serializes complete stroke geometry for an optional recognizer', () {
    final request = HandwritingRecognitionRequest(
      strokes: [
        InkStroke(
          id: 's1',
          points: const [
            InkPoint(x: 1, y: 2, timestampMicros: 3),
            InkPoint(x: 4, y: 5, timestampMicros: 6),
          ],
        ),
      ],
    );
    final map = request.toMap();
    expect(map['languageTag'], 'de-DE');
    expect((map['strokes']! as List).single, containsPair('id', 's1'));
  });

  test('filters corrupt coordinates before crossing the platform channel', () {
    final request = HandwritingRecognitionRequest(
      strokes: [
        InkStroke(
          id: 'damaged',
          points: const [
            InkPoint(x: double.nan, y: 2),
            InkPoint(x: double.infinity, y: 3),
            InkPoint(x: 12, y: 14, timestampMicros: 9),
          ],
        ),
      ],
    );

    final stroke = (request.toMap()['strokes']! as List).single as Map;
    final points = stroke['points']! as List;
    expect(points, hasLength(1));
    expect(points.single, containsPair('x', 12));
    expect(request.hasSerializableInk, isTrue);
  });

  test('bounds dense smartboard packets and preserves endpoints and turns', () {
    final source = List<InkPoint>.generate(
      HandwritingRecognitionRequest.maximumChannelPointsPerStroke + 401,
      (index) => InkPoint(
        x: index.toDouble(),
        y: index == 6001 ? 240 : 0,
        timestampMicros: index,
      ),
      growable: false,
    );
    final request = HandwritingRecognitionRequest(
      strokes: <InkStroke>[InkStroke(id: 'dense', points: source)],
    );

    final stroke = (request.toMap()['strokes']! as List).single as Map;
    final points = stroke['points']! as List;
    expect(
      points.length,
      lessThanOrEqualTo(
        HandwritingRecognitionRequest.maximumChannelPointsPerStroke,
      ),
    );
    expect((points.first as Map)['x'], source.first.x);
    expect((points.last as Map)['x'], source.last.x);
    expect(
      points.cast<Map>().any((point) => point['y'] == 240),
      isTrue,
      reason: 'the sharp turn must survive dense-packet simplification',
    );
  });

  test('caps the complete channel payload across many selected strokes', () {
    final request = HandwritingRecognitionRequest(
      strokes: <InkStroke>[
        for (var stroke = 0; stroke < 10; stroke++)
          InkStroke(
            id: 'dense-$stroke',
            points: List<InkPoint>.generate(
              9000,
              (index) => InkPoint(x: index.toDouble(), y: stroke.toDouble()),
              growable: false,
            ),
          ),
      ],
    );

    final serialized = request.toMap()['strokes']! as List;
    final pointCount = serialized.fold<int>(
      0,
      (total, stroke) => total + ((stroke as Map)['points']! as List).length,
    );
    expect(
      pointCount,
      lessThanOrEqualTo(HandwritingRecognitionRequest.maximumChannelPointCount),
    );
    expect(serialized, hasLength(10));
  });

  test('redistributes unused point budget to a dense cursive stroke', () {
    final densePoints = List<InkPoint>.generate(
      HandwritingRecognitionRequest.maximumChannelPointsPerStroke,
      (index) => InkPoint(
        x: index.toDouble(),
        y: (index % 37).toDouble(),
        timestampMicros: index,
      ),
      growable: false,
    );
    final request = HandwritingRecognitionRequest(
      strokes: <InkStroke>[
        for (var index = 0; index < 99; index++)
          InkStroke(
            id: 'dot-$index',
            points: <InkPoint>[InkPoint(x: index.toDouble(), y: 0)],
          ),
        InkStroke(id: 'cursive', points: densePoints),
      ],
    );

    final serialized = (request.toMap()['strokes']! as List).cast<Map>();
    final cursive = serialized.singleWhere(
      (stroke) => stroke['id'] == 'cursive',
    );

    expect(cursive['points'], hasLength(densePoints.length));
  });

  test('normalized sampling preserves a tight turn beside long packets', () {
    final source = <InkPoint>[
      for (var index = 0; index < 6500; index++) InkPoint(x: index * 4.0, y: 0),
      const InkPoint(x: 26000, y: 2),
      const InkPoint(x: 26001, y: 28),
      const InkPoint(x: 26002, y: 2),
      for (var index = 6501; index < 13000; index++)
        InkPoint(x: index * 4.0, y: 0),
    ];
    final request = HandwritingRecognitionRequest(
      strokes: <InkStroke>[InkStroke(id: 'tight-turn', points: source)],
    );

    final stroke = (request.toMap()['strokes']! as List).single as Map;
    final points = (stroke['points']! as List).cast<Map>();

    expect(
      points.any((point) => point['y'] == 28),
      isTrue,
      reason: 'short high-curvature features must not lose to long segments',
    );
  });

  test(
    'rejects oversized stroke selections before the native boundary',
    () async {
      var invoked = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            invoked = true;
            return null;
          });
      final request = HandwritingRecognitionRequest(
        strokes: <InkStroke>[
          for (
            var index = 0;
            index < HandwritingRecognitionRequest.maximumChannelStrokeCount + 1;
            index++
          )
            InkStroke(
              id: 'stroke-$index',
              points: <InkPoint>[InkPoint(x: index.toDouble(), y: 1)],
            ),
        ],
      );

      final result = await service.recognize(request);

      expect(result.isRecognized, isFalse);
      expect(result.message, contains('zu viele'));
      expect(invoked, isFalse);
    },
  );

  test(
    'recognizes directly through the platform boundary and parses confidence',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'recognize') {
              return <String, Object>{
                'text': 'Hallo',
                'confidence': .91,
                'engine': 'bundledLatinOcr16',
                'modelDelivery': 'bundled-apk',
              };
            }
            return null;
          });
      final result = await service.recognize(
        HandwritingRecognitionRequest(
          strokes: [
            InkStroke(id: 's', points: const [InkPoint(x: 0, y: 0)]),
          ],
        ),
      );
      expect(result.text, 'Hallo');
      expect(result.confidence, .91);
      expect(result.isRecognized, isTrue);
      expect(result.engine, 'bundledLatinOcr16');
      expect(result.modelDelivery, 'bundled-apk');
    },
  );

  test('prepare requests a network-free native availability check', () async {
    MethodCall? invocation;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          invocation = call;
          return true;
        });

    expect(await service.prepare(languageTag: 'en-US'), isTrue);
    expect(invocation?.method, 'ensureModel');
    expect(invocation?.arguments, containsPair('languageTag', 'en-US'));
  });

  test(
    'reports native recognition failure without leaking PlatformException',
    () {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(
              code: 'recognizer_unavailable',
              message: 'Lokaler Recognizer nicht verfügbar.',
            );
          });

      expect(
        () => service.recognize(
          HandwritingRecognitionRequest(
            strokes: [
              InkStroke(id: 's', points: const [InkPoint(x: 0, y: 0)]),
            ],
          ),
        ),
        throwsA(
          isA<HandwritingRecognitionUnavailable>().having(
            (error) => error.toString(),
            'message',
            contains('Recognizer'),
          ),
        ),
      );
    },
  );

  test(
    'treats no native candidate as a typed, non-exceptional result',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => <String, Object>{
              'status': 'notRecognized',
              'message': 'Keine sichere Erkennung.',
              'engine': 'bundledLatinOcr',
              'modelDelivery': 'bundled-apk',
              'attempts': 3,
              'lineCountHint': 2,
              'wordCountHint': 5,
              'durationMillis': 417,
              'timedOut': true,
            },
          );

      final result = await service.recognize(
        HandwritingRecognitionRequest(
          strokes: [
            InkStroke(id: 'short', points: const [InkPoint(x: 1, y: 2)]),
          ],
        ),
      );

      expect(result.isRecognized, isFalse);
      expect(result.status, HandwritingRecognitionStatus.notRecognized);
      expect(result.text, isEmpty);
      expect(result.message, 'Keine sichere Erkennung.');
      expect(result.engine, 'bundledLatinOcr');
      expect(result.modelDelivery, 'bundled-apk');
      expect(result.attemptCount, 3);
      expect(result.lineCountHint, 2);
      expect(result.wordCountHint, 5);
      expect(result.durationMillis, 417);
      expect(result.timedOut, isTrue);
    },
  );

  test('maps legacy no_candidate errors to a typed result', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'no_candidate',
            message: 'Nicht erkannt.',
          );
        });

    final result = await service.recognize(
      HandwritingRecognitionRequest(
        strokes: [
          InkStroke(id: 's', points: const [InkPoint(x: 0, y: 0)]),
        ],
      ),
    );

    expect(result.isRecognized, isFalse);
    expect(result.message, 'Nicht erkannt.');
  });

  test('rejects a recognized protocol response without text', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => <String, Object>{'status': 'recognized'},
        );

    expect(
      () => service.recognize(
        HandwritingRecognitionRequest(
          strokes: [
            InkStroke(id: 's', points: const [InkPoint(x: 0, y: 0)]),
          ],
        ),
      ),
      throwsA(
        isA<HandwritingRecognitionFailure>().having(
          (failure) => failure.kind,
          'kind',
          HandwritingRecognitionFailureKind.invalidResponse,
        ),
      ),
    );
  });

  test('empty ink is not reported as a FormatException', () async {
    final result = await service.recognize(
      HandwritingRecognitionRequest(strokes: const []),
    );

    expect(result.isRecognized, isFalse);
    expect(result.message, contains('Keine Handschrift'));
  });

  test('invalid native input is a typed technical failure', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'invalid_ink', message: 'Ungültig.');
        });

    await expectLater(
      service.recognize(
        HandwritingRecognitionRequest(
          strokes: [
            InkStroke(id: 's', points: const [InkPoint(x: 0, y: 0)]),
          ],
        ),
      ),
      throwsA(
        isA<HandwritingRecognitionFailure>()
            .having(
              (error) => error.kind,
              'kind',
              HandwritingRecognitionFailureKind.invalidInput,
            )
            .having((error) => error.toString(), 'message', 'Ungültig.'),
      ),
    );
  });

  test('native engine failures never surface as FormatException', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'recognition_failed',
            message: 'Enginefehler.',
          );
        });

    await expectLater(
      service.recognize(
        HandwritingRecognitionRequest(
          strokes: [
            InkStroke(id: 's', points: const [InkPoint(x: 0, y: 0)]),
          ],
        ),
      ),
      throwsA(
        isA<HandwritingRecognitionFailure>()
            .having(
              (error) => error.kind,
              'kind',
              HandwritingRecognitionFailureKind.engineFailure,
            )
            .having(
              (error) => error,
              'exception type',
              isNot(isA<FormatException>()),
            ),
      ),
    );
  });

  test('null platform response is a typed invalid response', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);

    await expectLater(
      service.recognize(
        HandwritingRecognitionRequest(
          strokes: [
            InkStroke(id: 's', points: const [InkPoint(x: 0, y: 0)]),
          ],
        ),
      ),
      throwsA(
        isA<HandwritingRecognitionFailure>()
            .having(
              (error) => error.kind,
              'kind',
              HandwritingRecognitionFailureKind.invalidResponse,
            )
            .having(
              (error) => error,
              'exception type',
              isNot(isA<FormatException>()),
            ),
      ),
    );
  });

  test('rejects an unknown native result status defensively', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => <String, Object>{'status': 'maybe'},
        );

    await expectLater(
      service.recognize(
        HandwritingRecognitionRequest(
          strokes: [
            InkStroke(id: 's', points: const [InkPoint(x: 0, y: 0)]),
          ],
        ),
      ),
      throwsA(
        isA<HandwritingRecognitionFailure>().having(
          (error) => error.kind,
          'kind',
          HandwritingRecognitionFailureKind.invalidResponse,
        ),
      ),
    );
  });

  test('generic unavailable message never asks for a download', () {
    const error = HandwritingRecognitionUnavailable();
    expect(error.toString(), isNot(contains('Download')));
    expect(error.toString(), isNot(contains('Internet')));
  });
}
