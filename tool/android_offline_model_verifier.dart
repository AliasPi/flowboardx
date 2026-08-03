import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

/// Build-time verification for Flowboard X's download-free Android recognizer.
///
/// ML Kit's bundled Latin OCR artifact contributes a set of assets below
/// `mlkit-google-ocr-models`. Merely resolving the Maven dependency is not
/// enough evidence for a distributable build: shrinker or packaging changes
/// must not silently remove those files from one split APK. The official
/// PP-OCRv6 ONNX model and its metadata are additionally checked by SHA-256.
final class AndroidOfflineModelVerifier {
  const AndroidOfflineModelVerifier();

  static const int minimumModelFileCount = 18;
  static const int minimumUncompressedModelBytes = 1_200_000;

  static const List<String> requiredModelSuffixes = <String>[
    'mlkit-google-ocr-models/gocr/gocr_models/'
        'line_recognition_legacy_mobile/Latn_ctc/optical/lstm_model.fb',
    'mlkit-google-ocr-models/gocr/gocr_models/'
        'line_recognition_legacy_mobile/tflite_langid.tflite',
    'mlkit-google-ocr-models/gocr/layout/'
        'line_clustering_custom_ops/model.tflite',
    'mlkit-google-ocr-models/taser/detector/'
        'rpn_text_detector_mobile_space_to_depth_quantized_mbv2_v1.tflite',
  ];

  static const Map<String, String> requiredHandwritingAssetHashes =
      <String, String>{
        'handwriting/PP-OCRv6_small_rec.onnx':
            '5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634',
        'handwriting/PP-OCRv6_small_rec.yml':
            'ab078671bb49f06228eadccd34f1bb501e157f7a047095ffb943ba81512c77d1',
        'handwriting/PADDLEOCR_APACHE_2_LICENSE.txt':
            '3840c5c0c61c294264d2dd77b8777be6ddd90121ef4e0e64abcd22edea581d6e',
        'handwriting/ONNXRUNTIME_MIT_LICENSE.txt':
            '2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c',
      };

  static const int minimumPaddleModelBytes = 20_000_000;
  static const int minimumOnnxRuntimeLibraryBytes = 50_000;
  static const List<String> releaseAbis = <String>[
    'armeabi-v7a',
    'arm64-v8a',
    'x86_64',
  ];
  static const List<String> requiredOnnxRuntimeLibraries = <String>[
    'libonnxruntime.so',
    'libonnxruntime4j_jni.so',
  ];
  static const List<String> requiredOnnxJavaDescriptors = <String>[
    'Lai/onnxruntime/OnnxTensor;',
    'Lai/onnxruntime/OnnxValue;',
    'Lai/onnxruntime/OrtSession;',
    'Lai/onnxruntime/TensorInfo;',
  ];

  OfflineModelReport verifyArchive(File artifact) {
    if (!artifact.existsSync() ||
        FileSystemEntity.typeSync(artifact.path) != FileSystemEntityType.file) {
      throw StateError('Android-Artefakt fehlt: ${artifact.path}');
    }
    final input = InputFileStream(artifact.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final modelEntries = <String, int>{
        for (final entry in archive.files)
          if (entry.isFile &&
              _normalized(entry.name).contains('mlkit-google-ocr-models/'))
            _normalized(entry.name): entry.size,
      };
      final handwritingEntries = <String, OfflineAssetEvidence>{
        for (final entry in archive.files)
          if (entry.isFile &&
              requiredHandwritingAssetHashes.keys.any(
                (suffix) => _normalized(entry.name).endsWith(suffix),
              ))
            _normalized(entry.name): OfflineAssetEvidence(
              size: entry.size,
              sha256: sha256.convert(entry.content).toString(),
            ),
      };
      final nativeLibraryEntries = <String, int>{
        for (final entry in archive.files)
          if (entry.isFile &&
              requiredOnnxRuntimeLibraries.any(
                (name) => _normalized(entry.name).endsWith('/$name'),
              ))
            _normalized(entry.name): entry.size,
      };
      final dexPayloads = <List<int>>[
        for (final entry in archive.files)
          if (entry.isFile &&
              RegExp(
                r'(^|/)classes[0-9]*\.dex$',
              ).hasMatch(_normalized(entry.name)))
            entry.content,
      ];
      final onnxJavaDescriptors = <String>{
        for (final descriptor in requiredOnnxJavaDescriptors)
          if (dexPayloads.any(
            (payload) => _containsBytes(payload, ascii.encode(descriptor)),
          ))
            descriptor,
      };
      return evaluateEntries(
        artifactName: artifact.uri.pathSegments.last,
        modelEntries: modelEntries,
        handwritingEntries: handwritingEntries,
        nativeLibraryEntries: nativeLibraryEntries,
        onnxJavaDescriptors: onnxJavaDescriptors,
      );
    } finally {
      input.closeSync();
    }
  }

  OfflineModelReport evaluateEntries({
    required String artifactName,
    required Map<String, int> modelEntries,
    required Map<String, OfflineAssetEvidence> handwritingEntries,
    required Map<String, int> nativeLibraryEntries,
    required Set<String> onnxJavaDescriptors,
  }) {
    final normalizedEntries = <String, int>{
      for (final entry in modelEntries.entries)
        _normalized(entry.key): entry.value,
    };
    final missing = requiredModelSuffixes
        .where(
          (suffix) =>
              !normalizedEntries.keys.any((path) => path.endsWith(suffix)),
        )
        .toList(growable: false);
    final totalBytes = normalizedEntries.values.fold<int>(
      0,
      (sum, size) => sum + (size > 0 ? size : 0),
    );
    if (missing.isNotEmpty ||
        normalizedEntries.length < minimumModelFileCount ||
        totalBytes < minimumUncompressedModelBytes) {
      throw StateError(
        'Das Android-Artefakt $artifactName enthält kein vollständiges '
        'Offline-Handschriftmodell '
        '(Dateien ${normalizedEntries.length}/$minimumModelFileCount, '
        'Bytes $totalBytes/$minimumUncompressedModelBytes'
        '${missing.isEmpty ? '' : ', fehlend: ${missing.join(', ')}'}).',
      );
    }

    final normalizedHandwriting = <String, OfflineAssetEvidence>{
      for (final entry in handwritingEntries.entries)
        _normalized(entry.key): entry.value,
    };
    final missingOrChangedHandwriting = <String>[];
    for (final required in requiredHandwritingAssetHashes.entries) {
      OfflineAssetEvidence? match;
      for (final entry in normalizedHandwriting.entries) {
        if (entry.key.endsWith(required.key)) {
          match = entry.value;
          break;
        }
      }
      if (match == null ||
          match.sha256.toLowerCase() != required.value ||
          (required.key.endsWith('.onnx') &&
              match.size < minimumPaddleModelBytes)) {
        missingOrChangedHandwriting.add(required.key);
      }
    }
    if (missingOrChangedHandwriting.isNotEmpty) {
      throw StateError(
        'Das Android-Artefakt $artifactName enthält kein unverändertes '
        'eingebettetes PP-OCRv6-Handschriftmodell '
        '(fehlend/geändert: ${missingOrChangedHandwriting.join(', ')}).',
      );
    }
    final normalizedNativeLibraries = <String, int>{
      for (final entry in nativeLibraryEntries.entries)
        _normalized(entry.key): entry.value,
    };
    final artifactLower = artifactName.toLowerCase();
    String? artifactAbi;
    for (final abi in releaseAbis) {
      if (artifactLower.contains(abi)) {
        artifactAbi = abi;
        break;
      }
    }
    final requiredAbis = artifactAbi == null
        ? releaseAbis
        : <String>[artifactAbi];
    final missingNativeLibraries = <String>[];
    for (final abi in requiredAbis) {
      for (final library in requiredOnnxRuntimeLibraries) {
        final suffix = 'lib/$abi/$library';
        int? matchingSize;
        for (final entry in normalizedNativeLibraries.entries) {
          if (entry.key.endsWith(suffix)) {
            matchingSize = entry.value;
            break;
          }
        }
        if (matchingSize == null ||
            matchingSize < minimumOnnxRuntimeLibraryBytes) {
          missingNativeLibraries.add('$abi/$library');
        }
      }
    }
    if (missingNativeLibraries.isNotEmpty) {
      throw StateError(
        'Das Android-Artefakt $artifactName enthält keine vollständige '
        'ABI-passende ONNX-Runtime '
        '(fehlend/zu klein: ${missingNativeLibraries.join(', ')}).',
      );
    }
    final missingOnnxJavaTypes = requiredOnnxJavaDescriptors
        .where((descriptor) => !onnxJavaDescriptors.contains(descriptor))
        .toList(growable: false);
    if (missingOnnxJavaTypes.isNotEmpty) {
      throw StateError(
        'Das Android-Artefakt $artifactName enthält nicht alle von der '
        'nativen ONNX-Runtime per JNI aufgelösten Java-Typen '
        '(fehlend: ${missingOnnxJavaTypes.join(', ')}).',
      );
    }
    final handwritingBytes = normalizedHandwriting.values.fold<int>(
      0,
      (sum, asset) => sum + (asset.size > 0 ? asset.size : 0),
    );
    return OfflineModelReport(
      artifactName: artifactName,
      modelFileCount: normalizedEntries.length,
      uncompressedModelBytes: totalBytes,
      handwritingAssetCount: normalizedHandwriting.length,
      handwritingAssetBytes: handwritingBytes,
      onnxRuntimeLibraryCount: normalizedNativeLibraries.length,
      onnxRuntimeJavaTypeCount: onnxJavaDescriptors.length,
    );
  }

  static String _normalized(String path) => path.replaceAll('\\', '/');

  static bool _containsBytes(List<int> data, List<int> pattern) {
    if (pattern.isEmpty) return true;
    if (pattern.length > data.length) return false;
    final lastStart = data.length - pattern.length;
    for (var start = 0; start <= lastStart; start++) {
      if (data[start] != pattern.first) continue;
      var matched = true;
      for (var offset = 1; offset < pattern.length; offset++) {
        if (data[start + offset] != pattern[offset]) {
          matched = false;
          break;
        }
      }
      if (matched) return true;
    }
    return false;
  }
}

final class OfflineModelReport {
  const OfflineModelReport({
    required this.artifactName,
    required this.modelFileCount,
    required this.uncompressedModelBytes,
    required this.handwritingAssetCount,
    required this.handwritingAssetBytes,
    required this.onnxRuntimeLibraryCount,
    required this.onnxRuntimeJavaTypeCount,
  });

  final String artifactName;
  final int modelFileCount;
  final int uncompressedModelBytes;
  final int handwritingAssetCount;
  final int handwritingAssetBytes;
  final int onnxRuntimeLibraryCount;
  final int onnxRuntimeJavaTypeCount;
}

final class OfflineAssetEvidence {
  const OfflineAssetEvidence({required this.size, required this.sha256});

  final int size;
  final String sha256;
}

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    stderr.writeln(
      'Aufruf: dart run tool/android_offline_model_verifier.dart '
      '<app.apk|app.aab> [...]',
    );
    exitCode = 64;
    return;
  }
  const verifier = AndroidOfflineModelVerifier();
  for (final path in arguments) {
    final report = verifier.verifyArchive(File(path));
    stdout.writeln(
      '${report.artifactName}: ${report.modelFileCount} Modelldateien, '
      '${report.uncompressedModelBytes} Byte ML Kit; '
      '${report.handwritingAssetCount} PP-OCRv6-Assets, '
      '${report.handwritingAssetBytes} Byte; '
      '${report.onnxRuntimeLibraryCount} ONNX-Runtime-Bibliotheken, '
      '${report.onnxRuntimeJavaTypeCount} JNI-Java-Typen, '
      'vollständig offline.',
    );
  }
}
