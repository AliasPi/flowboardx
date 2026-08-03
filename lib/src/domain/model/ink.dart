import 'dart:math' as math;

import 'geometry.dart';

enum InkToolType { normal, marker, dashed, straightLine }

final class InkPoint {
  const InkPoint({
    required this.x,
    required this.y,
    this.pressure = 1,
    this.timestampMicros = 0,
    this.tiltX = 0,
    this.tiltY = 0,
  });

  final double x;
  final double y;
  final double pressure;
  final int timestampMicros;
  final double tiltX;
  final double tiltY;

  Vec2 get position => Vec2(x, y);

  InkPoint transformed(TransformDelta delta) {
    final position = delta.apply(this.position);
    return InkPoint(
      x: position.x,
      y: position.y,
      pressure: pressure,
      timestampMicros: timestampMicros,
      tiltX: tiltX,
      tiltY: tiltY,
    );
  }

  Map<String, Object> toJson() => {
    'x': x,
    'y': y,
    'pressure': pressure,
    'timestampMicros': timestampMicros,
    'tiltX': tiltX,
    'tiltY': tiltY,
  };

  factory InkPoint.fromJson(Map<String, Object?> json) => InkPoint(
    x: _double(json['x'], 0),
    y: _double(json['y'], 0),
    pressure: _double(json['pressure'], 1).clamp(0, 1),
    timestampMicros: _integer(json['timestampMicros'], 0),
    tiltX: _double(json['tiltX'], 0).clamp(-1, 1),
    tiltY: _double(json['tiltY'], 0).clamp(-1, 1),
  );
}

final class InkStroke {
  InkStroke({
    required this.id,
    required Iterable<InkPoint> points,
    this.colorArgb = 0xFF000000,
    this.width = 4,
    this.type = InkToolType.normal,
    this.zIndex = 0,
    DateTime? createdAt,
    this.authorId = 'local',
    this.pointerId,
  }) : points = List.unmodifiable(points),
       _boundsCache = null,
       createdAt = (createdAt ?? DateTime.now().toUtc()).toUtc();

  InkStroke._trusted({
    required this.id,
    required this.points,
    required this.colorArgb,
    required this.width,
    required this.type,
    required this.zIndex,
    required this.createdAt,
    required this.authorId,
    required this.pointerId,
    required Rect2? knownBounds,
  }) : _boundsCache = knownBounds;

  final String id;
  final List<InkPoint> points;
  final int colorArgb;
  final double width;
  final InkToolType type;
  final int zIndex;
  final DateTime createdAt;
  final String authorId;
  final int? pointerId;

  bool get isEmpty => points.isEmpty;

  Rect2? _boundsCache;
  Rect2 get bounds => _boundsCache ??= _calculateBounds();

  Rect2 _calculateBounds() {
    if (points.isEmpty) return const Rect2.zero();
    // Bounds are requested while freezing live-preview chunks, indexing a
    // committed stroke and culling persisted ink. Mapping every sample through
    // [InkPoint.position] allocated one Vec2 plus iterator plumbing per point.
    // Curved handwriting contains deliberately more anchors than a straight
    // line, so that allocation burst made circles disproportionately costly.
    // Scan the already validated primitive coordinates directly instead.
    final first = points.first;
    var minimumX = first.x;
    var maximumX = first.x;
    var minimumY = first.y;
    var maximumY = first.y;
    for (var index = 1; index < points.length; index++) {
      final point = points[index];
      minimumX = math.min(minimumX, point.x);
      maximumX = math.max(maximumX, point.x);
      minimumY = math.min(minimumY, point.y);
      maximumY = math.max(maximumY, point.y);
    }
    return Rect2(
      left: minimumX,
      top: minimumY,
      width: maximumX - minimumX,
      height: maximumY - minimumY,
    ).inflate(width / 2);
  }

  int get firstTimestampMicros => points.isEmpty
      ? createdAt.microsecondsSinceEpoch
      : points.first.timestampMicros;
  int get lastTimestampMicros => points.isEmpty
      ? createdAt.microsecondsSinceEpoch
      : points.last.timestampMicros;

  InkStroke transformed(TransformDelta delta) => copyWith(
    points: points.map((point) => point.transformed(delta)),
    width:
        width *
        math.sqrt(
          (delta.scaleX.abs() * delta.scaleY.abs()).clamp(
            0.0001,
            double.infinity,
          ),
        ),
  );

  InkStroke copyWith({
    String? id,
    Iterable<InkPoint>? points,
    int? colorArgb,
    double? width,
    InkToolType? type,
    int? zIndex,
    DateTime? createdAt,
    String? authorId,
    int? pointerId,
    bool clearPointerId = false,
  }) {
    final nextPoints = points == null || identical(points, this.points)
        ? this.points
        : List<InkPoint>.unmodifiable(points);
    final nextWidth = math.max(0.0001, width ?? this.width);
    return InkStroke._trusted(
      id: id ?? this.id,
      points: nextPoints,
      colorArgb: colorArgb ?? this.colorArgb,
      // Object-bound ink uses normalized coordinates, so a normal 8 px nib can
      // legitimately be far below 0.1 for a large embedded object.
      width: nextWidth,
      type: type ?? this.type,
      zIndex: zIndex ?? this.zIndex,
      createdAt: (createdAt ?? this.createdAt).toUtc(),
      authorId: authorId ?? this.authorId,
      pointerId: clearPointerId ? null : pointerId ?? this.pointerId,
      knownBounds: identical(nextPoints, this.points) && nextWidth == this.width
          ? _boundsCache
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    // Points dominate real-world documents. A flat numeric array avoids one
    // JSON map and six repeated field names per sample while retaining every
    // persisted value. [fromJson] continues to accept the legacy map list.
    'points': _encodePoints(points),
    'colorArgb': colorArgb,
    'width': width,
    'type': type.name,
    'zIndex': zIndex,
    'createdAt': createdAt.toIso8601String(),
    'authorId': authorId,
    if (pointerId != null) 'pointerId': pointerId,
  };

  factory InkStroke.fromJson(Map<String, Object?> json) => InkStroke(
    id: _string(json['id'], 'stroke'),
    points: _decodePoints(json['points']),
    colorArgb: _integer(json['colorArgb'], 0xFF000000),
    width: math.max(0.0001, _double(json['width'], 4)),
    type: _enumByName(InkToolType.values, json['type'], InkToolType.normal),
    zIndex: _integer(json['zIndex'], 0),
    createdAt: _date(json['createdAt']),
    authorId: _string(json['authorId'], 'local'),
    pointerId: json['pointerId'] is num
        ? (json['pointerId']! as num).toInt()
        : null,
  );
}

const int _inkPointFieldCount = 6;

List<num> _encodePoints(List<InkPoint> points) {
  final result = List<num>.filled(
    points.length * _inkPointFieldCount,
    0,
    growable: false,
  );
  var offset = 0;
  for (final point in points) {
    result[offset++] = point.x;
    result[offset++] = point.y;
    result[offset++] = point.pressure;
    result[offset++] = point.timestampMicros;
    result[offset++] = point.tiltX;
    result[offset++] = point.tiltY;
  }
  return result;
}

Iterable<InkPoint> _decodePoints(Object? value) sync* {
  if (value is! List || value.isEmpty) return;

  // Documents written before compact point storage used one map per point.
  if (value.first is Map) {
    yield* _mapList(value).map(InkPoint.fromJson);
    return;
  }

  // A truncated final tuple is ignored defensively. Complete tuples still
  // recover, and no synthesized point can introduce a large line to (0, 0).
  final completeLength = value.length - (value.length % _inkPointFieldCount);
  for (var offset = 0; offset < completeLength; offset += _inkPointFieldCount) {
    final x = value[offset];
    final y = value[offset + 1];
    final pressure = value[offset + 2];
    final timestamp = value[offset + 3];
    final tiltX = value[offset + 4];
    final tiltY = value[offset + 5];
    // A non-numeric tuple is corrupt. Skip that point rather than applying
    // legacy field fallbacks that could create visible phantom ink.
    if (x is! num ||
        y is! num ||
        pressure is! num ||
        timestamp is! num ||
        tiltX is! num ||
        tiltY is! num) {
      continue;
    }
    final safeX = x.toDouble();
    final safeY = y.toDouble();
    if (!safeX.isFinite || !safeY.isFinite) continue;
    final safeTimestamp = timestamp.toDouble();
    yield InkPoint(
      x: safeX,
      y: safeY,
      pressure: pressure.toDouble().isFinite
          ? pressure.toDouble().clamp(0, 1)
          : 1,
      timestampMicros: safeTimestamp.isFinite ? timestamp.toInt() : 0,
      tiltX: tiltX.toDouble().isFinite ? tiltX.toDouble().clamp(-1, 1) : 0,
      tiltY: tiltY.toDouble().isFinite ? tiltY.toDouble().clamp(-1, 1) : 0,
    );
  }
}

final class PenPreset {
  const PenPreset({
    required this.id,
    required this.name,
    this.colorArgb = 0xFF000000,
    this.width = 4,
    this.type = InkToolType.normal,
  });

  final String id;
  final String name;
  final int colorArgb;
  final double width;
  final InkToolType type;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'colorArgb': colorArgb,
    'width': width,
    'type': type.name,
  };

  factory PenPreset.fromJson(Map<String, Object?> json) => PenPreset(
    id: _string(json['id'], 'black'),
    name: _string(json['name'], 'Schwarz'),
    colorArgb: _integer(json['colorArgb'], 0xFF000000),
    width: math.max(0.1, _double(json['width'], 4)),
    type: _enumByName(InkToolType.values, json['type'], InkToolType.normal),
  );
}

T _enumByName<T extends Enum>(List<T> values, Object? value, T fallback) {
  final name = value?.toString();
  return values.where((candidate) => candidate.name == name).firstOrNull ??
      fallback;
}

double _double(Object? value, double fallback) {
  final result = value is num ? value.toDouble() : fallback;
  return result.isFinite ? result : fallback;
}

int _integer(Object? value, int fallback) =>
    value is num ? value.toInt() : fallback;
String _string(Object? value, String fallback) =>
    value is String && value.isNotEmpty ? value : fallback;
DateTime _date(Object? value) =>
    DateTime.tryParse(value?.toString() ?? '')?.toUtc() ??
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

Iterable<Map<String, Object?>> _mapList(Object? value) sync* {
  if (value is! List) return;
  for (final item in value) {
    if (item is Map) yield Map<String, Object?>.from(item);
  }
}
