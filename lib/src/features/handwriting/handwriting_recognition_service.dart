import 'dart:async';
import 'dart:math' as math;

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

  bool get exceedsPlatformStrokeLimit =>
      strokes
          .where((stroke) => stroke.points.any(_isSerializablePoint))
          .take(maximumChannelStrokeCount + 1)
          .length >
      maximumChannelStrokeCount;

  /// Serializes a bounded, turn-preserving representation for the platform
  /// channel. Dense SMART Board packets can otherwise allocate hundreds of
  /// thousands of nested maps on the UI isolate before Android gets a chance
  /// to apply its own defensive limit.
  Map<String, Object?> toMap() {
    final validPointCounts = <int>[
      for (final stroke in strokes)
        stroke.points.where(_isSerializablePoint).length,
    ];
    final desiredPointCounts = <int>[
      for (final count in validPointCounts)
        count.clamp(0, maximumChannelPointsPerStroke),
    ];
    final desiredSuffix = List<int>.filled(desiredPointCounts.length + 1, 0);
    final nonEmptySuffix = List<int>.filled(desiredPointCounts.length + 1, 0);
    for (var index = desiredPointCounts.length - 1; index >= 0; index--) {
      desiredSuffix[index] =
          desiredSuffix[index + 1] + desiredPointCounts[index];
      nonEmptySuffix[index] =
          nonEmptySuffix[index + 1] + (desiredPointCounts[index] > 0 ? 1 : 0);
    }
    var remaining = maximumChannelPointCount;
    final serializedStrokes = <Map<String, Object?>>[];
    for (var strokeIndex = 0; strokeIndex < strokes.length; strokeIndex++) {
      if (remaining <= 0) break;
      final stroke = strokes[strokeIndex];
      final validPointCount = validPointCounts[strokeIndex];
      final desired = desiredPointCounts[strokeIndex];
      if (desired == 0) continue;
      final remainingDesired = desiredSuffix[strokeIndex];
      final remainingNonEmpty = nonEmptySuffix[strokeIndex + 1];
      final proportionalBudget = remainingDesired <= remaining
          ? desired
          : (remaining * desired ~/ remainingDesired)
                .clamp(1, math.max(1, remaining - remainingNonEmpty))
                .toInt();
      final points = _boundedPoints(
        stroke.points,
        math.min(desired, proportionalBudget),
        validPointCount: validPointCount,
      );
      if (points.isEmpty) continue;
      remaining -= points.length;
      final coordinates = Float32List(points.length * 2);
      for (var pointIndex = 0; pointIndex < points.length; pointIndex++) {
        final point = points[pointIndex];
        coordinates[pointIndex * 2] = point.x;
        coordinates[pointIndex * 2 + 1] = point.y;
      }
      final timestampsMicros = _safeTimestamps(points);
      serializedStrokes.add(<String, Object?>{
        'id': stroke.id,
        'coordinates': coordinates,
        'timestampsMicros': ?timestampsMicros,
      });
    }
    return <String, Object?>{
      'languageTag': languageTag,
      'strokes': serializedStrokes,
    };
  }

  @visibleForTesting
  static const int maximumChannelPointCount = 20000;

  @visibleForTesting
  static const int maximumChannelPointsPerStroke = 6000;

  @visibleForTesting
  static const int maximumChannelStrokeCount = 4096;

  static List<InkPoint> _boundedPoints(
    List<InkPoint> source,
    int maximum, {
    required int validPointCount,
  }) {
    final valid = validPointCount == source.length
        ? source
        : source.where(_isSerializablePoint).toList(growable: false);
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
      var selectedImportance = -1.0;
      final chordStart = valid[start - 1];
      final chordEnd = valid[math.min(valid.length - 1, endExclusive)];
      final chordX = chordEnd.x - chordStart.x;
      final chordY = chordEnd.y - chordStart.y;
      final chordLength = math.sqrt(chordX * chordX + chordY * chordY);
      for (var index = start; index < endExclusive; index++) {
        final previous = valid[index - 1];
        final current = valid[index];
        final next = valid[index + 1];
        final firstX = current.x - previous.x;
        final firstY = current.y - previous.y;
        final secondX = next.x - current.x;
        final secondY = next.y - current.y;
        final firstLength = math.sqrt(firstX * firstX + firstY * firstY);
        final secondLength = math.sqrt(secondX * secondX + secondY * secondY);
        final normalizedTurn = firstLength <= 1e-9 || secondLength <= 1e-9
            ? 0.0
            : (firstX * secondY - firstY * secondX).abs() /
                  (firstLength * secondLength);
        final chordDistance = chordLength <= 1e-9
            ? math.sqrt(
                math.pow(current.x - chordStart.x, 2) +
                    math.pow(current.y - chordStart.y, 2),
              )
            : ((current.x - chordStart.x) * chordY -
                          (current.y - chordStart.y) * chordX)
                      .abs() /
                  chordLength;
        // Normalize both terms. The previous raw cross product strongly
        // preferred long Smartboard packets and could discard a tight loop or
        // corner made from short, densely sampled segments.
        final importance =
            normalizedTurn +
            chordDistance / math.max(1.0, chordLength) +
            (index == start || index == endExclusive - 1 ? 1e-6 : 0);
        if (importance > selectedImportance) {
          selectedImportance = importance;
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

  static Int64List? _safeTimestamps(List<InkPoint> points) {
    if (points.every((point) => point.timestampMicros == 0)) return null;
    for (final point in points) {
      final timestamp = point.timestampMicros;
      if (timestamp < _minimumInt64 || timestamp > _maximumInt64) return null;
    }
    return Int64List.fromList(<int>[
      for (final point in points) point.timestampMicros,
    ]);
  }

  static const int _minimumInt64 = -0x8000000000000000;
  static const int _maximumInt64 = 0x7FFFFFFFFFFFFFFF;
}

@immutable
final class HandwritingRecognitionResult {
  const HandwritingRecognitionResult({
    required this.text,
    this.confidence,
    this.engine,
    this.modelDelivery,
    this.attemptCount,
    this.lineCountHint,
    this.wordCountHint,
    this.durationMillis,
    this.timedOut = false,
  }) : status = HandwritingRecognitionStatus.recognized,
       message = null;

  const HandwritingRecognitionResult.notRecognized({
    this.message,
    this.engine,
    this.modelDelivery,
    this.attemptCount,
    this.lineCountHint,
    this.wordCountHint,
    this.durationMillis,
    this.timedOut = false,
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
  final int? lineCountHint;
  final int? wordCountHint;
  final int? durationMillis;
  final bool timedOut;

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
    this.ensureModelTimeout = defaultEnsureModelTimeout,
    this.recognitionTimeout = defaultRecognitionTimeout,
  }) : _channel = channel;

  static const channelName = 'de.flowboardx/handwriting_recognition';
  static const defaultEnsureModelTimeout = Duration(seconds: 5);
  static const defaultRecognitionTimeout = Duration(seconds: 35);
  @visibleForTesting
  static const maximumRecognizedTextLength = 4096;
  final MethodChannel _channel;
  final Duration ensureModelTimeout;
  final Duration recognitionTimeout;

  @override
  Future<bool> isAvailable() => prepare();

  /// Checks whether the native, offline recognizer can handle [languageTag].
  ///
  /// This method performs no network request and does not install components.
  Future<bool> prepare({String languageTag = 'de-DE'}) async {
    final normalizedTag = languageTag.trim();
    if (normalizedTag.isEmpty) return false;
    try {
      return await _channel
              .invokeMethod<bool>('ensureModel', {'languageTag': normalizedTag})
              .timeout(
                _positiveTimeout(ensureModelTimeout, defaultEnsureModelTimeout),
              ) ??
          false;
    } on TimeoutException catch (error, stackTrace) {
      const failure = HandwritingRecognitionFailure(
        HandwritingRecognitionFailureKind.engineFailure,
        'Die eingebettete Handschrifterkennung hat beim Start nicht '
        'rechtzeitig geantwortet.',
      );
      _recordFailure(error, stackTrace);
      throw failure;
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
    if (request.exceedsPlatformStrokeLimit) {
      const result = HandwritingRecognitionResult.notRecognized(
        message:
            'Die Auswahl enthält zu viele einzelne Striche. '
            'Bitte ein Wort, eine Zeile oder einen kleineren Bereich markieren.',
      );
      _recordNotRecognized(result);
      return result;
    }
    Map<Object?, Object?>? response;
    try {
      // The native side also ensures the exact request model. Recognition is
      // therefore race-safe even when callers skip [isAvailable].
      response = await _channel
          .invokeMapMethod<Object?, Object?>('recognize', request.toMap())
          .timeout(
            _positiveTimeout(recognitionTimeout, defaultRecognitionTimeout),
          );
    } on TimeoutException catch (error, stackTrace) {
      const failure = HandwritingRecognitionFailure(
        HandwritingRecognitionFailureKind.engineFailure,
        'Die lokale Handschrifterkennung hat das Zeitlimit überschritten.',
      );
      _recordFailure(error, stackTrace);
      throw failure;
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
    } on FormatException catch (error, stackTrace) {
      final failure = HandwritingRecognitionFailure(
        HandwritingRecognitionFailureKind.invalidResponse,
        'Die lokale Erkennung hat unlesbare Antwortdaten geliefert: '
        '${error.message}',
      );
      _recordFailure(failure, stackTrace);
      throw failure;
    } on TypeError catch (error, stackTrace) {
      const failure = HandwritingRecognitionFailure(
        HandwritingRecognitionFailureKind.invalidResponse,
        'Die lokale Erkennung hat unerwartete Antwortdaten geliefert.',
      );
      _recordFailure(error, stackTrace);
      throw failure;
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
    final lineCountHint = _boundedDiagnosticInteger(
      response['lineCountHint'],
      maximum: 100,
    );
    final wordCountHint = _boundedDiagnosticInteger(
      response['wordCountHint'],
      maximum: 1000,
    );
    final durationMillis = _boundedDiagnosticInteger(
      response['durationMillis'],
      maximum: 120000,
    );
    final timedOut = response['timedOut'] == true;
    final text = response['text'] is String
        ? (response['text']! as String).trim()
        : '';
    if (text.length > maximumRecognizedTextLength) {
      const failure = HandwritingRecognitionFailure(
        HandwritingRecognitionFailureKind.invalidResponse,
        'Die lokale Erkennung hat einen unerwartet langen Text geliefert.',
      );
      _recordFailure(failure, StackTrace.current);
      throw failure;
    }
    if (status == 'recognized' && text.isEmpty) {
      const failure = HandwritingRecognitionFailure(
        HandwritingRecognitionFailureKind.invalidResponse,
        'Die lokale Erkennung hat einen Treffer ohne Text geliefert.',
      );
      _recordFailure(failure, StackTrace.current);
      throw failure;
    }
    if (status == 'notRecognized' || (status == null && text.isEmpty)) {
      final result = HandwritingRecognitionResult.notRecognized(
        message:
            response['message']?.toString() ??
            'Die Handschrift wurde nicht sicher erkannt.',
        engine: engine,
        modelDelivery: modelDelivery,
        attemptCount: attemptCount,
        lineCountHint: lineCountHint,
        wordCountHint: wordCountHint,
        durationMillis: durationMillis,
        timedOut: timedOut,
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
    final confidence = response['confidence'];
    final result = HandwritingRecognitionResult(
      text: text,
      engine: engine,
      modelDelivery: modelDelivery,
      attemptCount: attemptCount,
      lineCountHint: lineCountHint,
      wordCountHint: wordCountHint,
      durationMillis: durationMillis,
      timedOut: timedOut,
      confidence: confidence is num && confidence.toDouble().isFinite
          ? confidence.toDouble().clamp(0.0, 1.0).toDouble()
          : null,
    );
    _recordRecognized(
      result,
      inputStrokeCount: request.strokes.length,
      inputPointCount: request.strokes.fold<int>(
        0,
        (total, stroke) => total + stroke.points.length,
      ),
    );
    return result;
  }

  static void _recordRecognized(
    HandwritingRecognitionResult result, {
    required int inputStrokeCount,
    required int inputPointCount,
  }) {
    DiagnosticLogService.instance.info(
      'recognition.recognized',
      fields: <String, Object?>{
        'platform': defaultTargetPlatform.name,
        'engine': result.engine ?? 'unknown',
        'model_delivery': result.modelDelivery ?? 'unknown',
        'input_stroke_count': inputStrokeCount,
        'input_point_count': inputPointCount,
        if (result.confidence != null) 'confidence': result.confidence,
        if (result.attemptCount != null) 'attempt_count': result.attemptCount,
        if (result.lineCountHint != null)
          'line_count_hint': result.lineCountHint,
        if (result.wordCountHint != null)
          'word_count_hint': result.wordCountHint,
        if (result.durationMillis != null) 'duration_ms': result.durationMillis,
        'timed_out': result.timedOut,
      },
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
        if (result.lineCountHint != null)
          'line_count_hint': result.lineCountHint,
        if (result.wordCountHint != null)
          'word_count_hint': result.wordCountHint,
        if (result.durationMillis != null) 'duration_ms': result.durationMillis,
        'timed_out': result.timedOut,
      },
    );
  }

  static int? _boundedDiagnosticInteger(Object? value, {required int maximum}) {
    if (value is! num || !value.isFinite) return null;
    return value.toInt().clamp(0, maximum).toInt();
  }

  static Duration _positiveTimeout(Duration configured, Duration fallback) =>
      configured > Duration.zero ? configured : fallback;

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
