import 'dart:math' as math;

double _finiteDouble(Object? value, double fallback) {
  final number = value is num ? value.toDouble() : fallback;
  return number.isFinite ? number : fallback;
}

/// A small platform-independent 2D vector used by the document model.
final class Vec2 {
  const Vec2(this.x, this.y);

  final double x;
  final double y;

  static const zero = Vec2(0, 0);

  double distanceTo(Vec2 other) =>
      math.sqrt(math.pow(x - other.x, 2) + math.pow(y - other.y, 2));

  Vec2 operator +(Vec2 other) => Vec2(x + other.x, y + other.y);
  Vec2 operator -(Vec2 other) => Vec2(x - other.x, y - other.y);
  Vec2 operator *(double factor) => Vec2(x * factor, y * factor);

  Map<String, Object> toJson() => {'x': x, 'y': y};

  factory Vec2.fromJson(Map<String, Object?> json) =>
      Vec2(_finiteDouble(json['x'], 0), _finiteDouble(json['y'], 0));

  @override
  bool operator ==(Object other) =>
      other is Vec2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// An axis-aligned rectangle. Empty rectangles are represented by zero size.
final class Rect2 {
  const Rect2({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  const Rect2.zero() : this(left: 0, top: 0, width: 0, height: 0);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;
  Vec2 get center => Vec2(left + width / 2, top + height / 2);
  bool get isEmpty => width <= 0 || height <= 0;

  bool contains(Vec2 point) =>
      point.x >= left &&
      point.x <= right &&
      point.y >= top &&
      point.y <= bottom;

  bool intersects(Rect2 other) =>
      left <= other.right &&
      right >= other.left &&
      top <= other.bottom &&
      bottom >= other.top;

  Rect2 inflate(double amount) => Rect2(
    left: left - amount,
    top: top - amount,
    width: math.max(0, width + amount * 2),
    height: math.max(0, height + amount * 2),
  );

  Rect2 union(Rect2 other) {
    if (isEmpty) return other;
    if (other.isEmpty) return this;
    final nextLeft = math.min(left, other.left);
    final nextTop = math.min(top, other.top);
    return Rect2(
      left: nextLeft,
      top: nextTop,
      width: math.max(right, other.right) - nextLeft,
      height: math.max(bottom, other.bottom) - nextTop,
    );
  }

  Rect2 transformed(TransformDelta delta) {
    return Rect2.fromPoints(<Vec2>[
      delta.apply(Vec2(left, top)),
      delta.apply(Vec2(right, top)),
      delta.apply(Vec2(right, bottom)),
      delta.apply(Vec2(left, bottom)),
    ]);
  }

  static Rect2 fromPoints(Iterable<Vec2> points) {
    final iterator = points.iterator;
    if (!iterator.moveNext()) return const Rect2.zero();
    var minX = iterator.current.x;
    var maxX = minX;
    var minY = iterator.current.y;
    var maxY = minY;
    while (iterator.moveNext()) {
      minX = math.min(minX, iterator.current.x);
      maxX = math.max(maxX, iterator.current.x);
      minY = math.min(minY, iterator.current.y);
      maxY = math.max(maxY, iterator.current.y);
    }
    return Rect2(
      left: minX,
      top: minY,
      width: maxX - minX,
      height: maxY - minY,
    );
  }

  Map<String, Object> toJson() => {
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  factory Rect2.fromJson(Map<String, Object?> json) => Rect2(
    left: _finiteDouble(json['left'], 0),
    top: _finiteDouble(json['top'], 0),
    width: math.max(0, _finiteDouble(json['width'], 0)),
    height: math.max(0, _finiteDouble(json['height'], 0)),
  );

  @override
  bool operator ==(Object other) =>
      other is Rect2 &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}

/// Object placement in page coordinates.
///
/// [x], [y], [width] and [height] describe the object's unrotated local frame.
/// [rotationRadians] is applied around that frame's centre. Keeping the local
/// frame stable means annotations remain normalized to the object and rotate
/// with it without destructive point rewrites.
final class ObjectTransform {
  const ObjectTransform({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.rotationRadians = 0,
    this.flipX = false,
    this.flipY = false,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final double rotationRadians;
  final bool flipX;
  final bool flipY;

  Rect2 get localFrame => Rect2(left: x, top: y, width: width, height: height);

  Vec2 get center => Vec2(x + width / 2, y + height / 2);

  /// Axis-aligned world bounds enclosing the possibly rotated local frame.
  Rect2 get bounds {
    if (rotationRadians.abs() < 0.0000001) return localFrame;
    return Rect2.fromPoints(<Vec2>[
      localToWorld(const Vec2(0, 0)),
      localToWorld(Vec2(width, 0)),
      localToWorld(Vec2(width, height)),
      localToWorld(Vec2(0, height)),
    ]);
  }

  Vec2 localToWorld(Vec2 point) {
    final pivot = center;
    final unrotated = Vec2(
      x + (flipX ? width - point.x : point.x),
      y + (flipY ? height - point.y : point.y),
    );
    return _rotateAround(unrotated, pivot, rotationRadians);
  }

  Vec2 worldToLocal(Vec2 point) {
    final unrotated = _rotateAround(point, center, -rotationRadians);
    final localX = unrotated.x - x;
    final localY = unrotated.y - y;
    return Vec2(
      flipX ? width - localX : localX,
      flipY ? height - localY : localY,
    );
  }

  bool containsWorld(Vec2 point, {double tolerance = 0}) {
    final local = worldToLocal(point);
    return local.x >= -tolerance &&
        local.x <= width + tolerance &&
        local.y >= -tolerance &&
        local.y <= height + tolerance;
  }

  ObjectTransform apply(TransformDelta delta) {
    final nextCenter = delta.apply(center);
    final nextWidth = math.max(0.001, width * delta.scaleX.abs());
    final nextHeight = math.max(0.001, height * delta.scaleY.abs());
    return ObjectTransform(
      x: nextCenter.x - nextWidth / 2,
      y: nextCenter.y - nextHeight / 2,
      width: nextWidth,
      height: nextHeight,
      rotationRadians: _normalizeRadians(
        rotationRadians + delta.rotationRadians,
      ),
      flipX: delta.scaleX < 0 ? !flipX : flipX,
      flipY: delta.scaleY < 0 ? !flipY : flipY,
    );
  }

  Map<String, Object> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'rotationRadians': rotationRadians,
    'flipX': flipX,
    'flipY': flipY,
  };

  factory ObjectTransform.fromJson(Map<String, Object?> json) =>
      ObjectTransform(
        x: _finiteDouble(json['x'], 0),
        y: _finiteDouble(json['y'], 0),
        width: math.max(0.001, _finiteDouble(json['width'], 1)),
        height: math.max(0.001, _finiteDouble(json['height'], 1)),
        rotationRadians: _normalizeRadians(
          _finiteDouble(json['rotationRadians'], 0),
        ),
        flipX: json['flipX'] == true,
        flipY: json['flipY'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is ObjectTransform &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.rotationRadians == rotationRadians &&
      other.flipX == flipX &&
      other.flipY == flipY;

  @override
  int get hashCode =>
      Object.hash(x, y, width, height, rotationRadians, flipX, flipY);
}

/// Translation, scale/mirroring and rotation around an anchor.
///
/// This remains a transient/command delta rather than persistent object state;
/// applying it bakes free ink points while object transforms retain their
/// angle and flip flags.
final class TransformDelta {
  const TransformDelta({
    this.dx = 0,
    this.dy = 0,
    this.scaleX = 1,
    this.scaleY = 1,
    this.anchor = Vec2.zero,
    this.rotationRadians = 0,
    this.scaleAxisRadians = 0,
  });

  final double dx;
  final double dy;
  final double scaleX;
  final double scaleY;
  final Vec2 anchor;
  final double rotationRadians;
  final double scaleAxisRadians;

  Vec2 apply(Vec2 point) {
    final aligned = _rotateAround(point, anchor, -scaleAxisRadians);
    final scaled = Vec2(
      anchor.x + (aligned.x - anchor.x) * scaleX,
      anchor.y + (aligned.y - anchor.y) * scaleY,
    );
    final worldScaled = _rotateAround(scaled, anchor, scaleAxisRadians);
    final rotated = _rotateAround(worldScaled, anchor, rotationRadians);
    return Vec2(rotated.x + dx, rotated.y + dy);
  }

  Map<String, Object> toJson() => {
    'dx': dx,
    'dy': dy,
    'scaleX': scaleX,
    'scaleY': scaleY,
    'anchor': anchor.toJson(),
    'rotationRadians': rotationRadians,
    if (scaleAxisRadians.abs() >= 0.0000001)
      'scaleAxisRadians': scaleAxisRadians,
  };

  factory TransformDelta.fromJson(Map<String, Object?> json) => TransformDelta(
    dx: _finiteDouble(json['dx'], 0),
    dy: _finiteDouble(json['dy'], 0),
    scaleX: _finiteDouble(json['scaleX'], 1),
    scaleY: _finiteDouble(json['scaleY'], 1),
    anchor: json['anchor'] is Map
        ? Vec2.fromJson(Map<String, Object?>.from(json['anchor']! as Map))
        : Vec2.zero,
    rotationRadians: _finiteDouble(json['rotationRadians'], 0),
    scaleAxisRadians: _finiteDouble(json['scaleAxisRadians'], 0),
  );
}

Vec2 _rotateAround(Vec2 point, Vec2 center, double radians) {
  if (radians.abs() < 0.0000001) return point;
  final cosine = math.cos(radians);
  final sine = math.sin(radians);
  final dx = point.x - center.x;
  final dy = point.y - center.y;
  return Vec2(
    center.x + dx * cosine - dy * sine,
    center.y + dx * sine + dy * cosine,
  );
}

double _normalizeRadians(double radians) {
  if (!radians.isFinite) return 0;
  final normalized = (radians + math.pi) % (math.pi * 2) - math.pi;
  return normalized == -math.pi ? math.pi : normalized;
}
