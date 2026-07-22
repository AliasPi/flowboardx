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
       createdAt = (createdAt ?? DateTime.now().toUtc()).toUtc();

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

  late final Rect2 bounds = _calculateBounds();

  Rect2 _calculateBounds() {
    if (points.isEmpty) return const Rect2.zero();
    return Rect2.fromPoints(
      points.map((point) => point.position),
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
  }) => InkStroke(
    id: id ?? this.id,
    points: points ?? this.points,
    colorArgb: colorArgb ?? this.colorArgb,
    // Object-bound ink uses normalized coordinates, so a normal 8 px nib can
    // legitimately be far below 0.1 for a large embedded object.
    width: math.max(0.0001, width ?? this.width),
    type: type ?? this.type,
    zIndex: zIndex ?? this.zIndex,
    createdAt: createdAt ?? this.createdAt,
    authorId: authorId ?? this.authorId,
    pointerId: clearPointerId ? null : pointerId ?? this.pointerId,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'points': points.map((point) => point.toJson()).toList(growable: false),
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
    points: _mapList(json['points']).map(InkPoint.fromJson),
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
