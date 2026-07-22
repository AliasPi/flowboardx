import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:uuid/uuid.dart';

import '../../../domain/model/ink.dart';
import 'stroke_sampler.dart';

@immutable
class ActivePenStyle {
  const ActivePenStyle({
    this.colorArgb = 0xFF000000,
    this.width = 4,
    this.type = InkToolType.normal,
  });

  final int colorArgb;
  final double width;
  final InkToolType type;

  ActivePenStyle copyWith({int? colorArgb, double? width, InkToolType? type}) =>
      ActivePenStyle(
        colorArgb: colorArgb ?? this.colorArgb,
        width: width ?? this.width,
        type: type ?? this.type,
      );
}

final class ActiveInkSession {
  ActiveInkSession({
    required this.pointer,
    required this.authorId,
    required this.style,
    required this.sampler,
  });

  final int pointer;
  final String authorId;
  final ActivePenStyle style;
  final StrokeSampler sampler;
  final List<InkStroke> frozenPreviewSegments = <InkStroke>[];
  int previewStartIndex = 0;
}

/// Keeps one independent stroke builder per physical pointer. No global
/// "current stroke" exists, so multiple pens can write concurrently.
class InkSessionManager extends ChangeNotifier {
  InkSessionManager({this.maxConcurrentPointers = 16, Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final int maxConcurrentPointers;
  final Uuid _uuid;
  final Map<int, ActiveInkSession> _sessions = <int, ActiveInkSession>{};

  UnmodifiableMapView<int, ActiveInkSession> get sessions =>
      UnmodifiableMapView(_sessions);
  bool get isWriting => _sessions.isNotEmpty;

  bool begin({
    required PointerDownEvent event,
    required Offset worldPosition,
    required ActivePenStyle style,
    required String authorId,
  }) {
    if (_sessions.length >= maxConcurrentPointers ||
        _sessions.containsKey(event.pointer)) {
      return false;
    }
    final sampler = StrokeSampler()..addEvent(event, worldPosition);
    _sessions[event.pointer] = ActiveInkSession(
      pointer: event.pointer,
      authorId: authorId,
      style: style,
      sampler: sampler,
    );
    notifyListeners();
    return true;
  }

  void update(PointerMoveEvent event, Offset worldPosition) {
    final session = _sessions[event.pointer];
    if (session == null) return;
    session.sampler.addEvent(event, worldPosition);
    _freezeCompletePreviewSegments(session);
    notifyListeners();
  }

  InkStroke? end(PointerEvent event, Offset worldPosition) {
    final session = _sessions.remove(event.pointer);
    if (session == null) return null;
    session.sampler.addEvent(event, worldPosition);
    final samples = session.sampler.samples;
    if (samples.isEmpty) {
      notifyListeners();
      return null;
    }
    final selectedSamples =
        session.style.type == InkToolType.straightLine && samples.length > 1
        ? [samples.first, samples.last]
        : samples;
    final stroke = InkStroke(
      id: _uuid.v4(),
      pointerId: session.pointer,
      authorId: session.authorId,
      colorArgb: session.style.colorArgb,
      width: _safeWidth(session.style.width),
      type: session.style.type,
      points: selectedSamples.map(
        (sample) => InkPoint(
          x: sample.position.dx,
          y: sample.position.dy,
          pressure: sample.pressure,
          timestampMicros: sample.timestampMicros,
          tiltX: sample.tilt.dx,
          tiltY: sample.tilt.dy,
        ),
      ),
    );
    notifyListeners();
    return stroke;
  }

  void cancel(int pointer) {
    if (_sessions.remove(pointer) != null) notifyListeners();
  }

  List<InkStroke> buildPreviewStrokes() => _sessions.values
      .expand((session) {
        final samples = session.sampler.samples;
        if (samples.isEmpty) return const <InkStroke>[];
        if (session.style.type == InkToolType.straightLine) {
          final selected = samples.length > 1
              ? <StrokeSample>[samples.first, samples.last]
              : <StrokeSample>[samples.first];
          return <InkStroke>[
            _previewStroke(session, selected, 'live-${session.pointer}-line'),
          ];
        }
        final tail = samples.sublist(session.previewStartIndex);
        return <InkStroke>[
          ...session.frozenPreviewSegments,
          if (tail.isNotEmpty)
            _previewStroke(
              session,
              tail,
              'live-${session.pointer}-tail-${session.frozenPreviewSegments.length}',
            ),
        ];
      })
      .toList(growable: false);

  static const int _previewSegmentPointCount = 64;
  static const int _dashedPreviewSegmentPointCount = 512;

  void _freezeCompletePreviewSegments(ActiveInkSession session) {
    if (session.style.type == InkToolType.straightLine ||
        session.style.type == InkToolType.marker) {
      return;
    }
    final samples = session.sampler.samples;
    // Dashed segments are converted to one bounded Path per preview stroke.
    // Larger frozen chunks keep a long gesture from creating hundreds of
    // CustomPaint/RepaintBoundary children while retaining incremental paints.
    final segmentPointCount = session.style.type == InkToolType.dashed
        ? _dashedPreviewSegmentPointCount
        : _previewSegmentPointCount;
    while (samples.length - session.previewStartIndex > segmentPointCount) {
      final end = session.previewStartIndex + segmentPointCount;
      final segment = samples.sublist(session.previewStartIndex, end);
      session.frozenPreviewSegments.add(
        _previewStroke(
          session,
          segment,
          'live-${session.pointer}-segment-${session.frozenPreviewSegments.length}',
        ),
      );
      // Keep one shared endpoint so adjacent cached layers join seamlessly.
      session.previewStartIndex = end - 1;
    }
  }

  InkStroke _previewStroke(
    ActiveInkSession session,
    Iterable<StrokeSample> samples,
    String id,
  ) => InkStroke(
    id: id,
    pointerId: session.pointer,
    authorId: session.authorId,
    colorArgb: session.style.colorArgb,
    width: _safeWidth(session.style.width),
    type: session.style.type,
    points: samples.map(
      (sample) => InkPoint(
        x: sample.position.dx,
        y: sample.position.dy,
        pressure: sample.pressure,
        timestampMicros: sample.timestampMicros,
        tiltX: sample.tilt.dx,
        tiltY: sample.tilt.dy,
      ),
    ),
  );

  static double _safeWidth(double width) =>
      width.isFinite && width > 0 ? width.clamp(.5, 80) : 4;
}
