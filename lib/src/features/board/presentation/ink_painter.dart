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
        trustedLivePoints: true,
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
  ) {
    final width = objectSize.width;
    final height = objectSize.height;
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return;
    }
    // Map coordinates while constructing the path. Materialising an InkPoint
    // and then a complete InkStroke for every saved sample made recording a
    // large image/PDF annotation allocation-heavy and caused a visible pause
    // on every pen-up.
    _drawStroke(
      canvas,
      stroke,
      xScale: width,
      yScale: height,
      widthScale: math.min(width, height),
    );
  }

  static void _drawStroke(
    Canvas canvas,
    InkStroke stroke, {
    StrokeCap? markerStrokeCap,
    bool trustedLivePoints = false,
    double xScale = 1,
    double yScale = 1,
    double widthScale = 1,
  }) {
    // InkSessionManager sanitises every live pointer coordinate before it can
    // enter a preview stroke. Persisted/recovered data remains defensive, but
    // rescanning the bounded moving tail on every MOVE is redundant.
    final points = trustedLivePoints
        ? stroke.points
        : _renderablePoints(stroke.points, xScale: xScale, yScale: yScale);
    if (points.isEmpty) return;
    final width = _safeWidth(stroke.width * widthScale);
    if (width == null) return;
    final color = Color(stroke.colorArgb & 0xFFFFFFFF);
    final isMarker = stroke.type == InkToolType.marker;
    final paint = Paint()
      ..isAntiAlias = true
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
        Offset(points.first.x * xScale, points.first.y * yScale),
        math.max(.5, width * _pressure(points.first.pressure) / 2),
        Paint()
          ..isAntiAlias = true
          ..color = paint.color,
      );
      return;
    }

    if (stroke.type == InkToolType.straightLine) {
      paint.strokeWidth =
          width *
          (_pressure(points.first.pressure) + _pressure(points.last.pressure)) /
          2;
      canvas.drawLine(
        Offset(points.first.x * xScale, points.first.y * yScale),
        Offset(points.last.x * xScale, points.last.y * yScale),
        paint,
      );
      return;
    }

    if (stroke.type == InkToolType.dashed) {
      _drawDashed(canvas, points, paint, width, xScale: xScale, yScale: yScale);
      return;
    }

    if (isMarker) {
      paint.strokeWidth = width;
      final path = _adaptiveCenterline(points, xScale: xScale, yScale: yScale);
      canvas.drawPath(path, paint);
      return;
    }

    // Quantized pressure paths keep pressure feedback while bounding the
    // number of draw calls. A long circular stroke used to issue one drawLine
    // per point pair on every preview frame. Grouping segments by pressure
    // reduces that to at most [_pressureBucketCount] drawPath calls.
    //
    // Keep adjacent segments in one contour while their pressure bucket stays
    // unchanged. Starting every pair with moveTo makes a round-capped pen
    // tessellate two caps per sample; dense circular strokes then spend most of
    // their raster time drawing hundreds of overlapping semicircles. A small
    // one-bucket hysteresis also prevents harmless sensor noise from splitting
    // an otherwise continuous contour on every sample.
    final paths = _normalPressurePaths(points, xScale: xScale, yScale: yScale);
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

  static List<Path?> _normalPressurePaths(
    List<InkPoint> points, {
    double xScale = 1,
    double yScale = 1,
  }) {
    final paths = List<Path?>.filled(_pressureBucketCount, null);
    int? previousBucket;
    var cursorX = points.first.x * xScale;
    var cursorY = points.first.y * yScale;
    for (var index = 1; index < points.length - 1; index++) {
      final previous = points[index - 1];
      final current = points[index];
      final next = points[index + 1];
      final pressure =
          (_pressure(previous.pressure) + _pressure(current.pressure)) / 2;
      var bucket = _pressureBucket(pressure);
      final lastBucket = previousBucket;
      if (lastBucket != null && (bucket - lastBucket).abs() <= 1) {
        bucket = lastBucket;
      }
      final path = paths[bucket] ??= Path();
      if (bucket != lastBucket) path.moveTo(cursorX, cursorY);

      final currentX = current.x * xScale;
      final currentY = current.y * yScale;
      final nextX = next.x * xScale;
      final nextY = next.y * yScale;
      final smoothing = _adaptiveSmoothingFactor(
        previous.x * xScale,
        previous.y * yScale,
        currentX,
        currentY,
        nextX,
        nextY,
      );
      if (smoothing > 0) {
        cursorX = currentX + (nextX - currentX) * smoothing;
        cursorY = currentY + (nextY - currentY) * smoothing;
        path.quadraticBezierTo(currentX, currentY, cursorX, cursorY);
      } else {
        cursorX = currentX;
        cursorY = currentY;
        path.lineTo(cursorX, cursorY);
      }
      previousBucket = bucket;
    }

    final previous = points[points.length - 2];
    final current = points.last;
    final pressure =
        (_pressure(previous.pressure) + _pressure(current.pressure)) / 2;
    var bucket = _pressureBucket(pressure);
    final lastBucket = previousBucket;
    if (lastBucket != null && (bucket - lastBucket).abs() <= 1) {
      bucket = lastBucket;
    }
    final path = paths[bucket] ??= Path();
    if (bucket != lastBucket) path.moveTo(cursorX, cursorY);
    path.lineTo(current.x * xScale, current.y * yScale);
    return paths;
  }

  static int _pressureBucket(double pressure) =>
      ((pressure - _minimumPressure) /
              (1 - _minimumPressure) *
              (_pressureBucketCount - 1))
          .round()
          .clamp(0, _pressureBucketCount - 1);

  /// Builds a one-command-per-edge centreline while smoothing only gradual,
  /// evenly sampled direction changes.
  ///
  /// The quadratic endpoint stays close to the measured vertex. Right angles,
  /// reversals and strongly uneven packet gaps remain exact line segments, so
  /// handwriting corners are not pulled into generic rounded arcs. No
  /// intermediate Offset or point list is allocated.
  static Path _adaptiveCenterline(
    List<InkPoint> points, {
    double xScale = 1,
    double yScale = 1,
    int step = 1,
  }) {
    final path = Path();
    if (points.isEmpty) return path;
    final safeStep = math.max(1, step);
    path.moveTo(points.first.x * xScale, points.first.y * yScale);
    var previousIndex = 0;
    var index = math.min(safeStep, points.length - 1);
    while (index < points.length - 1) {
      final nextIndex = math.min(index + safeStep, points.length - 1);
      final previous = points[previousIndex];
      final current = points[index];
      final next = points[nextIndex];
      final previousX = previous.x * xScale;
      final previousY = previous.y * yScale;
      final currentX = current.x * xScale;
      final currentY = current.y * yScale;
      final nextX = next.x * xScale;
      final nextY = next.y * yScale;
      final smoothing = _adaptiveSmoothingFactor(
        previousX,
        previousY,
        currentX,
        currentY,
        nextX,
        nextY,
      );
      if (smoothing > 0) {
        path.quadraticBezierTo(
          currentX,
          currentY,
          currentX + (nextX - currentX) * smoothing,
          currentY + (nextY - currentY) * smoothing,
        );
      } else {
        path.lineTo(currentX, currentY);
      }
      previousIndex = index;
      index = nextIndex;
    }
    if (points.length > 1) {
      path.lineTo(points.last.x * xScale, points.last.y * yScale);
    }
    return path;
  }

  /// Returns zero for a corner that must stay geometrically exact, otherwise
  /// the small fraction of the outgoing edge used as the curve endpoint.
  /// Squared-length comparisons avoid an `acos`/`sqrt` per point on the live
  /// tail. The sampler already bounds normal packet gaps, while the ratio gate
  /// keeps recovered or unusually sparse input defensive.
  static double _adaptiveSmoothingFactor(
    double previousX,
    double previousY,
    double currentX,
    double currentY,
    double nextX,
    double nextY,
  ) {
    final incomingX = currentX - previousX;
    final incomingY = currentY - previousY;
    final outgoingX = nextX - currentX;
    final outgoingY = nextY - currentY;
    final incomingLengthSquared = incomingX * incomingX + incomingY * incomingY;
    final outgoingLengthSquared = outgoingX * outgoingX + outgoingY * outgoingY;
    if (!incomingLengthSquared.isFinite ||
        !outgoingLengthSquared.isFinite ||
        incomingLengthSquared <= _smoothingLengthEpsilonSquared ||
        outgoingLengthSquared <= _smoothingLengthEpsilonSquared ||
        incomingLengthSquared > outgoingLengthSquared * _maximumLengthRatio ||
        outgoingLengthSquared > incomingLengthSquared * _maximumLengthRatio) {
      return 0;
    }

    final dot = incomingX * outgoingX + incomingY * outgoingY;
    if (!dot.isFinite || dot <= 0) return 0;
    final lengthProduct = incomingLengthSquared * outgoingLengthSquared;
    final cross = incomingX * outgoingY - incomingY * outgoingX;
    final crossSquared = cross * cross;
    // A quadratic command cannot improve a truly straight run. Keeping those
    // as lineTo commands is cheaper for both Skia and Impeller, and extremely
    // dense curves already look continuous below this angular threshold.
    if (!crossSquared.isFinite ||
        crossSquared <= lengthProduct * _minimumCurvatureSineSquared) {
      return 0;
    }
    final dotSquared = dot * dot;
    if (dotSquared < lengthProduct * _minimumSmoothCosineSquared) return 0;
    if (dotSquared >= lengthProduct * _gentleCosineSquared) {
      return _gentleSmoothingFraction;
    }
    if (dotSquared >= lengthProduct * _moderateCosineSquared) {
      return _moderateSmoothingFraction;
    }
    return _cornerSmoothingFraction;
  }

  @visibleForTesting
  static ({int curves, int lines}) debugAdaptiveCommandCounts(
    List<InkPoint> points, {
    double xScale = 1,
    double yScale = 1,
  }) {
    if (points.length < 2) return (curves: 0, lines: 0);
    var curves = 0;
    var lines = 1; // The final measured endpoint is always an exact lineTo.
    for (var index = 1; index < points.length - 1; index++) {
      final previous = points[index - 1];
      final current = points[index];
      final next = points[index + 1];
      if (_adaptiveSmoothingFactor(
            previous.x * xScale,
            previous.y * yScale,
            current.x * xScale,
            current.y * yScale,
            next.x * xScale,
            next.y * yScale,
          ) >
          0) {
        curves++;
      } else {
        lines++;
      }
    }
    return (curves: curves, lines: lines);
  }

  @visibleForTesting
  static Path debugAdaptiveCenterline(List<InkPoint> points) =>
      _adaptiveCenterline(points);

  @visibleForTesting
  static int debugNormalPressureContourCount(List<InkPoint> points) {
    if (points.length < 2) return 0;
    return _normalPressurePaths(points).fold<int>(
      0,
      (count, path) => count + (path?.computeMetrics().length ?? 0),
    );
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
      ..isAntiAlias = true
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
    Path path;
    if (stroke.type == InkToolType.straightLine) {
      path = Path()
        ..moveTo(points.first.x, points.first.y)
        ..lineTo(points.last.x, points.last.y);
    } else {
      final step = math.max(
        1,
        (points.length / DashedInkPathBuilder.maxPathCommands).ceil(),
      );
      path = _adaptiveCenterline(points, step: step);
    }
    canvas.drawPath(path, halo);
  }

  static void _drawDashed(
    Canvas canvas,
    List<InkPoint> points,
    Paint paint,
    double width, {
    double xScale = 1,
    double yScale = 1,
  }) {
    final dash = math.max(5.0, width * 2.1);
    final gap = math.max(3.0, width * 1.25);
    final result = DashedInkPathBuilder.buildMapped<InkPoint>(
      points: points,
      xOf: _inkPointX,
      yOf: _inkPointY,
      dashLength: dash,
      gapLength: gap,
      xScale: xScale,
      yScale: yScale,
    );
    if (result.commandCount == 0) return;
    var pressureSum = 0.0;
    for (final point in points) {
      pressureSum += _pressure(point.pressure);
    }
    final averagePressure = pressureSum / points.length;
    paint.strokeWidth = width * averagePressure;
    canvas.drawPath(result.path, paint);
  }

  static List<InkPoint> _renderablePoints(
    List<InkPoint> points, {
    double xScale = 1,
    double yScale = 1,
  }) {
    var allRenderable = true;
    for (final point in points) {
      if (!_isRenderable(point, xScale: xScale, yScale: yScale)) {
        allRenderable = false;
        break;
      }
    }
    if (allRenderable) return points;
    return points
        .where((point) => _isRenderable(point, xScale: xScale, yScale: yScale))
        .toList(growable: false);
  }

  static bool _isRenderable(
    InkPoint point, {
    required double xScale,
    required double yScale,
  }) {
    final x = point.x * xScale;
    final y = point.y * yScale;
    return x.isFinite &&
        y.isFinite &&
        x.abs() <= DashedInkPathBuilder.maxCoordinateMagnitude &&
        y.abs() <= DashedInkPathBuilder.maxCoordinateMagnitude;
  }

  static double _inkPointX(InkPoint point) => point.x;

  static double _inkPointY(InkPoint point) => point.y;

  static double? _safeWidth(double width) {
    if (!width.isFinite || width <= 0) return null;
    return width.clamp(.0001, 512.0);
  }

  static const int _pressureBucketCount = 12;
  static const double _minimumPressure = .52;
  static const double _smoothingLengthEpsilonSquared = 1e-8;
  static const double _maximumLengthRatio = 6;
  static const double _minimumSmoothCosineSquared = .5; // cos(45°)²
  static const double _minimumCurvatureSineSquared = .00001;
  static const double _moderateCosineSquared = .5625; // cos(41.4°)²
  static const double _gentleCosineSquared = .8464; // cos(23.1°)²
  static const double _cornerSmoothingFraction = .18;
  static const double _moderateSmoothingFraction = .27;
  static const double _gentleSmoothingFraction = .36;

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
