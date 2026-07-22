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

  test(
    'recognizes directly through the platform boundary and parses confidence',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'recognize') {
              return <String, Object>{'text': 'Hallo', 'confidence': .91};
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

  test('generic unavailable message never asks for a download', () {
    const error = HandwritingRecognitionUnavailable();
    expect(error.toString(), isNot(contains('Download')));
    expect(error.toString(), isNot(contains('Internet')));
  });
}
