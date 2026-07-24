import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// A conservative fallback for panels which split the heel of a clenched hand
/// into several ordinary-looking touch contacts.
///
/// A cluster is accepted only when at least three contacts:
///
/// * arrived almost simultaneously;
/// * form a compact footprint both before and after moving; and
/// * move together like one physical contact.
///
/// This deliberately does not classify on pointer-down. Two-finger pan/zoom
/// therefore remains untouched, and a five-finger radial gesture has time to
/// win arbitration before any movement is considered here.
final class ClusteredTouchEraserTracker {
  ClusteredTouchEraserTracker({
    this.minimumContacts = 3,
    this.maximumDiameter = 132,
    this.maximumDownSpread = const Duration(milliseconds: 180),
    this.maximumRecognitionDelay = const Duration(milliseconds: 700),
    this.minimumContactTravel = 6,
    this.minimumCentroidTravel = 4,
    this.minimumDirectionAgreement = .82,
  }) : assert(minimumContacts == 3),
       assert(maximumDiameter > 0),
       assert(minimumContactTravel > 0),
       assert(minimumCentroidTravel > 0),
       assert(minimumDirectionAgreement >= 0 && minimumDirectionAgreement <= 1);

  final int minimumContacts;
  final double maximumDiameter;
  final Duration maximumDownSpread;
  final Duration maximumRecognitionDelay;
  final double minimumContactTravel;
  final double minimumCentroidTravel;
  final double minimumDirectionAgreement;

  final Map<int, _TrackedTouchContact> _contacts =
      <int, _TrackedTouchContact>{};

  int get contactCount => _contacts.length;

  void add(PointerDownEvent event, Offset localPosition) {
    if (event.kind != PointerDeviceKind.touch || !_isFinite(localPosition)) {
      return;
    }
    _contacts[event.pointer] = _TrackedTouchContact(
      pointer: event.pointer,
      downTime: event.timeStamp,
      initialPosition: localPosition,
      currentPosition: localPosition,
    );
  }

  /// Updates one contact and returns an eraser match once the footprint has
  /// enough evidence. The caller owns arbitration and must then [removeAll]
  /// matched contacts after promoting them.
  ClusteredTouchEraserMatch? update(
    PointerMoveEvent event,
    Offset localPosition,
  ) {
    if (event.kind != PointerDeviceKind.touch || !_isFinite(localPosition)) {
      return null;
    }
    final updated = _contacts[event.pointer];
    if (updated == null) return null;
    updated.currentPosition = localPosition;

    if (_contacts.length < minimumContacts) return null;
    final nearby = _contacts.values
        .where(
          (contact) =>
              (contact.currentPosition - updated.currentPosition).distance <=
              maximumDiameter,
        )
        .toList(growable: false);
    if (nearby.length < minimumContacts) return null;

    // Search triples containing the contact which just moved. A small fixed
    // contact count is typical, so this is both deterministic and cheaper than
    // maintaining a second spatial index for transient pointers.
    for (var first = 0; first < nearby.length - 1; first++) {
      for (var second = first + 1; second < nearby.length; second++) {
        final triple = <_TrackedTouchContact>{
          updated,
          nearby[first],
          nearby[second],
        }.toList(growable: false);
        if (triple.length != minimumContacts || !_qualifies(triple, event)) {
          continue;
        }

        final cluster = <_TrackedTouchContact>[...triple];
        for (final candidate in nearby) {
          if (cluster.contains(candidate)) continue;
          final expanded = <_TrackedTouchContact>[...cluster, candidate];
          if (_compatibleFootprint(expanded, event.timeStamp)) {
            cluster.add(candidate);
          }
        }
        final diameter = _maximumPairDistance(
          cluster.map((contact) => contact.currentPosition),
        );
        final radius = (16 + diameter * .30).clamp(24.0, 52.0);
        return ClusteredTouchEraserMatch(
          positions: <int, Offset>{
            for (final contact in cluster)
              contact.pointer: contact.currentPosition,
          },
          brushRadius: radius,
        );
      }
    }
    return null;
  }

  void remove(int pointer) => _contacts.remove(pointer);

  void removeAll(Iterable<int> pointers) {
    for (final pointer in pointers) {
      _contacts.remove(pointer);
    }
  }

  void clear() => _contacts.clear();

  bool _qualifies(List<_TrackedTouchContact> contacts, PointerMoveEvent event) {
    if (!_compatibleFootprint(contacts, event.timeStamp)) return false;
    final movements = contacts
        .map((contact) => contact.currentPosition - contact.initialPosition)
        .where((movement) => movement.distance >= minimumContactTravel)
        .toList(growable: false);
    if (movements.length < 2) return false;

    final initialCentroid = _centroid(
      contacts.map((contact) => contact.initialPosition),
    );
    final currentCentroid = _centroid(
      contacts.map((contact) => contact.currentPosition),
    );
    if ((currentCentroid - initialCentroid).distance < minimumCentroidTravel) {
      return false;
    }

    var unitVectorSum = Offset.zero;
    for (final movement in movements) {
      unitVectorSum += movement / movement.distance;
    }
    final agreement = unitVectorSum.distance / movements.length;
    return agreement >= minimumDirectionAgreement;
  }

  bool _compatibleFootprint(
    List<_TrackedTouchContact> contacts,
    Duration currentTime,
  ) {
    final downTimes = contacts.map((contact) => contact.downTime);
    final earliest = downTimes.reduce((a, b) => a <= b ? a : b);
    final latest = downTimes.reduce((a, b) => a >= b ? a : b);
    if (latest - earliest > maximumDownSpread) return false;
    if (currentTime >= latest &&
        currentTime - latest > maximumRecognitionDelay) {
      return false;
    }
    return _maximumPairDistance(
              contacts.map((contact) => contact.initialPosition),
            ) <=
            maximumDiameter &&
        _maximumPairDistance(
              contacts.map((contact) => contact.currentPosition),
            ) <=
            maximumDiameter;
  }

  static double _maximumPairDistance(Iterable<Offset> values) {
    final positions = values.toList(growable: false);
    var maximum = 0.0;
    for (var first = 0; first < positions.length; first++) {
      for (var second = first + 1; second < positions.length; second++) {
        maximum = math.max(
          maximum,
          (positions[first] - positions[second]).distance,
        );
      }
    }
    return maximum;
  }

  static Offset _centroid(Iterable<Offset> values) {
    var sum = Offset.zero;
    var count = 0;
    for (final value in values) {
      sum += value;
      count++;
    }
    return count == 0 ? Offset.zero : sum / count.toDouble();
  }

  static bool _isFinite(Offset value) => value.dx.isFinite && value.dy.isFinite;
}

@immutable
final class ClusteredTouchEraserMatch {
  ClusteredTouchEraserMatch({
    required Map<int, Offset> positions,
    required this.brushRadius,
  }) : positions = Map<int, Offset>.unmodifiable(positions);

  final Map<int, Offset> positions;

  /// Eraser radius in logical screen pixels.
  final double brushRadius;
}

final class _TrackedTouchContact {
  _TrackedTouchContact({
    required this.pointer,
    required this.downTime,
    required this.initialPosition,
    required this.currentPosition,
  });

  final int pointer;
  final Duration downTime;
  final Offset initialPosition;
  Offset currentPosition;
}
