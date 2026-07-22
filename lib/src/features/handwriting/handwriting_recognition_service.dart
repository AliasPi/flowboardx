import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/model/ink.dart';

@immutable
final class HandwritingRecognitionRequest {
  HandwritingRecognitionRequest({
    required Iterable<InkStroke> strokes,
    this.languageTag = 'de-DE',
  }) : strokes = List<InkStroke>.unmodifiable(strokes);

  final List<InkStroke> strokes;
  final String languageTag;

  Map<String, Object?> toMap() => {
    'languageTag': languageTag,
    'strokes': [
      for (final stroke in strokes)
        {
          'id': stroke.id,
          'points': [
            for (final point in stroke.points)
              {
                'x': point.x,
                'y': point.y,
                'timestampMicros': point.timestampMicros,
              },
          ],
        },
    ],
  };
}

@immutable
final class HandwritingRecognitionResult {
  const HandwritingRecognitionResult({required this.text, this.confidence});

  final String text;
  final double? confidence;
}

/// Optional boundary for an offline or platform ink-to-text implementation.
/// The whiteboard, storage, and export engines do not depend on a recognizer.
abstract interface class HandwritingRecognitionService {
  Future<bool> isAvailable();
  Future<HandwritingRecognitionResult> recognize(
    HandwritingRecognitionRequest request,
  );
}

/// Platform-channel adapter for an entirely local recognizer.
///
/// Android ships the Latin ML Kit text model inside the application and
/// rasterizes the selected vector ink for recognition. Windows delegates the
/// original vector strokes to Windows Ink. Neither implementation downloads a
/// model at runtime. Missing platform implementations remain optional so web
/// and other desktop builds do not depend on either native runtime.
final class PlatformHandwritingRecognitionService
    implements HandwritingRecognitionService {
  const PlatformHandwritingRecognitionService({
    MethodChannel channel = const MethodChannel(channelName),
  }) : _channel = channel;

  static const channelName = 'de.flowboardx/handwriting_recognition';
  final MethodChannel _channel;

  @override
  Future<bool> isAvailable() => prepare();

  /// Checks whether the native, offline recognizer can handle [languageTag].
  ///
  /// This method performs no network request and does not install components.
  Future<bool> prepare({String languageTag = 'de-DE'}) async {
    final normalizedTag = languageTag.trim();
    if (normalizedTag.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('ensureModel', {
            'languageTag': normalizedTag,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<HandwritingRecognitionResult> recognize(
    HandwritingRecognitionRequest request,
  ) async {
    if (request.strokes.isEmpty ||
        request.strokes.every((stroke) => stroke.points.isEmpty)) {
      throw const FormatException('Keine Handschrift zur Erkennung vorhanden.');
    }
    Map<Object?, Object?>? response;
    try {
      // The native side also ensures the exact request model. Recognition is
      // therefore race-safe even when callers skip [isAvailable].
      response = await _channel.invokeMapMethod<Object?, Object?>(
        'recognize',
        request.toMap(),
      );
    } on MissingPluginException {
      throw const HandwritingRecognitionUnavailable();
    } on PlatformException catch (error) {
      if (error.code == 'invalid_ink' || error.code == 'no_candidate') {
        throw FormatException(
          error.message ?? 'Die Handschrift wurde nicht erkannt.',
        );
      }
      throw HandwritingRecognitionUnavailable(
        error.message ??
            'Die lokale Handschrifterkennung konnte nicht gestartet werden.',
      );
    }
    final text = response?['text']?.toString().trim() ?? '';
    if (text.isEmpty) {
      throw const FormatException('Die Handschrift wurde nicht erkannt.');
    }
    final confidence = response?['confidence'];
    return HandwritingRecognitionResult(
      text: text,
      confidence: confidence is num
          ? confidence.toDouble().clamp(0.0, 1.0).toDouble()
          : null,
    );
  }
}

final class HandwritingRecognitionUnavailable implements Exception {
  const HandwritingRecognitionUnavailable([
    this.message =
        'Auf diesem System ist keine lokale Handschrifterkennung verfügbar.',
  ]);

  final String message;

  @override
  String toString() => message;
}
