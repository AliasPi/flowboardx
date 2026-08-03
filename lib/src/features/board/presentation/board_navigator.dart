import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../domain/model/board_object.dart';
import '../../../domain/model/ink.dart';
import '../engine/board_viewport.dart';

/// A transient Photoshop-style overview of the complete 3×3 board.
///
/// The header moves the panel itself. Tapping or dragging inside the preview
/// moves the viewport; the red rectangle always represents the visible area.
class BoardNavigator extends StatelessWidget {
  const BoardNavigator({
    required this.viewport,
    required this.viewportSize,
    this.visibleScreenBounds,
    required this.objects,
    required this.strokes,
    required this.onNavigate,
    required this.onMovePanel,
    required this.onInteractionStart,
    required this.onInteractionEnd,
    super.key,
  });

  static const Size preferredSize = Size(276, 190);
  static const double headerHeight = 36;

  final BoardViewport viewport;
  final Size viewportSize;
  final Rect? visibleScreenBounds;
  final List<BoardObject> objects;
  final List<InkStroke> strokes;
  final ValueChanged<Offset> onNavigate;
  final ValueChanged<Offset> onMovePanel;
  final VoidCallback onInteractionStart;
  final VoidCallback onInteractionEnd;

  @override
  Widget build(BuildContext context) => Material(
    key: const ValueKey('board-navigator'),
    color: FlowboardColors.panel.withValues(alpha: .96),
    elevation: 14,
    borderRadius: BorderRadius.circular(16),
    clipBehavior: Clip.antiAlias,
    child: SizedBox.fromSize(
      size: preferredSize,
      child: Column(
        children: [
          GestureDetector(
            key: const ValueKey('board-navigator-move-handle'),
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => onInteractionStart(),
            onPanUpdate: (details) => onMovePanel(details.delta),
            onPanEnd: (_) => onInteractionEnd(),
            onPanCancel: onInteractionEnd,
            child: const SizedBox(
              height: headerHeight,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 11),
                child: Row(
                  children: [
                    Icon(
                      Icons.map_outlined,
                      size: 18,
                      color: FlowboardColors.mint,
                    ),
                    SizedBox(width: 7),
                    Text(
                      'Navigator',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Spacer(),
                    Icon(
                      Icons.drag_indicator_rounded,
                      size: 20,
                      color: FlowboardColors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(9, 0, 9, 9),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final mapSize = constraints.biggest;
                  void navigate(Offset local) {
                    final world = BoardNavigatorGeometry.worldAt(
                      local,
                      mapSize: mapSize,
                      worldBounds: viewport.worldBounds,
                    );
                    onNavigate(world);
                  }

                  return Semantics(
                    label:
                        'Whiteboard-Navigator, roter Rahmen zeigt den Sichtbereich',
                    child: GestureDetector(
                      key: const ValueKey('board-navigator-map'),
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) {
                        onInteractionStart();
                        navigate(details.localPosition);
                        onInteractionEnd();
                      },
                      onPanStart: (details) {
                        onInteractionStart();
                        navigate(details.localPosition);
                      },
                      onPanUpdate: (details) => navigate(details.localPosition),
                      onPanEnd: (_) => onInteractionEnd(),
                      onPanCancel: onInteractionEnd,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          RepaintBoundary(
                            child: CustomPaint(
                              painter: BoardNavigatorContentPainter(
                                worldBounds: viewport.worldBounds,
                                objects: objects,
                                strokes: strokes,
                              ),
                            ),
                          ),
                          IgnorePointer(
                            child: RepaintBoundary(
                              child: CustomPaint(
                                painter: BoardNavigatorViewportPainter(
                                  viewport: viewport,
                                  viewportSize: viewportSize,
                                  visibleScreenBounds:
                                      visibleScreenBounds ??
                                      (Offset.zero & viewportSize),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

abstract final class BoardNavigatorGeometry {
  static Offset worldAt(
    Offset local, {
    required Size mapSize,
    required Rect worldBounds,
  }) {
    if (mapSize.isEmpty) return worldBounds.center;
    return Offset(
      worldBounds.left +
          local.dx.clamp(0.0, mapSize.width) /
              mapSize.width *
              worldBounds.width,
      worldBounds.top +
          local.dy.clamp(0.0, mapSize.height) /
              mapSize.height *
              worldBounds.height,
    );
  }

  static Offset mapPoint(Offset world, Size size, Rect bounds) => Offset(
    (world.dx - bounds.left) / bounds.width * size.width,
    (world.dy - bounds.top) / bounds.height * size.height,
  );

  static Rect mapRect(Rect world, Size size, Rect bounds) => Rect.fromPoints(
    mapPoint(world.topLeft, size, bounds),
    mapPoint(world.bottomRight, size, bounds),
  );

  static Rect visibleWorldRect({
    required double viewportScale,
    required Offset viewportOffset,
    required Rect visibleScreenBounds,
    required Rect worldBounds,
  }) {
    if (!viewportScale.isFinite || viewportScale <= 0) return Rect.zero;
    return Rect.fromPoints(
      (visibleScreenBounds.topLeft - viewportOffset) / viewportScale,
      (visibleScreenBounds.bottomRight - viewportOffset) / viewportScale,
    ).intersect(worldBounds);
  }
}

/// Fixed work budgets for the transient overview.
///
/// The navigator is only 258x145 logical pixels. Processing every point from
/// every persisted circle cannot add visible detail, but used to make its
/// first repaint scale with the complete page history.
abstract final class BoardNavigatorSampling {
  static const int maximumObjectCount = 2000;
  static const int maximumStrokeCount = 5000;
  static const int maximumPointsPerStroke = 80;
  static const int maximumTotalStrokePoints = 16000;

  @visibleForTesting
  static List<int> sampledIndices(int itemCount, int maximumCount) {
    if (itemCount <= 0 || maximumCount <= 0) return const <int>[];
    if (itemCount <= maximumCount) {
      return List<int>.generate(itemCount, (index) => index, growable: false);
    }
    if (maximumCount == 1) return <int>[itemCount - 1];
    return List<int>.generate(
      maximumCount,
      (slot) => slot * (itemCount - 1) ~/ (maximumCount - 1),
      growable: false,
    );
  }

  @visibleForTesting
  static List<int> allocatePointBudgets(
    Iterable<int> pointCounts, {
    int totalPointBudget = maximumTotalStrokePoints,
    int perStrokeLimit = maximumPointsPerStroke,
  }) {
    final counts = pointCounts.toList(growable: false);
    var remainingPoints = math.max(0, totalPointBudget);
    var remainingStrokes = counts.length;
    final safePerStrokeLimit = math.max(0, perStrokeLimit);
    final result = <int>[];
    for (final count in counts) {
      if (remainingStrokes <= 0 || count <= 0) {
        if (remainingStrokes > 0) remainingStrokes--;
        result.add(0);
        continue;
      }
      final fairShare = remainingPoints <= 0
          ? 0
          : (remainingPoints / remainingStrokes).ceil();
      final allocated = math.min(
        count,
        math.min(safePerStrokeLimit, fairShare),
      );
      remainingStrokes--;
      remainingPoints = math.max(0, remainingPoints - allocated);
      result.add(allocated);
    }
    return result;
  }
}

/// Static page overview. Its repaint contract intentionally excludes camera
/// state so pinch/pan only moves the lightweight red viewport rectangle.
class BoardNavigatorContentPainter extends CustomPainter {
  const BoardNavigatorContentPainter({
    required this.worldBounds,
    required this.objects,
    required this.strokes,
  });

  final Rect worldBounds;
  final List<BoardObject> objects;
  final List<InkStroke> strokes;

  @override
  void paint(Canvas canvas, Size size) =>
      _paintNavigatorContent(canvas, size, worldBounds, objects, strokes);

  @override
  bool shouldRepaint(covariant BoardNavigatorContentPainter oldDelegate) =>
      oldDelegate.worldBounds != worldBounds ||
      !identical(oldDelegate.objects, objects) ||
      !identical(oldDelegate.strokes, strokes);
}

/// Dynamic navigator overlay containing only the current visible world rect.
class BoardNavigatorViewportPainter extends CustomPainter {
  BoardNavigatorViewportPainter({
    required BoardViewport viewport,
    required this.viewportSize,
    Rect? visibleScreenBounds,
  }) : viewportScale = viewport.scale,
       viewportOffset = viewport.offset,
       worldBounds = viewport.worldBounds,
       visibleScreenBounds =
           visibleScreenBounds ?? (Offset.zero & viewportSize);

  final double viewportScale;
  final Offset viewportOffset;
  final Rect worldBounds;
  final Size viewportSize;
  final Rect visibleScreenBounds;

  @override
  void paint(Canvas canvas, Size size) => _paintNavigatorViewport(
    canvas,
    size,
    viewportScale: viewportScale,
    viewportOffset: viewportOffset,
    visibleScreenBounds: visibleScreenBounds,
    worldBounds: worldBounds,
  );

  @override
  bool shouldRepaint(covariant BoardNavigatorViewportPainter oldDelegate) =>
      oldDelegate.viewportScale != viewportScale ||
      oldDelegate.viewportOffset != viewportOffset ||
      oldDelegate.worldBounds != worldBounds ||
      oldDelegate.viewportSize != viewportSize ||
      oldDelegate.visibleScreenBounds != visibleScreenBounds;
}

/// Combined painter retained for embedders that used the original public API.
class BoardNavigatorPainter extends CustomPainter {
  BoardNavigatorPainter({
    required BoardViewport viewport,
    required this.viewportSize,
    Rect? visibleScreenBounds,
    required this.objects,
    required this.strokes,
  }) : viewportScale = viewport.scale,
       viewportOffset = viewport.offset,
       worldBounds = viewport.worldBounds,
       visibleScreenBounds =
           visibleScreenBounds ?? (Offset.zero & viewportSize);

  final double viewportScale;
  final Offset viewportOffset;
  final Rect worldBounds;
  final Size viewportSize;
  final Rect visibleScreenBounds;
  final List<BoardObject> objects;
  final List<InkStroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    _paintNavigatorContent(canvas, size, worldBounds, objects, strokes);
    _paintNavigatorViewport(
      canvas,
      size,
      viewportScale: viewportScale,
      viewportOffset: viewportOffset,
      visibleScreenBounds: visibleScreenBounds,
      worldBounds: worldBounds,
    );
  }

  @override
  bool shouldRepaint(covariant BoardNavigatorPainter oldDelegate) =>
      oldDelegate.viewportScale != viewportScale ||
      oldDelegate.viewportOffset != viewportOffset ||
      oldDelegate.worldBounds != worldBounds ||
      oldDelegate.viewportSize != viewportSize ||
      oldDelegate.visibleScreenBounds != visibleScreenBounds ||
      oldDelegate.objects != objects ||
      oldDelegate.strokes != strokes;
}

void _paintNavigatorContent(
  Canvas canvas,
  Size size,
  Rect world,
  List<BoardObject> objects,
  List<InkStroke> strokes,
) {
  final surface = Offset.zero & size;
  canvas.drawRect(surface, Paint()..color = FlowboardColors.canvas);
  canvas.save();
  canvas.clipRRect(RRect.fromRectAndRadius(surface, const Radius.circular(9)));

  final cellPaint = Paint()
    ..color = const Color(0xFF8D9994).withValues(alpha: .48)
    ..strokeWidth = 1;
  for (var index = 1; index < 3; index++) {
    final x = size.width * index / 3;
    final y = size.height * index / 3;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), cellPaint);
    canvas.drawLine(Offset(0, y), Offset(size.width, y), cellPaint);
  }

  final objectPaint = Paint()
    ..color = const Color(0xFF52605D).withValues(alpha: .38)
    ..style = PaintingStyle.fill;
  final objectIndices = BoardNavigatorSampling.sampledIndices(
    objects.length,
    BoardNavigatorSampling.maximumObjectCount,
  );
  for (final objectIndex in objectIndices) {
    final object = objects[objectIndex];
    final bounds = object.transform.bounds;
    if (!bounds.left.isFinite ||
        !bounds.top.isFinite ||
        !bounds.width.isFinite ||
        !bounds.height.isFinite) {
      continue;
    }
    final rect = BoardNavigatorGeometry.mapRect(
      Rect.fromLTWH(bounds.left, bounds.top, bounds.width, bounds.height),
      size,
      world,
    ).intersect(surface);
    if (!rect.isEmpty) canvas.drawRect(rect, objectPaint);
  }

  final inkPaint = Paint()
    ..color = const Color(0xFF26312F).withValues(alpha: .72)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = 1.15;
  final strokeIndices = BoardNavigatorSampling.sampledIndices(
    strokes.length,
    BoardNavigatorSampling.maximumStrokeCount,
  );
  final pointBudgets = BoardNavigatorSampling.allocatePointBudgets(
    strokeIndices.map((index) => strokes[index].points.length),
  );
  for (var slot = 0; slot < strokeIndices.length; slot++) {
    final stroke = strokes[strokeIndices[slot]];
    if (stroke.points.isEmpty) continue;
    final pointBudget = pointBudgets[slot];
    if (pointBudget <= 0) continue;
    final sampleCount = math.min(pointBudget, stroke.points.length);
    Path? path;
    for (var sample = 0; sample < sampleCount; sample++) {
      final index = sampleCount == 1
          ? 0
          : sample * (stroke.points.length - 1) ~/ (sampleCount - 1);
      final point = stroke.points[index];
      if (!point.x.isFinite || !point.y.isFinite) continue;
      final mapped = BoardNavigatorGeometry.mapPoint(
        Offset(point.x, point.y),
        size,
        world,
      );
      path ??= Path()..moveTo(mapped.dx, mapped.dy);
      path.lineTo(mapped.dx, mapped.dy);
    }
    if (path != null) canvas.drawPath(path, inkPaint);
  }

  canvas.restore();
  canvas.drawRRect(
    RRect.fromRectAndRadius(surface.deflate(.75), const Radius.circular(9)),
    Paint()
      ..color = FlowboardColors.divider
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5,
  );
}

void _paintNavigatorViewport(
  Canvas canvas,
  Size size, {
  required double viewportScale,
  required Offset viewportOffset,
  required Rect visibleScreenBounds,
  required Rect worldBounds,
}) {
  if (!viewportScale.isFinite || viewportScale <= 0) return;
  final surface = Offset.zero & size;
  canvas.save();
  canvas.clipRRect(RRect.fromRectAndRadius(surface, const Radius.circular(9)));
  final visibleWorld = BoardNavigatorGeometry.visibleWorldRect(
    viewportScale: viewportScale,
    viewportOffset: viewportOffset,
    visibleScreenBounds: visibleScreenBounds,
    worldBounds: worldBounds,
  );
  if (!visibleWorld.isEmpty) {
    final visible = BoardNavigatorGeometry.mapRect(
      visibleWorld,
      size,
      worldBounds,
    );
    canvas.drawRect(
      visible,
      Paint()..color = const Color(0xFFD73333).withValues(alpha: .08),
    );
    canvas.drawRect(
      visible,
      Paint()
        ..color = const Color(0xFFE32636)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4,
    );
  }
  canvas.restore();
}
