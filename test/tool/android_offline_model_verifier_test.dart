import 'package:flutter_test/flutter_test.dart';

import '../../tool/android_offline_model_verifier.dart';

void main() {
  const verifier = AndroidOfflineModelVerifier();
  final validHandwriting = <String, OfflineAssetEvidence>{
    for (final entry
        in AndroidOfflineModelVerifier.requiredHandwritingAssetHashes.entries)
      'base/assets/${entry.key}': OfflineAssetEvidence(
        size: entry.key.endsWith('.onnx')
            ? 21159378
            : entry.key.endsWith('.yml')
            ? 150579
            : 12000,
        sha256: entry.value,
      ),
  };
  final validNativeLibraries = <String, int>{
    for (final abi in AndroidOfflineModelVerifier.releaseAbis)
      for (final library
          in AndroidOfflineModelVerifier.requiredOnnxRuntimeLibraries)
        'lib/$abi/$library':
            AndroidOfflineModelVerifier.minimumOnnxRuntimeLibraryBytes + 1,
  };
  final validOnnxJavaDescriptors = AndroidOfflineModelVerifier
      .requiredOnnxJavaDescriptors
      .toSet();

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
      handwritingEntries: validHandwriting,
      nativeLibraryEntries: validNativeLibraries,
      onnxJavaDescriptors: validOnnxJavaDescriptors,
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
        handwritingEntries: validHandwriting,
        nativeLibraryEntries: validNativeLibraries,
        onnxJavaDescriptors: validOnnxJavaDescriptors,
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

  test('rejects an APK whose bundled handwriting model changed', () {
    final entries = <String, int>{
      for (final suffix in AndroidOfflineModelVerifier.requiredModelSuffixes)
        'base/assets/$suffix': 310000,
      for (var index = 0; index < 14; index++)
        'assets/mlkit-google-ocr-models/part-$index.binarypb': 1000,
    };
    final changed = Map<String, OfflineAssetEvidence>.of(validHandwriting);
    final modelPath = changed.keys.singleWhere(
      (path) => path.endsWith('.onnx'),
    );
    changed[modelPath] = const OfflineAssetEvidence(
      size: 21159378,
      sha256: '00',
    );

    expect(
      () => verifier.evaluateEntries(
        artifactName: 'app-x86_64-release.apk',
        modelEntries: entries,
        handwritingEntries: changed,
        nativeLibraryEntries: validNativeLibraries,
        onnxJavaDescriptors: validOnnxJavaDescriptors,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('PP-OCRv6-Handschriftmodell'),
        ),
      ),
    );
  });

  test('rejects a split whose matching ONNX Runtime JNI library is absent', () {
    final entries = <String, int>{
      for (final suffix in AndroidOfflineModelVerifier.requiredModelSuffixes)
        'base/assets/$suffix': 310000,
      for (var index = 0; index < 14; index++)
        'assets/mlkit-google-ocr-models/part-$index.binarypb': 1000,
    };
    final incompleteNative = Map<String, int>.of(validNativeLibraries)
      ..remove('lib/arm64-v8a/libonnxruntime4j_jni.so');

    expect(
      () => verifier.evaluateEntries(
        artifactName: 'app-arm64-v8a-release.apk',
        modelEntries: entries,
        handwritingEntries: validHandwriting,
        nativeLibraryEntries: incompleteNative,
        onnxJavaDescriptors: validOnnxJavaDescriptors,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('ABI-passende ONNX-Runtime'), contains('arm64-v8a')),
        ),
      ),
    );
  });

  test('rejects an R8 artifact missing a JNI-resolved ONNX Java type', () {
    final entries = <String, int>{
      for (final suffix in AndroidOfflineModelVerifier.requiredModelSuffixes)
        'base/assets/$suffix': 310000,
      for (var index = 0; index < 14; index++)
        'assets/mlkit-google-ocr-models/part-$index.binarypb': 1000,
    };
    final incompleteDescriptors = Set<String>.of(validOnnxJavaDescriptors)
      ..remove('Lai/onnxruntime/TensorInfo;');

    expect(
      () => verifier.evaluateEntries(
        artifactName: 'app-arm64-v8a-release.apk',
        modelEntries: entries,
        handwritingEntries: validHandwriting,
        nativeLibraryEntries: validNativeLibraries,
        onnxJavaDescriptors: incompleteDescriptors,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('JNI'), contains('TensorInfo')),
        ),
      ),
    );
  });
}
