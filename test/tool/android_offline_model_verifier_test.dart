import 'package:flutter_test/flutter_test.dart';

import '../../tool/android_offline_model_verifier.dart';

void main() {
  const verifier = AndroidOfflineModelVerifier();

  test('accepts a complete statically bundled Latin model', () {
    final entries = <String, int>{
      for (final suffix in AndroidOfflineModelVerifier.requiredModelSuffixes)
        'base/assets/$suffix': 310000,
      for (var index = 0; index < 14; index++)
        'assets/mlkit-google-ocr-models/part-$index.binarypb': 1000,
    };

    final report = verifier.evaluateEntries(
      artifactName: 'app-arm64-v8a-release.apk',
      modelEntries: entries,
    );

    expect(
      report.modelFileCount,
      AndroidOfflineModelVerifier.minimumModelFileCount,
    );
    expect(
      report.uncompressedModelBytes,
      greaterThanOrEqualTo(
        AndroidOfflineModelVerifier.minimumUncompressedModelBytes,
      ),
    );
  });

  test('rejects a split artifact with a missing recognition model', () {
    expect(
      () => verifier.evaluateEntries(
        artifactName: 'app-armeabi-v7a-release.apk',
        modelEntries: const <String, int>{
          'assets/mlkit-google-ocr-models/placeholder.binarypb': 64,
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('kein vollständiges Offline-Handschriftmodell'),
        ),
      ),
    );
  });
}
