import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:uuid/uuid.dart';

import '../../../domain/model/geometry.dart';
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

/// One immutable, spatially bounded unit of completed live ink.
///
/// A batch contains several bounded vector chunks so a long gesture does not
/// create one render layer per small moving-tail segment. Batches retain
/// identity forever;
/// only the final open batch is replaced when one more chunk is frozen.
@immutable
final class FrozenInkPreviewBatch {
  FrozenInkPreviewBatch._({
    required this.id,
    required this.pointer,
    required Iterable<InkStroke> strokes,
    required this.pointCount,
    required this.worldBounds,
  }) : strokes = List<InkStroke>.unmodifiable(strokes);

  factory FrozenInkPreviewBatch.first({
    required int pointer,
    required int index,
    required InkStroke stroke,
  }) => FrozenInkPreviewBatch._(
    id: 'live-$pointer-batch-$index',
    pointer: pointer,
    strokes: <InkStroke>[stroke],
    pointCount: stroke.points.length,
    worldBounds: stroke.bounds,
  );

  final String id;
  final int pointer;
  final List<InkStroke> strokes;
  final int pointCount;
  final Rect2 worldBounds;

  FrozenInkPreviewBatch append(InkStroke stroke) => FrozenInkPreviewBatch._(
    id: id,
    pointer: pointer,
    strokes: <InkStroke>[...strokes, stroke],
    pointCount: pointCount + stroke.points.length,
    worldBounds: worldBounds.union(stroke.bounds),
  );
}

final class ActiveInkSession {
  ActiveInkSession({
    required this.pointer,
    required this.deviceKind,
    required this.authorId,
    required this.style,
    required this.sampler,
    required this.startedAt,
  });

  final int pointer;
  final PointerDeviceKind deviceKind;
  final String authorId;
  final ActivePenStyle style;
  final StrokeSampler sampler;
  final DateTime startedAt;
  final List<InkStroke> frozenPreviewSegments = <InkStroke>[];
  final List<FrozenInkPreviewBatch> frozenPreviewBatches =
      <FrozenInkPreviewBatch>[];
  int previewStartIndex = 0;
  int _activePreviewCacheStartIndex = -1;
  final List<StrokeSample> _activePreviewSampleCache = <StrokeSample>[];
  final List<InkPoint> _activePreviewPointCache = <InkPoint>[];
  InkStroke? _activePreviewSnapshot;
}

/// Keeps one independent stroke builder per physical pointer. No global
/// "current stroke" exists, so multiple pens can write concurrently.
class InkSessionManager extends ChangeNotifier {
  InkSessionManager({this.maxConcurrentPointers = 16, Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final int maxConcurrentPointers;
  final Uuid _uuid;
  final Map<int, ActiveInkSession> _sessions = <int, ActiveInkSession>{};
  final Stopwatch _activityClock = Stopwatch()..start();
  int? _lastInputActivityMicros;
  List<InkStroke> _frozenPreviewSnapshot = const <InkStroke>[];
  bool _frozenPreviewDirty = false;
  List<FrozenInkPreviewBatch> _frozenBatchSnapshot =
      const <FrozenInkPreviewBatch>[];
  bool _frozenBatchDirty = false;
  int? _scheduledNotificationId;
  SchedulerBinding? _notificationScheduler;
  bool _disposed = false;

  UnmodifiableMapView<int, ActiveInkSession> get sessions =>
      UnmodifiableMapView(_sessions);
  bool get isWriting => _sessions.isNotEmpty;
  bool get hasActiveStylus => _sessions.values.any(
    (session) => session.deviceKind == PointerDeviceKind.stylus,
  );
  bool wasActiveWithin(Duration duration) {
    final last = _lastInputActivityMicros;
    if (last == null || duration.isNegative) return false;
    return _activityClock.elapsedMicroseconds - last <= duration.inMicroseconds;
  }

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
    final startedAt = DateTime.now().toUtc();
    final sampler = StrokeSampler(
      minimumDistance: _minimumScreenDistance,
      // The curvature test still commits earlier on a tight bend. A larger
      // straight-segment ceiling merely removes redundant collinear anchors;
      // it halves the geometry and path work for broad circles without
      // sacrificing the sampler's sub-pixel curve tolerance.
      maximumSegmentLength: _maximumScreenSegmentLength,
      sessionStartedAt: startedAt,
    )..addEvent(event, worldPosition, samplingPosition: samplingPosition);
    _sessions[event.pointer] = ActiveInkSession(
      pointer: event.pointer,
      deviceKind: event.kind,
      authorId: authorId,
      style: style,
      sampler: sampler,
      startedAt: startedAt,
    );
    _markInputActivity();
    _notifyImmediately();
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
    _markInputActivity();
    _freezeCompletePreviewSegments(session);
    _notifyOnNextFrame();
  }

  InkStroke? end(
    PointerEvent event,
    Offset worldPosition, {
    Offset? samplingPosition,
  }) {
    final session = _sessions.remove(event.pointer);
    if (session == null) return null;
    _markInputActivity();
    if (session.frozenPreviewSegments.isNotEmpty) {
      _frozenPreviewDirty = true;
      _frozenBatchDirty = true;
    }
    session.sampler.addEvent(
      event,
      worldPosition,
      samplingPosition: samplingPosition,
    );
    final samples = session.sampler.samples;
    if (samples.isEmpty) {
      _notifyImmediately();
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
    _notifyImmediately();
    return stroke;
  }

  void cancel(int pointer) {
    final removed = _sessions.remove(pointer);
    if (removed == null) return;
    _markInputActivity();
    if (removed.frozenPreviewSegments.isNotEmpty) {
      _frozenPreviewDirty = true;
      _frozenBatchDirty = true;
    }
    _notifyImmediately();
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

  /// Stable repaint units for completed live ink.
  ///
  /// Ordinary MOVE events return the identical outer list. At a chunk boundary
  /// only the final batch for that pointer can change; all sealed batch objects
  /// remain identical and retain their raster/vector caches.
  List<FrozenInkPreviewBatch> buildFrozenPreviewBatches() {
    if (!_frozenBatchDirty) return _frozenBatchSnapshot;
    _frozenBatchSnapshot = List<FrozenInkPreviewBatch>.unmodifiable(
      _sessions.values.expand((session) => session.frozenPreviewBatches),
    );
    _frozenBatchDirty = false;
    return _frozenBatchSnapshot;
  }

  List<InkStroke> buildActivePreviewStrokes() {
    final result = <InkStroke>[];
    for (final session in _sessions.values) {
      final samples = session.sampler.samples;
      if (samples.isEmpty) continue;
      if (session.style.type == InkToolType.straightLine) {
        result.add(
          _previewStroke(
            session,
            samples.length > 1
                ? <StrokeSample>[samples.first, samples.last]
                : <StrokeSample>[samples.first],
            'live-${session.pointer}-line',
          ),
        );
        continue;
      }
      final start = session.previewStartIndex;
      if (start >= samples.length) continue;
      result.add(
        _activePreviewStroke(
          session,
          samples,
          start,
          'live-${session.pointer}-tail-${session.frozenPreviewSegments.length}',
        ),
      );
    }
    return List<InkStroke>.unmodifiable(result);
  }

  InkStroke _activePreviewStroke(
    ActiveInkSession session,
    List<StrokeSample> samples,
    int start,
    String id,
  ) {
    final sampleCache = session._activePreviewSampleCache;
    final pointCache = session._activePreviewPointCache;
    var changed = session._activePreviewCacheStartIndex != start;
    if (changed) {
      session._activePreviewCacheStartIndex = start;
      sampleCache.clear();
      pointCache.clear();
    }

    final pointCount = samples.length - start;
    if (sampleCache.length > pointCount) {
      sampleCache.removeRange(pointCount, sampleCache.length);
      pointCache.removeRange(pointCount, pointCache.length);
      changed = true;
    }
    for (var localIndex = 0; localIndex < pointCount; localIndex++) {
      final sample = samples[start + localIndex];
      if (localIndex < sampleCache.length &&
          identical(sampleCache[localIndex], sample)) {
        continue;
      }
      final point = _inkPointFromSample(sample);
      if (localIndex < sampleCache.length) {
        sampleCache[localIndex] = sample;
        pointCache[localIndex] = point;
      } else {
        sampleCache.add(sample);
        pointCache.add(point);
      }
      changed = true;
    }

    final previous = session._activePreviewSnapshot;
    if (!changed && previous != null && previous.id == id) return previous;
    return session._activePreviewSnapshot = _previewStrokeFromPoints(
      session,
      pointCache,
      id,
    );
  }

  static const double _minimumScreenDistance = .75;
  static const double _maximumScreenSegmentLength = 8;

  /// Only this many mutable points are rebuilt on an ordinary MOVE.
  ///
  /// Completed chunks are immediately frozen into vector pictures. Keeping the
  /// normal/marker tail small bounds UI-thread Path creation even when a broad
  /// circular gesture produces more anchors than a straight line.
  @visibleForTesting
  static const int normalActivePreviewPointLimit = 64;

  @visibleForTesting
  static const int markerActivePreviewPointLimit = 64;

  @visibleForTesting
  static const int dashedActivePreviewPointLimit = 192;

  static const int maxFrozenPreviewBatchSegments = 8;
  static const int maxFrozenPreviewBatchPoints = 1536;
  static const double maxFrozenPreviewBatchWorldExtent = 1536;
  static const double maxFrozenPreviewBatchWorldArea =
      maxFrozenPreviewBatchWorldExtent * maxFrozenPreviewBatchWorldExtent;

  void _freezeCompletePreviewSegments(ActiveInkSession session) {
    if (session.style.type == InkToolType.straightLine) {
      return;
    }
    final samples = session.sampler.samples;
    // Each completed chunk becomes one immutable cached vector picture. The
    // active tail stays bounded, so one more pointer sample never rebuilds the
    // full stroke regardless of how long or circular the gesture becomes.
    final segmentPointCount = switch (session.style.type) {
      InkToolType.dashed => dashedActivePreviewPointLimit,
      InkToolType.marker => markerActivePreviewPointLimit,
      _ => normalActivePreviewPointLimit,
    };
    while (samples.length - session.previewStartIndex > segmentPointCount) {
      final end = session.previewStartIndex + segmentPointCount;
      final preview = _previewStroke(
        session,
        samples.getRange(session.previewStartIndex, end),
        'live-${session.pointer}-segment-${session.frozenPreviewSegments.length}',
      );
      session.frozenPreviewSegments.add(preview);
      _appendFrozenPreviewBatch(session, preview);
      _frozenPreviewDirty = true;
      _frozenBatchDirty = true;
      // Keep one shared endpoint so adjacent cached layers join seamlessly.
      session.previewStartIndex = end - 1;
    }
  }

  void _appendFrozenPreviewBatch(ActiveInkSession session, InkStroke segment) {
    final batches = session.frozenPreviewBatches;
    final last = batches.lastOrNull;
    if (last != null && _canAppendToFrozenBatch(last, segment)) {
      batches[batches.length - 1] = last.append(segment);
      return;
    }
    batches.add(
      FrozenInkPreviewBatch.first(
        pointer: session.pointer,
        index: batches.length,
        stroke: segment,
      ),
    );
  }

  static bool _canAppendToFrozenBatch(
    FrozenInkPreviewBatch batch,
    InkStroke segment,
  ) {
    if (batch.strokes.length >= maxFrozenPreviewBatchSegments ||
        batch.pointCount + segment.points.length >
            maxFrozenPreviewBatchPoints) {
      return false;
    }
    final combined = batch.worldBounds.union(segment.bounds);
    final area = combined.width * combined.height;
    return combined.left.isFinite &&
        combined.top.isFinite &&
        combined.width.isFinite &&
        combined.height.isFinite &&
        area.isFinite &&
        combined.width <= maxFrozenPreviewBatchWorldExtent &&
        combined.height <= maxFrozenPreviewBatchWorldExtent &&
        area <= maxFrozenPreviewBatchWorldArea;
  }

  InkStroke _previewStroke(
    ActiveInkSession session,
    Iterable<StrokeSample> samples,
    String id,
  ) => _previewStrokeFromPoints(session, samples.map(_inkPointFromSample), id);

  InkStroke _previewStrokeFromPoints(
    ActiveInkSession session,
    Iterable<InkPoint> points,
    String id,
  ) => InkStroke(
    id: id,
    pointerId: session.pointer,
    authorId: session.authorId,
    colorArgb: session.style.colorArgb,
    width: _safeWidth(session.style.width),
    type: session.style.type,
    points: points,
    // Preview snapshots are replaced at pointer frequency. Reusing the
    // session timestamp avoids a platform clock read plus DateTime allocation
    // for every moving-tail rebuild.
    createdAt: session.startedAt,
  );

  static InkPoint _inkPointFromSample(StrokeSample sample) => InkPoint(
    x: sample.position.dx,
    y: sample.position.dy,
    pressure: sample.pressure,
    timestampMicros: sample.timestampMicros,
    tiltX: sample.tilt.dx,
    tiltY: sample.tilt.dy,
  );

  static double _safeWidth(double width) =>
      width.isFinite && width > 0 ? width.clamp(.5, 80) : 4;

  void _markInputActivity() {
    _lastInputActivityMicros = _activityClock.elapsedMicroseconds;
  }

  /// Pointer hardware can deliver several accepted samples inside one display
  /// frame. The preview can only be painted once in that frame, so invoking
  /// every widget listener for every packet just repeats `markNeedsBuild` and
  /// becomes visible as CPU pressure on high-rate smartboards.
  void _notifyOnNextFrame() {
    if (_disposed || _scheduledNotificationId != null || !hasListeners) return;
    final scheduler = _schedulerBindingOrNull();
    if (scheduler == null) {
      // Editor-controller tests and headless import/export tools deliberately
      // run without a Flutter binding. They still need correct synchronous
      // state changes, but there is no display frame to coalesce against.
      notifyListeners();
      return;
    }
    _notificationScheduler = scheduler;
    _scheduledNotificationId = scheduler.scheduleFrameCallback((_) {
      _scheduledNotificationId = null;
      _notificationScheduler = null;
      if (!_disposed) notifyListeners();
    });
  }

  /// Session boundaries stay synchronous. In particular, ending a stroke must
  /// remove its live preview in the same transaction that publishes the
  /// persisted stroke. Any older scheduled MOVE notification is redundant.
  void _notifyImmediately() {
    if (_disposed) return;
    final scheduled = _scheduledNotificationId;
    if (scheduled != null) {
      _notificationScheduler?.cancelFrameCallbackWithId(scheduled);
      _scheduledNotificationId = null;
      _notificationScheduler = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final scheduled = _scheduledNotificationId;
    if (scheduled != null) {
      _notificationScheduler?.cancelFrameCallbackWithId(scheduled);
      _scheduledNotificationId = null;
      _notificationScheduler = null;
    }
    _sessions.clear();
    _frozenPreviewSnapshot = const <InkStroke>[];
    _frozenBatchSnapshot = const <FrozenInkPreviewBatch>[];
    super.dispose();
  }

  SchedulerBinding? _schedulerBindingOrNull() {
    try {
      return SchedulerBinding.instance;
    } on FlutterError {
      return null;
    } on TypeError {
      // In release mode BindingBase's debug assertion is absent and the
      // nullable singleton is guarded by a null assertion instead.
      return null;
    }
  }
}
