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
    final first = delta.apply(Vec2(left, top));
    final second = delta.apply(Vec2(right, bottom));
    final nextLeft = math.min(first.x, second.x);
    final nextTop = math.min(first.y, second.y);
    return Rect2(
      left: nextLeft,
      top: nextTop,
      width: (second.x - first.x).abs(),
      height: (second.y - first.y).abs(),
    );
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

/// Object placement in page coordinates. Rotation is deliberately unsupported.
final class ObjectTransform {
  const ObjectTransform({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  Rect2 get bounds => Rect2(left: x, top: y, width: width, height: height);

  ObjectTransform apply(TransformDelta delta) {
    final result = bounds.transformed(delta);
    return ObjectTransform(
      x: result.left,
      y: result.top,
      width: result.width,
      height: result.height,
    );
  }

  Map<String, Object> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  factory ObjectTransform.fromJson(Map<String, Object?> json) =>
      ObjectTransform(
        x: _finiteDouble(json['x'], 0),
        y: _finiteDouble(json['y'], 0),
        width: math.max(0.001, _finiteDouble(json['width'], 1)),
        height: math.max(0.001, _finiteDouble(json['height'], 1)),
      );

  @override
  bool operator ==(Object other) =>
      other is ObjectTransform &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);
}

/// A translation and scale around an anchor, suitable for selection transforms.
final class TransformDelta {
  const TransformDelta({
    this.dx = 0,
    this.dy = 0,
    this.scaleX = 1,
    this.scaleY = 1,
    this.anchor = Vec2.zero,
  });

  final double dx;
  final double dy;
  final double scaleX;
  final double scaleY;
  final Vec2 anchor;

  Vec2 apply(Vec2 point) => Vec2(
    anchor.x + (point.x - anchor.x) * scaleX + dx,
    anchor.y + (point.y - anchor.y) * scaleY + dy,
  );

  Map<String, Object> toJson() => {
    'dx': dx,
    'dy': dy,
    'scaleX': scaleX,
    'scaleY': scaleY,
    'anchor': anchor.toJson(),
  };

  factory TransformDelta.fromJson(Map<String, Object?> json) => TransformDelta(
    dx: _finiteDouble(json['dx'], 0),
    dy: _finiteDouble(json['dy'], 0),
    scaleX: _finiteDouble(json['scaleX'], 1),
    scaleY: _finiteDouble(json['scaleY'], 1),
    anchor: json['anchor'] is Map
        ? Vec2.fromJson(Map<String, Object?>.from(json['anchor']! as Map))
        : Vec2.zero,
  );
}
