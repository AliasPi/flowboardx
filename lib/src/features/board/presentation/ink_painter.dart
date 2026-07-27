import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../domain/model/geometry.dart';
import '../../../domain/model/ink.dart';
import 'dashed_ink_path.dart';

class InkPainter extends CustomPainter {
  const InkPainter({
    required this.strokes,
    required this.worldToScreenScale,
    required this.worldToScreenOffset,
    this.worldClip,
    this.selectionIds = const <String>{},
  });

  final List<InkStroke> strokes;
  final double worldToScreenScale;
  final Offset worldToScreenOffset;
  final Rect2? worldClip;
  final Set<String> selectionIds;

  @override
  void paint(Canvas canvas, Size size) {
    if (worldToScreenScale <= 0 ||
        !worldToScreenScale.isFinite ||
        !worldToScreenOffset.dx.isFinite ||
        !worldToScreenOffset.dy.isFinite) {
      return;
    }
    canvas.save();
    canvas.translate(worldToScreenOffset.dx, worldToScreenOffset.dy);
    canvas.scale(worldToScreenScale);
    for (final stroke in strokes) {
      if (stroke.points.isEmpty ||
          (worldClip != null && !stroke.bounds.intersects(worldClip!))) {
        continue;
      }
      if (selectionIds.contains(stroke.id)) {
        _drawSelectionHalo(canvas, stroke, worldToScreenScale);
      }
      _drawStroke(canvas, stroke);
    }
    canvas.restore();
  }

  static void drawStroke(Canvas canvas, InkStroke stroke) =>
      _drawStroke(canvas, stroke);

  static void drawSelectionHalo(
    Canvas canvas,
    InkStroke stroke,
    double worldToScreenScale,
  ) => _drawSelectionHalo(canvas, stroke, worldToScreenScale);

  /// Draws one bounded live-preview chunk.
  ///
  /// Marker chunks use flat caps while the pointer is down. Adjacent cached
  /// chunks can therefore meet without repeatedly alpha-blending square end
  /// caps into the dark dots that used to appear on long marker strokes.
  static void drawLivePreviewStroke(Canvas canvas, InkStroke stroke) =>
      _drawStroke(
        canvas,
        stroke,
        markerStrokeCap: stroke.type == InkToolType.marker
            ? StrokeCap.butt
            : null,
      );

  /// Maps an object-local annotation (`0..1` in both axes) into the object's
  /// paint space without applying a non-uniform canvas scale to the pen tip.
  ///
  /// A plain `canvas.scale(width, height)` turns a round dot into an ellipse
  /// whenever an image, PDF or table is not square. Keeping point scaling and
  /// thickness scaling separate preserves a circular nib while the ink still
  /// follows the object's position and size.
  static InkStroke objectLocalStrokeToCanvas(
    InkStroke stroke,
    Size objectSize,
  ) {
    final width = objectSize.width;
    final height = objectSize.height;
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return stroke.copyWith(points: const <InkPoint>[]);
    }
    final thicknessScale = math.min(width, height);
    return stroke.copyWith(
      points: stroke.points.map(
        (point) => InkPoint(
          x: point.x * width,
          y: point.y * height,
          pressure: point.pressure,
          timestampMicros: point.timestampMicros,
          tiltX: point.tiltX,
          tiltY: point.tiltY,
        ),
      ),
      width: stroke.width * thicknessScale,
    );
  }

  static void drawObjectLocalStroke(
    Canvas canvas,
    InkStroke stroke,
    Size objectSize,
  ) => _drawStroke(canvas, objectLocalStrokeToCanvas(stroke, objectSize));

  static void _drawStroke(
    Canvas canvas,
    InkStroke stroke, {
    StrokeCap? markerStrokeCap,
  }) {
    final points = _renderablePoints(stroke.points);
    if (points.isEmpty) return;
    final width = _safeWidth(stroke.width);
    if (width == null) return;
    final color = Color(stroke.colorArgb & 0xFFFFFFFF);
    final isMarker = stroke.type == InkToolType.marker;
    final paint = Paint()
      ..color = isMarker
          ? color.withValues(alpha: color.a < .999 ? color.a : .36)
          : color
      ..strokeCap = isMarker
          ? markerStrokeCap ?? StrokeCap.square
          : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..blendMode = isMarker ? BlendMode.multiply : BlendMode.srcOver;

    if (points.length == 1) {
      canvas.drawCircle(
        Offset(points.first.x, points.first.y),
        math.max(.5, width * _pressure(points.first.pressure) / 2),
        Paint()..color = paint.color,
      );
      return;
    }

    if (stroke.type == InkToolType.straightLine) {
      paint.strokeWidth =
          width *
          (_pressure(points.first.pressure) + _pressure(points.last.pressure)) /
          2;
      canvas.drawLine(
        Offset(points.first.x, points.first.y),
        Offset(points.last.x, points.last.y),
        paint,
      );
      return;
    }

    if (stroke.type == InkToolType.dashed) {
      _drawDashed(canvas, points, paint, width);
      return;
    }

    if (isMarker) {
      paint.strokeWidth = width;
      final path = Path()..moveTo(points.first.x, points.first.y);
      for (var index = 1; index < points.length - 1; index++) {
        final current = points[index];
        final next = points[index + 1];
        path.quadraticBezierTo(
          current.x,
          current.y,
          (current.x + next.x) / 2,
          (current.y + next.y) / 2,
        );
      }
      path.lineTo(points.last.x, points.last.y);
      canvas.drawPath(path, paint);
      return;
    }

    // Quantized pressure paths keep pressure feedback while bounding the
    // number of draw calls. A long circular stroke used to issue one drawLine
    // per point pair on every preview frame. Grouping segments by pressure
    // reduces that to at most [_pressureBucketCount] drawPath calls.
    final paths = List<Path?>.filled(_pressureBucketCount, null);
    for (var i = 1; i < points.length; i++) {
      final previous = points[i - 1];
      final current = points[i];
      final pressure =
          (_pressure(previous.pressure) + _pressure(current.pressure)) / 2;
      final bucket =
          ((pressure - _minimumPressure) /
                  (1 - _minimumPressure) *
                  (_pressureBucketCount - 1))
              .round()
              .clamp(0, _pressureBucketCount - 1);
      final path = paths[bucket] ??= Path();
      path
        ..moveTo(previous.x, previous.y)
        ..lineTo(current.x, current.y);
    }
    for (var bucket = 0; bucket < paths.length; bucket++) {
      final path = paths[bucket];
      if (path == null) continue;
      final pressure =
          _minimumPressure +
          (1 - _minimumPressure) * bucket / (_pressureBucketCount - 1);
      paint.strokeWidth = width * pressure;
      canvas.drawPath(path, paint);
    }
  }

  static void _drawSelectionHalo(
    Canvas canvas,
    InkStroke stroke,
    double worldToScreenScale,
  ) {
    final points = _renderablePoints(stroke.points);
    final width = _safeWidth(stroke.width);
    if (points.isEmpty || width == null) return;
    final halo = Paint()
      ..color = const Color(0xFF20DDB2).withValues(alpha: .42)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = width + 12 / worldToScreenScale;
    if (points.length == 1) {
      canvas.drawCircle(
        Offset(points.first.x, points.first.y),
        width / 2 + 6 / worldToScreenScale,
        Paint()..color = halo.color,
      );
      return;
    }
    final path = Path()..moveTo(points.first.x, points.first.y);
    if (stroke.type == InkToolType.straightLine) {
      path.lineTo(points.last.x, points.last.y);
    } else {
      final step = math.max(
        1,
        (points.length / DashedInkPathBuilder.maxPathCommands).ceil(),
      );
      var lastDrawnIndex = 0;
      for (var index = step; index < points.length; index += step) {
        final point = points[index];
        path.lineTo(point.x, point.y);
        lastDrawnIndex = index;
      }
      if (lastDrawnIndex != points.length - 1) {
        final point = points.last;
        path.lineTo(point.x, point.y);
      }
    }
    canvas.drawPath(path, halo);
  }

  static void _drawDashed(
    Canvas canvas,
    List<InkPoint> points,
    Paint paint,
    double width,
  ) {
    final dash = math.max(5.0, width * 2.1);
    final gap = math.max(3.0, width * 1.25);
    final result = DashedInkPathBuilder.build(
      points: points.map((point) => Offset(point.x, point.y)),
      dashLength: dash,
      gapLength: gap,
    );
    if (result.commandCount == 0) return;
    final averagePressure =
        points.fold<double>(
          0,
          (sum, point) => sum + _pressure(point.pressure),
        ) /
        points.length;
    paint.strokeWidth = width * averagePressure;
    canvas.drawPath(result.path, paint);
  }

  static List<InkPoint> _renderablePoints(List<InkPoint> points) {
    var allRenderable = true;
    for (final point in points) {
      if (!_isRenderable(point)) {
        allRenderable = false;
        break;
      }
    }
    if (allRenderable) return points;
    return points.where(_isRenderable).toList(growable: false);
  }

  static bool _isRenderable(InkPoint point) =>
      point.x.isFinite &&
      point.y.isFinite &&
      point.x.abs() <= DashedInkPathBuilder.maxCoordinateMagnitude &&
      point.y.abs() <= DashedInkPathBuilder.maxCoordinateMagnitude;

  static double? _safeWidth(double width) {
    if (!width.isFinite || width <= 0) return null;
    return width.clamp(.0001, 512.0);
  }

  static const int _pressureBucketCount = 12;
  static const double _minimumPressure = .52;

  static double _pressure(double pressure) =>
      _minimumPressure +
      (pressure.isFinite ? pressure.clamp(0, 1) : 1) * (1 - _minimumPressure);

  @override
  bool shouldRepaint(covariant InkPainter oldDelegate) {
    if (oldDelegate.worldToScreenScale != worldToScreenScale ||
        oldDelegate.worldToScreenOffset != worldToScreenOffset ||
        oldDelegate.worldClip != worldClip ||
        !setEquals(oldDelegate.selectionIds, selectionIds) ||
        oldDelegate.strokes.length != strokes.length) {
      return true;
    }
    for (var index = 0; index < strokes.length; index++) {
      if (!identical(oldDelegate.strokes[index], strokes[index])) return true;
    }
    return false;
  }
}
