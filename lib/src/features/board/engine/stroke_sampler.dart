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

  late final List<StrokeSample> _readOnlySamples =
      UnmodifiableListView<StrokeSample>(_samples);
  List<StrokeSample> get samples => _readOnlySamples;
  bool get isEmpty => _samples.isEmpty;

  void addEvent(PointerEvent event, Offset worldPosition) {
    add(
      StrokeSample(
        position: worldPosition,
        timestampMicros: _absoluteTimestamp(event.timeStamp),
        pressure: _normalizedPressure(event),
        tilt: Offset(
          event.tilt * math.cos(event.orientation),
          event.tilt * math.sin(event.orientation),
        ),
      ),
    );
  }

  int _absoluteTimestamp(Duration eventTimestamp) {
    final first = _firstEventTimestamp ??= eventTimestamp;
    final delta = eventTimestamp - first;
    return _sessionStartedMicros + math.max(0, delta.inMicroseconds);
  }

  void add(StrokeSample sample) {
    if (_samples.length >= maxSamples) return;
    if (!sample.position.dx.isFinite || !sample.position.dy.isFinite) return;
    final safeSample = StrokeSample(
      position: sample.position,
      timestampMicros: sample.timestampMicros,
      pressure: sample.pressure.isFinite ? sample.pressure.clamp(0.05, 1) : 1,
      tilt: Offset(
        sample.tilt.dx.isFinite ? sample.tilt.dx.clamp(-1, 1) : 0,
        sample.tilt.dy.isFinite ? sample.tilt.dy.clamp(-1, 1) : 0,
      ),
    );
    final distance = _samples.isEmpty
        ? null
        : (_samples.last.position - safeSample.position).distance;
    if (_samples.isNotEmpty &&
        distance!.isFinite &&
        distance < minimumDistance) {
      // Preserve the freshest pressure and timestamp without growing the path.
      _samples[_samples.length - 1] = safeSample;
      return;
    }
    _samples.add(safeSample);
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
