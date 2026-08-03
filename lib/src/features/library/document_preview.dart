import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/model/board_object.dart';
import '../../domain/model/document.dart';
import '../../domain/model/geometry.dart';
import '../../domain/model/ink.dart';
import '../../domain/model/scene_order.dart';
import '../board/presentation/dashed_ink_path.dart';
import '../editor/text_object_layout.dart';

/// Lightweight, asset-independent page preview. Raster assets intentionally use
/// recognizable placeholders while their real transforms and annotations are
/// retained, so a library grid never decodes dozens of large images or PDFs.
class DocumentPagePreview extends StatelessWidget {
  const DocumentPagePreview({
    required this.page,
    super.key,
    this.backgroundColor = const Color(0xFFF8F7F2),
  });

  final BoardPage page;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Vorschau ${page.name}',
      image: true,
      child: RepaintBoundary(
        child: CustomPaint(
          key: ValueKey<String>('document-preview-${page.id}'),
          painter: DocumentPagePreviewPainter(
            page: page,
            backgroundColor: backgroundColor,
          ),
          isComplex: true,
        ),
      ),
    );
  }
}

class DocumentPagePreviewPainter extends CustomPainter {
  const DocumentPagePreviewPainter({
    required this.page,
    this.backgroundColor = const Color(0xFFF8F7F2),
  });

  static const Size referenceViewport = Size(1920, 1080);
  static const int maxPreviewStrokes = 320;
  static const int maxPointsPerStroke = 140;
  static const double maxPreviewStrokeWidth = 512;

  final BoardPage page;
  final Color backgroundColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final viewport = page.viewport.normalized();
    final worldView = Rect.fromLTWH(
      -viewport.offsetX / viewport.zoom,
      -viewport.offsetY / viewport.zoom,
      referenceViewport.width / viewport.zoom,
      referenceViewport.height / viewport.zoom,
    );
    final scale = math.min(
      size.width / worldView.width,
      size.height / worldView.height,
    );
    final contentWidth = worldView.width * scale;
    final contentHeight = worldView.height * scale;
    canvas.translate(
      (size.width - contentWidth) / 2 - worldView.left * scale,
      (size.height - contentHeight) / 2 - worldView.top * scale,
    );
    canvas.scale(scale);

    _paintBoardGrid(canvas, worldView, scale);
    _paintTemplate(canvas, scale);

    final annotations = <String, ObjectInkLayer>{
      for (final layer in page.annotationLayers.where((layer) => layer.visible))
        layer.objectId: layer,
    };
    final scene = orderedBoardSceneItems(
      objects: page.objects,
      strokes: page.strokes,
    );
    var paintedFreeStrokes = 0;
    for (final item in scene) {
      final stroke = item.stroke;
      if (stroke != null) {
        if (paintedFreeStrokes++ < maxPreviewStrokes) {
          _paintStroke(canvas, stroke, scale);
        }
        continue;
      }
      final sourceObject = item.object!;
      final object = sourceObject is TextObject
          ? TextObjectLayout.upgradeLegacyFrame(sourceObject)
          : sourceObject;
      _paintObject(canvas, object, scale);
      final layer = annotations[object.id];
      final transform = object.transform;
      if (layer != null && _validTransform(transform)) {
        canvas.save();
        _applyObjectOrientation(canvas, transform);
        canvas.translate(transform.x, transform.y);
        final objectSize = Size(transform.width, transform.height);
        final count = math.min(layer.strokes.length, maxPreviewStrokes);
        for (var index = 0; index < count; index++) {
          _paintStroke(
            canvas,
            layer.strokes[index],
            scale,
            xScale: objectSize.width,
            yScale: objectSize.height,
            widthScale: math.min(objectSize.width, objectSize.height),
          );
        }
        canvas.restore();
      }
    }

    canvas.restore();
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x24000000),
    );
  }

  void _paintBoardGrid(Canvas canvas, Rect worldView, double scale) {
    final minorWidth = math.max(.7 / scale, .65);
    final majorWidth = math.max(1 / scale, 1.1);
    final minor = Paint()
      ..color = const Color(0x1F66716B)
      ..strokeWidth = minorWidth;
    final major = Paint()
      ..color = const Color(0x3A66716B)
      ..strokeWidth = majorWidth;

    const minorStep = 192.0;
    var x = (worldView.left / minorStep).floor() * minorStep;
    var minorLines = 0;
    while (x <= worldView.right && minorLines++ < 80) {
      canvas.drawLine(
        Offset(x, worldView.top),
        Offset(x, worldView.bottom),
        minor,
      );
      x += minorStep;
    }
    var y = (worldView.top / minorStep).floor() * minorStep;
    minorLines = 0;
    while (y <= worldView.bottom && minorLines++ < 80) {
      canvas.drawLine(
        Offset(worldView.left, y),
        Offset(worldView.right, y),
        minor,
      );
      y += minorStep;
    }

    const boardWidth = 1920.0;
    const boardHeight = 1080.0;
    x = (worldView.left / boardWidth).floor() * boardWidth;
    var majorLines = 0;
    while (x <= worldView.right && majorLines++ < 12) {
      canvas.drawLine(
        Offset(x, worldView.top),
        Offset(x, worldView.bottom),
        major,
      );
      x += boardWidth;
    }
    y = (worldView.top / boardHeight).floor() * boardHeight;
    majorLines = 0;
    while (y <= worldView.bottom && majorLines++ < 12) {
      canvas.drawLine(
        Offset(worldView.left, y),
        Offset(worldView.right, y),
        major,
      );
      y += boardHeight;
    }
  }

  void _paintTemplate(Canvas canvas, double scale) {
    final template = page.template;
    if (template == null) return;
    final center = const Offset(960, 540);
    final lineWidth = math.max(1.4 / scale, 3.0);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth
      ..color = const Color(0x704D7EA8);
    switch (template.kind) {
      case TemplateKind.overlappingCircles:
        canvas.drawCircle(center.translate(-220, 0), 310, line);
        canvas.drawCircle(center.translate(220, 0), 310, line);
      case TemplateKind.vennDiagram:
        canvas.drawCircle(center.translate(-190, -80), 270, line);
        canvas.drawCircle(center.translate(190, -80), 270, line);
        canvas.drawCircle(center.translate(0, 190), 270, line);
      case TemplateKind.mindMap:
        final bubbles = <Offset>[
          center.translate(-520, -260),
          center.translate(0, -350),
          center.translate(520, -260),
          center.translate(-520, 260),
          center.translate(0, 350),
          center.translate(520, 260),
        ];
        for (final bubble in bubbles) {
          final vector = bubble - center;
          final distance = math.max(1.0, vector.distance);
          final direction = vector / distance;
          canvas.drawLine(
            center + Offset(direction.dx * 180, direction.dy * 95),
            bubble - Offset(direction.dx * 140, direction.dy * 75),
            line,
          );
          canvas.drawOval(
            Rect.fromCenter(center: bubble, width: 280, height: 150),
            line,
          );
        }
        canvas.drawOval(
          Rect.fromCenter(center: center, width: 360, height: 190),
          line,
        );
      case TemplateKind.primarySchoolLines:
        final blue = Paint()
          ..color = const Color(0x554E8FC7)
          ..strokeWidth = math.max(1 / scale, 2);
        final red = Paint()
          ..color = const Color(0x55D35757)
          ..strokeWidth = math.max(1 / scale, 2);
        for (var lineY = 120.0; lineY <= 1030; lineY += 120) {
          canvas.drawLine(Offset(0, lineY), Offset(1920, lineY), blue);
          canvas.drawLine(
            Offset(0, lineY + 42),
            Offset(1920, lineY + 42),
            blue,
          );
        }
        canvas.drawLine(const Offset(180, 0), const Offset(180, 1080), red);
    }
  }

  void _paintObject(Canvas canvas, BoardObject object, double scale) {
    final transform = object.transform;
    if (!_validTransform(transform)) return;
    final rect = Rect.fromLTWH(
      transform.x,
      transform.y,
      transform.width,
      transform.height,
    );
    canvas.save();
    _applyObjectOrientation(canvas, transform);
    switch (object) {
      case final ShapeObject shape:
        _paintShape(canvas, rect, shape, scale);
      case final ImageObject image:
        _paintAssetPlaceholder(
          canvas,
          rect,
          label: 'BILD',
          accent: const Color(0xFF4A8FB8),
          opacity: image.opacity,
          imageGlyph: true,
          scale: scale,
        );
      case final PdfObject pdf:
        _paintAssetPlaceholder(
          canvas,
          rect,
          label: 'PDF',
          accent: const Color(0xFFD85454),
          opacity: pdf.opacity,
          imageGlyph: false,
          scale: scale,
        );
      case final TableObject table:
        _paintTable(canvas, rect, table, scale);
      case final CoverObject cover:
        _paintCover(canvas, rect, cover);
      case final TextObject text:
        _paintText(canvas, rect, text, scale);
    }
    canvas.restore();
  }

  void _applyObjectOrientation(Canvas canvas, ObjectTransform transform) {
    if (transform.rotationRadians.abs() < .0000001 &&
        !transform.flipX &&
        !transform.flipY) {
      return;
    }
    final center = Offset(
      transform.x + transform.width / 2,
      transform.y + transform.height / 2,
    );
    canvas
      ..translate(center.dx, center.dy)
      ..rotate(transform.rotationRadians)
      ..scale(transform.flipX ? -1 : 1, transform.flipY ? -1 : 1)
      ..translate(-center.dx, -center.dy);
  }

  void _paintShape(Canvas canvas, Rect rect, ShapeObject shape, double scale) {
    final strokeWidth = shape.strokeWidth.isFinite && shape.strokeWidth > 0
        ? shape.strokeWidth
        : 1.0;
    final inset = math.max(strokeWidth / 2, .5 / scale);
    final target = rect.deflate(math.min(inset, rect.shortestSide / 3));
    final path = switch (shape.shape) {
      ShapeKind.rectangle => Path()..addRect(target),
      ShapeKind.circle || ShapeKind.ellipse => Path()..addOval(target),
      ShapeKind.triangle =>
        Path()
          ..moveTo(target.center.dx, target.top)
          ..lineTo(target.right, target.bottom)
          ..lineTo(target.left, target.bottom)
          ..close(),
    };
    final fill = _withObjectOpacity(Color(shape.fillArgb), shape.opacity);
    if (fill.a > 0) canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(strokeWidth, 1 / scale)
        ..color = _withObjectOpacity(Color(shape.strokeArgb), shape.opacity),
    );
  }

  void _paintAssetPlaceholder(
    Canvas canvas,
    Rect rect, {
    required String label,
    required Color accent,
    required double opacity,
    required bool imageGlyph,
    required double scale,
  }) {
    final safeOpacity = _safeOpacity(opacity);
    canvas.drawRect(
      rect,
      Paint()..color = const Color(0xFFE3E7E5).withValues(alpha: safeOpacity),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1 / scale, 1.5)
        ..color = accent.withValues(alpha: safeOpacity * .82),
    );
    if (imageGlyph) {
      final mountain = Path()
        ..moveTo(rect.left + rect.width * .12, rect.bottom - rect.height * .16)
        ..lineTo(rect.left + rect.width * .42, rect.top + rect.height * .43)
        ..lineTo(rect.left + rect.width * .59, rect.top + rect.height * .62)
        ..lineTo(rect.left + rect.width * .75, rect.top + rect.height * .34)
        ..lineTo(rect.right - rect.width * .08, rect.bottom - rect.height * .16)
        ..close();
      canvas.drawPath(
        mountain,
        Paint()..color = accent.withValues(alpha: safeOpacity * .45),
      );
      canvas.drawCircle(
        rect.topRight.translate(-rect.width * .2, rect.height * .22),
        rect.shortestSide * .08,
        Paint()..color = accent.withValues(alpha: safeOpacity * .75),
      );
    }
    _paintCenteredLabel(canvas, rect, label, accent, safeOpacity, scale);
  }

  void _paintTable(Canvas canvas, Rect rect, TableObject table, double scale) {
    final opacity = _safeOpacity(table.opacity);
    canvas.drawRect(
      rect,
      Paint()..color = const Color(0xFFFDFDFC).withValues(alpha: opacity),
    );
    final grid = Paint()
      ..color = _withObjectOpacity(Color(table.gridColorArgb), opacity)
      ..strokeWidth = math.max(
        table.gridWidth.isFinite && table.gridWidth > 0 ? table.gridWidth : 1.0,
        1 / scale,
      );
    final renderedColumns = math.min(table.columns, 18);
    final renderedRows = math.min(table.rows, 18);
    for (var column = 1; column < renderedColumns; column++) {
      final x = rect.left + rect.width * column / renderedColumns;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
    }
    for (var row = 1; row < renderedRows; row++) {
      final y = rect.top + rect.height * row / renderedRows;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
    }
  }

  void _paintCover(Canvas canvas, Rect rect, CoverObject cover) {
    final reveal = cover.reveal.isFinite ? cover.reveal.clamp(0.0, 1.0) : 0.0;
    final covered = switch (cover.direction) {
      RevealDirection.leftToRight => Rect.fromLTRB(
        rect.left + rect.width * reveal,
        rect.top,
        rect.right,
        rect.bottom,
      ),
      RevealDirection.rightToLeft => Rect.fromLTRB(
        rect.left,
        rect.top,
        rect.right - rect.width * reveal,
        rect.bottom,
      ),
      RevealDirection.topToBottom => Rect.fromLTRB(
        rect.left,
        rect.top + rect.height * reveal,
        rect.right,
        rect.bottom,
      ),
      RevealDirection.bottomToTop => Rect.fromLTRB(
        rect.left,
        rect.top,
        rect.right,
        rect.bottom - rect.height * reveal,
      ),
    };
    canvas.drawRect(
      covered,
      Paint()
        ..color = _withObjectOpacity(Color(cover.colorArgb), cover.opacity),
    );
  }

  void _paintText(Canvas canvas, Rect rect, TextObject text, double _) {
    if (text.text.isEmpty) return;
    final previewText = text.copyWith(
      colorArgb: _withObjectOpacity(
        Color(text.colorArgb),
        text.opacity,
      ).toARGB32(),
    );
    final insets = TextObjectLayout.contentInsetsFor(previewText);
    final content = Rect.fromLTRB(
      rect.left + insets.left,
      rect.top + insets.top,
      rect.right - insets.right,
      rect.bottom - insets.bottom,
    );
    if (content.isEmpty) return;
    final painter = TextObjectLayout.createPainter(previewText)
      ..layout(maxWidth: content.width);
    final x = switch (text.alignment) {
      BoardTextAlign.left => content.left,
      BoardTextAlign.center => content.center.dx - painter.width / 2,
      BoardTextAlign.right => content.right - painter.width,
    };
    canvas.save();
    canvas.clipRect(rect);
    painter.paint(canvas, Offset(x, content.top));
    canvas.restore();
    painter.dispose();
  }

  void _paintCenteredLabel(
    Canvas canvas,
    Rect rect,
    String label,
    Color color,
    double opacity,
    double scale,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          inherit: false,
          color: color.withValues(alpha: opacity * .9),
          fontSize: math.max(10 / scale, rect.shortestSide * .15),
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2 / scale,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: rect.width * .8);
    painter.paint(
      canvas,
      rect.center - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
  }

  void _paintStroke(
    Canvas canvas,
    InkStroke stroke,
    double scale, {
    double xScale = 1,
    double yScale = 1,
    double widthScale = 1,
  }) {
    final points = stroke.points;
    if (points.isEmpty) return;
    final validPoints = points.where(
      (point) => (point.x * xScale).isFinite && (point.y * yScale).isFinite,
    );
    if (validPoints.isEmpty) return;
    final sampled = _sample(validPoints.toList(growable: false));
    final color = Color(stroke.colorArgb & 0xFFFFFFFF);
    final marker = stroke.type == InkToolType.marker;
    final paint = Paint()
      ..color = marker ? color.withValues(alpha: color.a * .36) : color
      ..strokeCap = marker ? StrokeCap.square : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = safePreviewStrokeWidth(stroke.width * widthScale, scale);

    if (sampled.length == 1) {
      canvas.drawCircle(
        Offset(sampled.first.x * xScale, sampled.first.y * yScale),
        paint.strokeWidth / 2,
        Paint()..color = paint.color,
      );
      return;
    }
    if (stroke.type == InkToolType.straightLine) {
      canvas.drawLine(
        Offset(sampled.first.x * xScale, sampled.first.y * yScale),
        Offset(sampled.last.x * xScale, sampled.last.y * yScale),
        paint,
      );
      return;
    }
    if (stroke.type == InkToolType.dashed) {
      _paintDashedStroke(
        canvas,
        sampled,
        paint,
        xScale: xScale,
        yScale: yScale,
      );
      return;
    }
    final path = Path()
      ..moveTo(sampled.first.x * xScale, sampled.first.y * yScale);
    for (var index = 1; index < sampled.length; index++) {
      path.lineTo(sampled[index].x * xScale, sampled[index].y * yScale);
    }
    canvas.drawPath(path, paint);
  }

  List<InkPoint> _sample(List<InkPoint> points) {
    if (points.length <= maxPointsPerStroke) return points;
    final step = (points.length / maxPointsPerStroke).ceil();
    final sampled = <InkPoint>[];
    for (var index = 0; index < points.length; index += step) {
      sampled.add(points[index]);
    }
    if (!identical(sampled.last, points.last)) sampled.add(points.last);
    return sampled;
  }

  void _paintDashedStroke(
    Canvas canvas,
    List<InkPoint> points,
    Paint paint, {
    double xScale = 1,
    double yScale = 1,
  }) {
    final dash = math.max(8.0, paint.strokeWidth * 2);
    final gap = math.max(5.0, paint.strokeWidth * 1.2);
    final result = DashedInkPathBuilder.buildMapped<InkPoint>(
      points: points,
      xOf: _inkPointX,
      yOf: _inkPointY,
      dashLength: dash,
      gapLength: gap,
      xScale: xScale,
      yScale: yScale,
    );
    if (result.commandCount > 0) canvas.drawPath(result.path, paint);
  }

  static double _inkPointX(InkPoint point) => point.x;

  static double _inkPointY(InkPoint point) => point.y;

  /// Keeps both corrupt persisted widths and the inverse-scale minimum away
  /// from values that can destabilize the native rasterizer.
  @visibleForTesting
  static double safePreviewStrokeWidth(double requested, double scale) {
    final safeRequested = requested.isFinite && requested > 0
        ? requested.clamp(.0001, maxPreviewStrokeWidth)
        : 1.0;
    final safeScale = scale.isFinite && scale > 0 ? scale : .0001;
    final minimumVisibleWidth = .85 / math.max(safeScale, .0001);
    return math
        .max(safeRequested, minimumVisibleWidth)
        .clamp(.0001, maxPreviewStrokeWidth);
  }

  bool _validTransform(ObjectTransform transform) {
    return transform.x.isFinite &&
        transform.y.isFinite &&
        transform.width.isFinite &&
        transform.height.isFinite &&
        transform.width > 0 &&
        transform.height > 0;
  }

  Color _withObjectOpacity(Color color, double opacity) {
    return color.withValues(alpha: color.a * _safeOpacity(opacity));
  }

  double _safeOpacity(double value) =>
      value.isFinite ? value.clamp(0.0, 1.0) : 1.0;

  @override
  bool shouldRepaint(covariant DocumentPagePreviewPainter oldDelegate) {
    return !identical(page, oldDelegate.page) ||
        backgroundColor != oldDelegate.backgroundColor;
  }
}
