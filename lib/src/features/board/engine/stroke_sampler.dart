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
    this.maxSamples = 100000,
    DateTime? sessionStartedAt,
  }) : _sessionStartedMicros = (sessionStartedAt ?? DateTime.now())
           .toUtc()
           .microsecondsSinceEpoch;

  final double minimumDistance;
  final int maxSamples;
  final int _sessionStartedMicros;
  Duration? _firstEventTimestamp;
  final List<StrokeSample> _samples = <StrokeSample>[];
  // The last spatially accepted sample remains fixed while one lightweight
  // pending endpoint follows sub-threshold motion. Measuring against the raw
  // previous event would prevent slow, high-frequency stylus movement from
  // ever accumulating enough distance to form a real curve.
  Offset? _lastSamplingPosition;
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
    return add(
      StrokeSample(
        position: worldPosition,
        timestampMicros: _absoluteTimestamp(event.timeStamp),
        pressure: _normalizedPressure(event),
        tilt: Offset(
          event.tilt * math.cos(event.orientation),
          event.tilt * math.sin(event.orientation),
        ),
      ),
      samplingPosition: samplingPosition,
    );
  }

  int _absoluteTimestamp(Duration eventTimestamp) {
    final first = _firstEventTimestamp ??= eventTimestamp;
    final delta = eventTimestamp - first;
    return _sessionStartedMicros + math.max(0, delta.inMicroseconds);
  }

  bool add(StrokeSample sample, {Offset? samplingPosition}) {
    if (!sample.position.dx.isFinite || !sample.position.dy.isFinite) {
      return false;
    }
    final safeSample = StrokeSample(
      position: sample.position,
      timestampMicros: sample.timestampMicros,
      pressure: sample.pressure.isFinite ? sample.pressure.clamp(0.05, 1) : 1,
      tilt: Offset(
        sample.tilt.dx.isFinite ? sample.tilt.dx.clamp(-1, 1) : 0,
        sample.tilt.dy.isFinite ? sample.tilt.dy.clamp(-1, 1) : 0,
      ),
    );
    final requestedSamplingPosition = samplingPosition ?? safeSample.position;
    final safeSamplingPosition =
        requestedSamplingPosition.dx.isFinite &&
            requestedSamplingPosition.dy.isFinite
        ? requestedSamplingPosition
        : safeSample.position;
    if (_samples.length >= maxSamples) {
      _samples[_samples.length - 1] = safeSample;
      return true;
    }

    if (_samples.isEmpty) {
      _samples.add(safeSample);
      _lastSamplingPosition = safeSamplingPosition;
      _hasPendingEndpoint = false;
      return true;
    }

    final distance =
        ((_lastSamplingPosition ?? _samples.last.position) -
                safeSamplingPosition)
            .distance;
    if (distance.isFinite && distance < minimumDistance) {
      // Keep accepted anchors intact. A separate pending endpoint makes the
      // live nib follow slow movement without resetting the distance origin
      // on every high-rate hardware event.
      if (_hasPendingEndpoint) {
        _samples[_samples.length - 1] = safeSample;
      } else {
        _samples.add(safeSample);
        _hasPendingEndpoint = true;
      }
      return true;
    }

    if (_hasPendingEndpoint) {
      _samples[_samples.length - 1] = safeSample;
    } else {
      _samples.add(safeSample);
    }
    _lastSamplingPosition = safeSamplingPosition;
    _hasPendingEndpoint = false;
    return true;
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
