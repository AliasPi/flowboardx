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
    required this.deviceKind,
    required this.authorId,
    required this.style,
    required this.sampler,
  });

  final int pointer;
  final PointerDeviceKind deviceKind;
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
  List<InkStroke> _frozenPreviewSnapshot = const <InkStroke>[];
  bool _frozenPreviewDirty = false;

  UnmodifiableMapView<int, ActiveInkSession> get sessions =>
      UnmodifiableMapView(_sessions);
  bool get isWriting => _sessions.isNotEmpty;
  bool get hasActiveStylus => _sessions.values.any(
    (session) => session.deviceKind == PointerDeviceKind.stylus,
  );

  bool begin({
    required PointerDownEvent event,
    required Offset worldPosition,
    required ActivePenStyle style,
    required String authorId,
    Offset? samplingPosition,
  }) {
    if (_sessions.length >= maxConcurrentPointers ||
        _sessions.containsKey(event.pointer)) {
      return false;
    }
    final sampler = StrokeSampler(minimumDistance: _minimumScreenDistance)
      ..addEvent(event, worldPosition, samplingPosition: samplingPosition);
    _sessions[event.pointer] = ActiveInkSession(
      pointer: event.pointer,
      deviceKind: event.kind,
      authorId: authorId,
      style: style,
      sampler: sampler,
    );
    notifyListeners();
    return true;
  }

  void update(
    PointerMoveEvent event,
    Offset worldPosition, {
    Offset? samplingPosition,
  }) {
    final session = _sessions[event.pointer];
    if (session == null) return;
    if (!session.sampler.addEvent(
      event,
      worldPosition,
      samplingPosition: samplingPosition,
    )) {
      return;
    }
    _freezeCompletePreviewSegments(session);
    notifyListeners();
  }

  InkStroke? end(
    PointerEvent event,
    Offset worldPosition, {
    Offset? samplingPosition,
  }) {
    final session = _sessions.remove(event.pointer);
    if (session == null) return null;
    if (session.frozenPreviewSegments.isNotEmpty) {
      _frozenPreviewDirty = true;
    }
    session.sampler.addEvent(
      event,
      worldPosition,
      samplingPosition: samplingPosition,
    );
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
    final removed = _sessions.remove(pointer);
    if (removed == null) return;
    if (removed.frozenPreviewSegments.isNotEmpty) {
      _frozenPreviewDirty = true;
    }
    notifyListeners();
  }

  List<InkStroke> buildPreviewStrokes() => <InkStroke>[
    ...buildFrozenPreviewStrokes(),
    ...buildActivePreviewStrokes(),
  ];

  /// Immutable chunks change only after a segment boundary, pointer end or
  /// cancellation. Returning the same outer list between those events lets the
  /// frozen RepaintBoundary stay untouched for ordinary pointer updates.
  List<InkStroke> buildFrozenPreviewStrokes() {
    if (!_frozenPreviewDirty) return _frozenPreviewSnapshot;
    _frozenPreviewSnapshot = List<InkStroke>.unmodifiable(
      _sessions.values.expand((session) => session.frozenPreviewSegments),
    );
    _frozenPreviewDirty = false;
    return _frozenPreviewSnapshot;
  }

  List<InkStroke> buildActivePreviewStrokes() => _sessions.values
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
          if (tail.isNotEmpty)
            _previewStroke(
              session,
              tail,
              'live-${session.pointer}-tail-${session.frozenPreviewSegments.length}',
            ),
        ];
      })
      .toList(growable: false);

  static const double _minimumScreenDistance = .75;
  static const int _previewSegmentPointCount = 192;
  static const int _markerPreviewSegmentPointCount = 192;
  static const int _dashedPreviewSegmentPointCount = 512;

  void _freezeCompletePreviewSegments(ActiveInkSession session) {
    if (session.style.type == InkToolType.straightLine) {
      return;
    }
    final samples = session.sampler.samples;
    // Each completed chunk becomes one immutable cached vector picture. The
    // active tail stays bounded, so one more pointer sample never rebuilds the
    // full stroke regardless of how long or circular the gesture becomes.
    final segmentPointCount = switch (session.style.type) {
      InkToolType.dashed => _dashedPreviewSegmentPointCount,
      InkToolType.marker => _markerPreviewSegmentPointCount,
      _ => _previewSegmentPointCount,
    };
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
      _frozenPreviewDirty = true;
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
