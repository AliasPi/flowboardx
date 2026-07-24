import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../diagnostics/diagnostics.dart';
import '../../domain/model/ink.dart';

@immutable
final class HandwritingRecognitionRequest {
  HandwritingRecognitionRequest({
    required Iterable<InkStroke> strokes,
    this.languageTag = 'de-DE',
  }) : strokes = List<InkStroke>.unmodifiable(strokes);

  final List<InkStroke> strokes;
  final String languageTag;

  bool get hasSerializableInk =>
      strokes.any((stroke) => stroke.points.any(_isSerializablePoint));

  /// Serializes a bounded, turn-preserving representation for the platform
  /// channel. Dense SMART Board packets can otherwise allocate hundreds of
  /// thousands of nested maps on the UI isolate before Android gets a chance
  /// to apply its own defensive limit.
  Map<String, Object?> toMap() {
    final nonEmptyStrokeCount = strokes
        .where((stroke) => stroke.points.any(_isSerializablePoint))
        .length;
    final perStrokeBudget = nonEmptyStrokeCount == 0
        ? 1
        : (maximumChannelPointCount ~/ nonEmptyStrokeCount).clamp(
            2,
            maximumChannelPointsPerStroke,
          );
    var remaining = maximumChannelPointCount;
    final serializedStrokes = <Map<String, Object?>>[];
    for (final stroke in strokes) {
      if (remaining <= 0) break;
      final points = _boundedPoints(
        stroke.points,
        perStrokeBudget.clamp(1, remaining),
      );
      if (points.isEmpty) continue;
      remaining -= points.length;
      serializedStrokes.add(<String, Object?>{
        'id': stroke.id,
        'points': <Map<String, Object?>>[
          for (final point in points)
            <String, Object?>{
              'x': point.x,
              'y': point.y,
              'timestampMicros': point.timestampMicros,
            },
        ],
      });
    }
    return <String, Object?>{
      'languageTag': languageTag,
      'strokes': serializedStrokes,
    };
  }

  @visibleForTesting
  static const int maximumChannelPointCount = 80000;

  @visibleForTesting
  static const int maximumChannelPointsPerStroke = 12000;

  static List<InkPoint> _boundedPoints(List<InkPoint> source, int maximum) {
    final valid = source.where(_isSerializablePoint).toList(growable: false);
    if (valid.length <= maximum) return valid;
    if (maximum <= 1) return <InkPoint>[valid.first];
    if (maximum == 2) return <InkPoint>[valid.first, valid.last];

    final result = <InkPoint>[valid.first];
    final interiorCount = valid.length - 2;
    final bucketCount = maximum - 2;
    for (var bucket = 0; bucket < bucketCount; bucket++) {
      final start =
          1 +
          (bucket * interiorCount / bucketCount)
              .floor()
              .clamp(0, interiorCount - 1)
              .toInt();
      final endExclusive =
          1 +
          (((bucket + 1) * interiorCount / bucketCount).ceil())
              .clamp(1, interiorCount)
              .toInt();
      var selectedIndex = start;
      var selectedTurn = -1.0;
      for (var index = start; index < endExclusive; index++) {
        final previous = valid[index - 1];
        final current = valid[index];
        final next = valid[index + 1];
        final firstX = current.x - previous.x;
        final firstY = current.y - previous.y;
        final secondX = next.x - current.x;
        final secondY = next.y - current.y;
        final turn = (firstX * secondY - firstY * secondX).abs();
        if (turn > selectedTurn) {
          selectedTurn = turn;
          selectedIndex = index;
        }
      }
      final selected = valid[selectedIndex];
      if (!identical(selected, result.last)) result.add(selected);
    }
    if (!identical(result.last, valid.last)) result.add(valid.last);
    return result;
  }

  static bool _isSerializablePoint(InkPoint point) =>
      point.x.isFinite &&
      point.y.isFinite &&
      point.x.abs() <= 10000000 &&
      point.y.abs() <= 10000000;
}

@immutable
final class HandwritingRecognitionResult {
  const HandwritingRecognitionResult({
    required this.text,
    this.confidence,
    this.engine,
    this.modelDelivery,
    this.attemptCount,
  }) : status = HandwritingRecognitionStatus.recognized,
       message = null;

  const HandwritingRecognitionResult.notRecognized({
    this.message,
    this.engine,
    this.modelDelivery,
    this.attemptCount,
  }) : text = '',
       confidence = null,
       status = HandwritingRecognitionStatus.notRecognized;

  final String text;
  final double? confidence;
  final HandwritingRecognitionStatus status;
  final String? message;
  final String? engine;

  /// How the native model reached the device, for diagnostics only.
  ///
  /// Android reports `bundled-apk`; no handwriting, recognized text, or local
  /// path is included in this metadata.
  final String? modelDelivery;
  final int? attemptCount;

  bool get isRecognized =>
      status == HandwritingRecognitionStatus.recognized && text.isNotEmpty;
}

enum HandwritingRecognitionStatus { recognized, notRecognized }

enum HandwritingRecognitionFailureKind {
  invalidInput,
  invalidResponse,
  engineFailure,
}

/// A technical recognition failure. Ordinary, valid handwriting for which no
/// candidate is found is represented by [HandwritingRecognitionResult]
/// instead, so UI code never exposes a misleading `FormatException`.
final class HandwritingRecognitionFailure implements Exception {
  const HandwritingRecognitionFailure(this.kind, this.message);

  final HandwritingRecognitionFailureKind kind;
  final String message;

  @override
  String toString() => message;
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
    if (!request.hasSerializableInk) {
      const result = HandwritingRecognitionResult.notRecognized(
        message: 'Keine Handschrift zur Erkennung vorhanden.',
      );
      _recordNotRecognized(result);
      return result;
    }
    Map<Object?, Object?>? response;
    try {
      // The native side also ensures the exact request model. Recognition is
      // therefore race-safe even when callers skip [isAvailable].
      response = await _channel.invokeMapMethod<Object?, Object?>(
        'recognize',
        request.toMap(),
      );
    } on MissingPluginException catch (error, stackTrace) {
      _recordFailure(error, stackTrace);
      throw const HandwritingRecognitionUnavailable();
    } on PlatformException catch (error, stackTrace) {
      if (error.code == 'no_candidate') {
        final result = HandwritingRecognitionResult.notRecognized(
          message: error.message ?? 'Die Handschrift wurde nicht erkannt.',
          engine: 'legacyPlatform',
        );
        _recordNotRecognized(result);
        return result;
      }
      if (error.code == 'invalid_ink' || error.code == 'invalid_language') {
        final failure = HandwritingRecognitionFailure(
          HandwritingRecognitionFailureKind.invalidInput,
          error.message ?? 'Die Handschriftdaten sind ungültig.',
        );
        _recordFailure(failure, stackTrace);
        throw failure;
      }
      if (error.code == 'recognition_failed') {
        final failure = HandwritingRecognitionFailure(
          HandwritingRecognitionFailureKind.engineFailure,
          error.message ?? 'Die lokale Erkennung ist fehlgeschlagen.',
        );
        _recordFailure(failure, stackTrace);
        throw failure;
      }
      final unavailable = HandwritingRecognitionUnavailable(
        error.message ??
            'Die lokale Handschrifterkennung konnte nicht gestartet werden.',
      );
      _recordFailure(unavailable, stackTrace);
      throw unavailable;
    }
    if (response == null) {
      const failure = HandwritingRecognitionFailure(
        HandwritingRecognitionFailureKind.invalidResponse,
        'Die lokale Erkennung hat keine gültige Antwort geliefert.',
      );
      _recordFailure(failure, StackTrace.current);
      throw failure;
    }
    final status = response['status']?.toString();
    final engine = response['engine'] is String
        ? response['engine']! as String
        : null;
    final modelDelivery = response['modelDelivery'] is String
        ? response['modelDelivery']! as String
        : null;
    final rawAttempts = response['attempts'];
    final attemptCount = rawAttempts is num && rawAttempts.isFinite
        ? rawAttempts.toInt().clamp(0, 100).toInt()
        : null;
    final text = response['text'] is String
        ? (response['text']! as String).trim()
        : '';
    if (status == 'notRecognized' || (status == null && text.isEmpty)) {
      final result = HandwritingRecognitionResult.notRecognized(
        message:
            response['message']?.toString() ??
            'Die Handschrift wurde nicht sicher erkannt.',
        engine: engine,
        modelDelivery: modelDelivery,
        attemptCount: attemptCount,
      );
      _recordNotRecognized(result);
      return result;
    }
    if (status != null && status != 'recognized') {
      const failure = HandwritingRecognitionFailure(
        HandwritingRecognitionFailureKind.invalidResponse,
        'Die lokale Erkennung hat einen unbekannten Status geliefert.',
      );
      _recordFailure(failure, StackTrace.current);
      throw failure;
    }
    if (text.isEmpty) {
      const result = HandwritingRecognitionResult.notRecognized(
        message: 'Die Handschrift wurde nicht sicher erkannt.',
      );
      _recordNotRecognized(result);
      return result;
    }
    final confidence = response['confidence'];
    return HandwritingRecognitionResult(
      text: text,
      engine: engine,
      modelDelivery: modelDelivery,
      attemptCount: attemptCount,
      confidence: confidence is num && confidence.toDouble().isFinite
          ? confidence.toDouble().clamp(0.0, 1.0).toDouble()
          : null,
    );
  }

  static void _recordNotRecognized(HandwritingRecognitionResult result) {
    DiagnosticLogService.instance.warning(
      'recognition.not_recognized',
      fields: <String, Object?>{
        'platform': defaultTargetPlatform.name,
        'engine': result.engine ?? 'unknown',
        'model_delivery': result.modelDelivery ?? 'unknown',
        if (result.attemptCount != null) 'attempt_count': result.attemptCount,
      },
    );
  }

  static void _recordFailure(Object error, StackTrace stackTrace) {
    DiagnosticLogService.instance.recordException(
      event: 'recognition.failure',
      error: error,
      stackTrace: stackTrace,
      fields: <String, Object?>{'platform': defaultTargetPlatform.name},
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
