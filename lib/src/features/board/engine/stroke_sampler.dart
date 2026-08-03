import 'dart:math' as math;
import 'dart:collection';

import 'package:flutter/material.dart';

@immutable
class StrokeSample {
  const StrokeSample({
    required this.position,
    required this.timestampMicros,
    required this.pressure,
    this.tilt = Offset.zero,
  });

  final Offset position;
  final int timestampMicros;
  final double pressure;
  final Offset tilt;
}

class StrokeSampler {
  StrokeSampler({
    this.minimumDistance = 0.45,
    this.curveTolerance = 0.35,
    this.pressureTolerance = 0.08,
    this.maximumSegmentLength = 4,
    this.maxSamples = 100000,
    DateTime? sessionStartedAt,
  }) : _sessionStartedMicros = (sessionStartedAt ?? DateTime.now())
           .toUtc()
           .microsecondsSinceEpoch {
    if (!minimumDistance.isFinite || minimumDistance < 0) {
      throw ArgumentError.value(
        minimumDistance,
        'minimumDistance',
        'muss endlich und nicht negativ sein',
      );
    }
    if (!curveTolerance.isFinite || curveTolerance < 0) {
      throw ArgumentError.value(
        curveTolerance,
        'curveTolerance',
        'muss endlich und nicht negativ sein',
      );
    }
    if (!pressureTolerance.isFinite || pressureTolerance < 0) {
      throw ArgumentError.value(
        pressureTolerance,
        'pressureTolerance',
        'muss endlich und nicht negativ sein',
      );
    }
    if (!maximumSegmentLength.isFinite || maximumSegmentLength <= 0) {
      throw ArgumentError.value(
        maximumSegmentLength,
        'maximumSegmentLength',
        'muss endlich und positiv sein',
      );
    }
  }

  final double minimumDistance;
  final double curveTolerance;
  final double pressureTolerance;
  final double maximumSegmentLength;
  final int maxSamples;
  final int _sessionStartedMicros;
  Duration? _firstEventTimestamp;
  final List<StrokeSample> _samples = <StrokeSample>[];
  final List<Offset> _samplingPositions = <Offset>[];
  // The newest item is a lightweight endpoint which follows every hardware
  // packet. The item before it is the last committed geometric anchor. A new
  // anchor is created only when curvature/pressure demands it or the segment
  // reaches a small screen-space maximum. This keeps circles sub-pixel exact
  // without storing and tessellating hundreds of redundant 240 Hz samples.
  bool _hasPendingEndpoint = false;

  late final List<StrokeSample> _readOnlySamples =
      UnmodifiableListView<StrokeSample>(_samples);
  List<StrokeSample> get samples => _readOnlySamples;
  bool get isEmpty => _samples.isEmpty;

  bool addEvent(
    PointerEvent event,
    Offset worldPosition, {
    Offset? samplingPosition,
  }) {
    if (!worldPosition.dx.isFinite || !worldPosition.dy.isFinite) {
      return false;
    }
    final requestedSamplingPosition = samplingPosition ?? worldPosition;
    final safeSamplingPosition =
        requestedSamplingPosition.dx.isFinite &&
            requestedSamplingPosition.dy.isFinite
        ? requestedSamplingPosition
        : worldPosition;
    final rawTilt = event.tilt;
    var tilt = Offset.zero;
    if (rawTilt.isFinite && rawTilt != 0) {
      final orientation = event.orientation.isFinite ? event.orientation : 0.0;
      final rawTiltX = rawTilt * math.cos(orientation);
      final rawTiltY = rawTilt * math.sin(orientation);
      if (rawTiltX.isFinite && rawTiltY.isFinite) {
        tilt = Offset(rawTiltX.clamp(-1.0, 1.0), rawTiltY.clamp(-1.0, 1.0));
      }
    }
    // Pointer events are already trusted, finite framework data after the
    // checks above. Feeding them directly into the sampler avoids constructing
    // a second StrokeSample and a second tilt Offset for every 120/240 Hz MOVE.
    return _addSanitized(
      StrokeSample(
        position: worldPosition,
        timestampMicros: _absoluteTimestamp(event.timeStamp),
        pressure: _normalizedPressure(event),
        tilt: tilt,
      ),
      safeSamplingPosition,
    );
  }

  int _absoluteTimestamp(Duration eventTimestamp) {
    final first = _firstEventTimestamp ??= eventTimestamp;
    // Duration subtraction allocates another short-lived object for every
    // hardware packet. The timestamps are integer microseconds already.
    return _sessionStartedMicros +
        math.max(0, eventTimestamp.inMicroseconds - first.inMicroseconds);
  }

  bool add(StrokeSample sample, {Offset? samplingPosition}) {
    if (!sample.position.dx.isFinite || !sample.position.dy.isFinite) {
      return false;
    }
    final safePressure = sample.pressure.isFinite
        ? sample.pressure.clamp(0.05, 1.0)
        : 1.0;
    final safeTiltX = sample.tilt.dx.isFinite
        ? sample.tilt.dx.clamp(-1.0, 1.0)
        : 0.0;
    final safeTiltY = sample.tilt.dy.isFinite
        ? sample.tilt.dy.clamp(-1.0, 1.0)
        : 0.0;
    final safeSample =
        safePressure == sample.pressure &&
            safeTiltX == sample.tilt.dx &&
            safeTiltY == sample.tilt.dy
        ? sample
        : StrokeSample(
            position: sample.position,
            timestampMicros: sample.timestampMicros,
            pressure: safePressure,
            tilt: safeTiltX == 0 && safeTiltY == 0
                ? Offset.zero
                : Offset(safeTiltX, safeTiltY),
          );
    final requestedSamplingPosition = samplingPosition ?? sample.position;
    final safeSamplingPosition =
        requestedSamplingPosition.dx.isFinite &&
            requestedSamplingPosition.dy.isFinite
        ? requestedSamplingPosition
        : sample.position;
    return _addSanitized(safeSample, safeSamplingPosition);
  }

  bool _addSanitized(StrokeSample safeSample, Offset safeSamplingPosition) {
    if (_samples.length >= maxSamples) {
      _samples[_samples.length - 1] = safeSample;
      _samplingPositions[_samplingPositions.length - 1] = safeSamplingPosition;
      return true;
    }

    if (_samples.isEmpty) {
      _samples.add(safeSample);
      _samplingPositions.add(safeSamplingPosition);
      _hasPendingEndpoint = false;
      return true;
    }

    if (!_hasPendingEndpoint) {
      _samples.add(safeSample);
      _samplingPositions.add(safeSamplingPosition);
      _hasPendingEndpoint = true;
      return true;
    }

    final anchorIndex = _samples.length - 2;
    final anchorPosition = _samplingPositions[anchorIndex];
    final pendingPosition = _samplingPositions.last;
    final anchorDeltaX = safeSamplingPosition.dx - anchorPosition.dx;
    final anchorDeltaY = safeSamplingPosition.dy - anchorPosition.dy;
    final anchorToNew = math.sqrt(
      anchorDeltaX * anchorDeltaX + anchorDeltaY * anchorDeltaY,
    );
    if (!anchorToNew.isFinite) return false;

    if (anchorToNew < minimumDistance) {
      _samples[_samples.length - 1] = safeSample;
      _samplingPositions[_samplingPositions.length - 1] = safeSamplingPosition;
      return true;
    }

    final pendingDeviation = _distanceToSegment(
      pendingPosition,
      anchorPosition,
      safeSamplingPosition,
    );
    final pressureDeviation = _pressureDeviation(
      anchor: _samples[anchorIndex],
      pending: _samples.last,
      next: safeSample,
      anchorPosition: anchorPosition,
      pendingPosition: pendingPosition,
      nextPosition: safeSamplingPosition,
    );
    final commitPending =
        anchorToNew >= maximumSegmentLength ||
        pendingDeviation > curveTolerance ||
        pressureDeviation > pressureTolerance;

    if (commitPending) {
      // The previous endpoint becomes a stable anchor. Append one new pending
      // endpoint so the visible nib still follows the latest raw event.
      _samples.add(safeSample);
      _samplingPositions.add(safeSamplingPosition);
    } else {
      _samples[_samples.length - 1] = safeSample;
      _samplingPositions[_samplingPositions.length - 1] = safeSamplingPosition;
    }
    return true;
  }

  static double _distanceToSegment(Offset point, Offset start, Offset end) {
    final deltaX = end.dx - start.dx;
    final deltaY = end.dy - start.dy;
    final lengthSquared = deltaX * deltaX + deltaY * deltaY;
    final relativeX = point.dx - start.dx;
    final relativeY = point.dy - start.dy;
    if (!lengthSquared.isFinite || lengthSquared <= 1e-12) {
      return math.sqrt(relativeX * relativeX + relativeY * relativeY);
    }
    final t = ((relativeX * deltaX + relativeY * deltaY) / lengthSquared).clamp(
      0.0,
      1.0,
    );
    final errorX = point.dx - (start.dx + deltaX * t);
    final errorY = point.dy - (start.dy + deltaY * t);
    return math.sqrt(errorX * errorX + errorY * errorY);
  }

  static double _pressureDeviation({
    required StrokeSample anchor,
    required StrokeSample pending,
    required StrokeSample next,
    required Offset anchorPosition,
    required Offset pendingPosition,
    required Offset nextPosition,
  }) {
    final deltaX = nextPosition.dx - anchorPosition.dx;
    final deltaY = nextPosition.dy - anchorPosition.dy;
    final lengthSquared = deltaX * deltaX + deltaY * deltaY;
    if (!lengthSquared.isFinite || lengthSquared <= 1e-12) {
      return (pending.pressure - anchor.pressure).abs();
    }
    final relativeX = pendingPosition.dx - anchorPosition.dx;
    final relativeY = pendingPosition.dy - anchorPosition.dy;
    final t = ((relativeX * deltaX + relativeY * deltaY) / lengthSquared).clamp(
      0.0,
      1.0,
    );
    final expected = anchor.pressure + (next.pressure - anchor.pressure) * t;
    return (pending.pressure - expected).abs();
  }

  List<Offset> smoothedPositions() {
    if (_samples.length < 3) {
      return _samples.map((sample) => sample.position).toList(growable: false);
    }
    final result = <Offset>[_samples.first.position];
    for (var i = 1; i < _samples.length - 1; i++) {
      final previous = _samples[i - 1].position;
      final current = _samples[i].position;
      final next = _samples[i + 1].position;
      result.add(previous * 0.18 + current * 0.64 + next * 0.18);
    }
    result.add(_samples.last.position);
    return result;
  }

  double _normalizedPressure(PointerEvent event) {
    final range = event.pressureMax - event.pressureMin;
    if (!event.pressure.isFinite || !range.isFinite || range <= 0) return 1;
    return ((event.pressure - event.pressureMin) / range).clamp(0.05, 1.0);
  }
}
