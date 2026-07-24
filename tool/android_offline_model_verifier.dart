import 'dart:io';

import 'package:archive/archive_io.dart';

/// Build-time verification for Flowboard X's download-free Android recognizer.
///
/// ML Kit's bundled Latin OCR artifact contributes a set of assets below
/// `mlkit-google-ocr-models`. Merely resolving the Maven dependency is not
/// enough evidence for a distributable build: shrinker or packaging changes
/// must not silently remove those files from one split APK. This verifier reads
/// the ZIP central directory only; model payloads are not decompressed.
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
      return evaluateEntries(
        artifactName: artifact.uri.pathSegments.last,
        modelEntries: modelEntries,
      );
    } finally {
      input.closeSync();
    }
  }

  OfflineModelReport evaluateEntries({
    required String artifactName,
    required Map<String, int> modelEntries,
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
    return OfflineModelReport(
      artifactName: artifactName,
      modelFileCount: normalizedEntries.length,
      uncompressedModelBytes: totalBytes,
    );
  }

  static String _normalized(String path) => path.replaceAll('\\', '/');
}

final class OfflineModelReport {
  const OfflineModelReport({
    required this.artifactName,
    required this.modelFileCount,
    required this.uncompressedModelBytes,
  });

  final String artifactName;
  final int modelFileCount;
  final int uncompressedModelBytes;
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
      '${report.uncompressedModelBytes} Byte, vollständig offline.',
    );
  }
}
