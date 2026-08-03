import 'dart:collection';
import 'dart:ui';

/// Prevents one physical touch sequence from owning both a non-destructive
/// selection interaction and a delayed destructive native palm replay.
///
/// Android may classify a contact as `TOOL_TYPE_PALM` only after Flutter has
/// already received DOWN/MOVE packets. Native palm traces therefore arrive on
/// a side channel, often around UP/CANCEL. Pointer ids are not shared across
/// those channels, so ownership is matched using their monotonic timestamps
/// and global-coordinate path envelopes.
final class TouchInteractionOwnershipGate {
  TouchInteractionOwnershipGate({
    this.temporalTolerance = const Duration(milliseconds: 140),
    this.recentRetention = const Duration(seconds: 5),
    this.fallbackRetention = const Duration(milliseconds: 900),
    this.spatialTolerance = 30,
    this.maximumRecentTraces = 24,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration temporalTolerance;
  final Duration recentRetention;
  final Duration fallbackRetention;
  final double spatialTolerance;
  final int maximumRecentTraces;
  final DateTime Function() _clock;

  final Map<int, _OwnedTouchTrace> _active = <int, _OwnedTouchTrace>{};
  final ListQueue<_OwnedTouchTrace> _recent = ListQueue<_OwnedTouchTrace>();

  bool get hasActiveSelectionOwnership =>
      _active.values.any((trace) => trace.selectionOwned);

  bool isSelectionOwned(int pointer) =>
      _active[pointer]?.selectionOwned == true;

  void observeDown({
    required int pointer,
    required Offset globalPosition,
    required Duration timeStamp,
  }) {
    if (!_isFinite(globalPosition)) return;
    _prune();
    final existing = _active[pointer];
    if (existing != null) {
      // The hit-tested board route and the global route have no guaranteed
      // ordering. A selection can claim the pointer before the global DOWN is
      // observed; processing that same DOWN must never replace the claimed
      // trace with a fresh unowned one.
      existing
        ..bounds = existing.bounds.expandToInclude(_pointBounds(globalPosition))
        ..append(globalPosition)
        ..lastTimeStamp = timeStamp
        ..lastObservedAt = _clock();
      return;
    }
    _active[pointer] = _OwnedTouchTrace(
      pointer: pointer,
      bounds: _pointBounds(globalPosition),
      path: <Offset>[globalPosition],
      firstTimeStamp: timeStamp,
      lastTimeStamp: timeStamp,
      lastObservedAt: _clock(),
    );
  }

  void observe({
    required int pointer,
    required Offset globalPosition,
    required Duration timeStamp,
  }) {
    if (!_isFinite(globalPosition)) return;
    final trace = _active[pointer];
    if (trace == null) {
      observeDown(
        pointer: pointer,
        globalPosition: globalPosition,
        timeStamp: timeStamp,
      );
      return;
    }
    trace
      ..bounds = trace.bounds.expandToInclude(_pointBounds(globalPosition))
      ..append(globalPosition)
      ..lastTimeStamp = timeStamp
      ..lastObservedAt = _clock();
  }

  /// Permanently assigns this pointer sequence to selection for its lifetime.
  ///
  /// Ownership is intentionally monotonic. Once a finger selected, moved, or
  /// resized content, later radius/pressure metadata and ACTION_CANCEL cannot
  /// reinterpret that same physical sequence as an eraser.
  void claimSelection({
    required int pointer,
    Offset? globalPosition,
    Duration? timeStamp,
  }) {
    if (_active[pointer] == null &&
        globalPosition != null &&
        timeStamp != null) {
      observeDown(
        pointer: pointer,
        globalPosition: globalPosition,
        timeStamp: timeStamp,
      );
    }
    _active[pointer]?.selectionOwned = true;
  }

  void complete({
    required int pointer,
    Offset? globalPosition,
    Duration? timeStamp,
  }) {
    final trace = _active.remove(pointer);
    if (trace == null) return;
    if (globalPosition != null &&
        timeStamp != null &&
        _isFinite(globalPosition)) {
      trace
        ..bounds = trace.bounds.expandToInclude(_pointBounds(globalPosition))
        ..append(globalPosition)
        ..lastTimeStamp = timeStamp;
    }
    trace.lastObservedAt = _clock();
    if (!trace.selectionOwned) return;
    _recent.addLast(trace);
    _trimRecent();
  }

  /// Ends active streams during page/mode/controller transitions while
  /// retaining selection ownership long enough to reject a queued platform
  /// message belonging to the old pointer lifecycle.
  void completeAll() {
    if (_active.isEmpty) return;
    final now = _clock();
    for (final trace in _active.values) {
      if (!trace.selectionOwned) continue;
      trace.lastObservedAt = now;
      _recent.addLast(trace);
    }
    _active.clear();
    _trimRecent();
  }

  /// Whether a native palm trace belongs to a touch sequence that already
  /// owns selection/move/resize.
  bool blocksNativeReplay({
    required Iterable<Offset> globalPositions,
    Iterable<Duration> timeStamps = const <Duration>[],
  }) {
    final positions = globalPositions.where(_isFinite).toList(growable: false);
    if (positions.isEmpty) return false;
    _prune();

    final nativeBounds = _boundsFor(positions);
    final usefulTimes = timeStamps
        .where((value) => value > Duration.zero)
        .toList(growable: false);
    Duration? nativeStart;
    Duration? nativeEnd;
    if (usefulTimes.isNotEmpty) {
      nativeStart = usefulTimes.reduce((a, b) => a <= b ? a : b);
      nativeEnd = usefulTimes.reduce((a, b) => a >= b ? a : b);
    }

    for (final trace in _active.values) {
      if (!trace.selectionOwned ||
          !_traceSpatiallyMatches(trace, positions, nativeBounds)) {
        continue;
      }
      if (_timeRangesOverlap(
        trace: trace,
        nativeStart: nativeStart,
        nativeEnd: nativeEnd,
      )) {
        return true;
      }
      // Active pointer streams without usable platform timestamps still need
      // protection, but only along the path which actually owns selection.
      if (nativeStart == null || nativeEnd == null) return true;
    }

    for (final trace in _recent) {
      if (!_traceSpatiallyMatches(trace, positions, nativeBounds)) continue;
      if (nativeStart != null &&
          nativeEnd != null &&
          trace.firstTimeStamp > Duration.zero &&
          trace.lastTimeStamp > Duration.zero) {
        if (_timeRangesOverlap(
          trace: trace,
          nativeStart: nativeStart,
          nativeEnd: nativeEnd,
        )) {
          return true;
        }
        continue;
      }
      // Legacy/test packets without an Android event timestamp are accepted
      // only during a short wall-clock grace period and still need to overlap
      // the owned path spatially.
      if (_clock().difference(trace.lastObservedAt) <= fallbackRetention) {
        return true;
      }
    }
    return false;
  }

  void clear() {
    _active.clear();
    _recent.clear();
  }

  void _prune() {
    final cutoff = _clock().subtract(recentRetention);
    while (_recent.isNotEmpty &&
        _recent.first.lastObservedAt.isBefore(cutoff)) {
      _recent.removeFirst();
    }
  }

  void _trimRecent() {
    _prune();
    while (_recent.length > maximumRecentTraces) {
      _recent.removeFirst();
    }
  }

  bool _spatiallyMatches(Rect owned, Rect native) =>
      owned.inflate(spatialTolerance).overlaps(native) ||
      native.inflate(spatialTolerance).overlaps(owned);

  bool _traceSpatiallyMatches(
    _OwnedTouchTrace trace,
    List<Offset> nativePath,
    Rect nativeBounds,
  ) {
    if (!_spatiallyMatches(trace.bounds, nativeBounds)) return false;
    return _pathsWithinTolerance(trace.path, nativePath, spatialTolerance);
  }

  bool _timeRangesOverlap({
    required _OwnedTouchTrace trace,
    required Duration? nativeStart,
    required Duration? nativeEnd,
  }) {
    if (nativeStart == null ||
        nativeEnd == null ||
        trace.firstTimeStamp <= Duration.zero ||
        trace.lastTimeStamp <= Duration.zero) {
      return true;
    }
    return !(nativeEnd + temporalTolerance < trace.firstTimeStamp ||
        trace.lastTimeStamp + temporalTolerance < nativeStart);
  }

  static bool _pathsWithinTolerance(
    List<Offset> first,
    List<Offset> second,
    double tolerance,
  ) {
    if (first.isEmpty || second.isEmpty) return false;
    final toleranceSquared = tolerance * tolerance;
    if (first.length == 1 && second.length == 1) {
      return (first.single - second.single).distanceSquared <= toleranceSquared;
    }
    if (first.length == 1) {
      return _pointNearPath(first.single, second, toleranceSquared);
    }
    if (second.length == 1) {
      return _pointNearPath(second.single, first, toleranceSquared);
    }
    for (var firstIndex = 0; firstIndex < first.length - 1; firstIndex++) {
      for (
        var secondIndex = 0;
        secondIndex < second.length - 1;
        secondIndex++
      ) {
        if (_segmentsWithinToleranceSquared(
          first[firstIndex],
          first[firstIndex + 1],
          second[secondIndex],
          second[secondIndex + 1],
          toleranceSquared,
        )) {
          return true;
        }
      }
    }
    return false;
  }

  static bool _pointNearPath(
    Offset point,
    List<Offset> path,
    double toleranceSquared,
  ) {
    for (var index = 0; index < path.length - 1; index++) {
      if (_pointSegmentDistanceSquared(point, path[index], path[index + 1]) <=
          toleranceSquared) {
        return true;
      }
    }
    return false;
  }

  static bool _segmentsWithinToleranceSquared(
    Offset a,
    Offset b,
    Offset c,
    Offset d,
    double toleranceSquared,
  ) {
    if (_segmentsIntersect(a, b, c, d)) return true;
    return _pointSegmentDistanceSquared(a, c, d) <= toleranceSquared ||
        _pointSegmentDistanceSquared(b, c, d) <= toleranceSquared ||
        _pointSegmentDistanceSquared(c, a, b) <= toleranceSquared ||
        _pointSegmentDistanceSquared(d, a, b) <= toleranceSquared;
  }

  static bool _segmentsIntersect(Offset a, Offset b, Offset c, Offset d) {
    double cross(Offset first, Offset second, Offset third) =>
        (second.dx - first.dx) * (third.dy - first.dy) -
        (second.dy - first.dy) * (third.dx - first.dx);
    final abC = cross(a, b, c);
    final abD = cross(a, b, d);
    final cdA = cross(c, d, a);
    final cdB = cross(c, d, b);
    return ((abC <= 0 && abD >= 0) || (abC >= 0 && abD <= 0)) &&
        ((cdA <= 0 && cdB >= 0) || (cdA >= 0 && cdB <= 0));
  }

  static double _pointSegmentDistanceSquared(
    Offset point,
    Offset start,
    Offset end,
  ) {
    final delta = end - start;
    final lengthSquared = delta.distanceSquared;
    if (lengthSquared <= 1e-9) return (point - start).distanceSquared;
    final projection =
        ((point.dx - start.dx) * delta.dx + (point.dy - start.dy) * delta.dy) /
        lengthSquared;
    final bounded = projection.clamp(0.0, 1.0);
    final nearest = start + delta * bounded;
    return (point - nearest).distanceSquared;
  }

  static Rect _pointBounds(Offset value) =>
      Rect.fromLTRB(value.dx, value.dy, value.dx, value.dy);

  static Rect _boundsFor(List<Offset> values) {
    var bounds = _pointBounds(values.first);
    for (final value in values.skip(1)) {
      bounds = bounds.expandToInclude(_pointBounds(value));
    }
    return bounds;
  }

  static bool _isFinite(Offset value) => value.dx.isFinite && value.dy.isFinite;
}

final class _OwnedTouchTrace {
  _OwnedTouchTrace({
    required this.pointer,
    required this.bounds,
    required this.path,
    required this.firstTimeStamp,
    required this.lastTimeStamp,
    required this.lastObservedAt,
  });

  final int pointer;
  Rect bounds;
  final List<Offset> path;
  final Duration firstTimeStamp;
  Duration lastTimeStamp;
  DateTime lastObservedAt;
  bool selectionOwned = false;

  void append(Offset value) {
    if (path.isNotEmpty && (path.last - value).distanceSquared < 1) return;
    if (path.length >= 64) {
      var writeIndex = 1;
      for (var readIndex = 2; readIndex < path.length - 1; readIndex += 2) {
        path[writeIndex++] = path[readIndex];
      }
      final last = path.last;
      if (writeIndex < path.length) path[writeIndex++] = last;
      path.removeRange(writeIndex, path.length);
    }
    path.add(value);
  }
}
