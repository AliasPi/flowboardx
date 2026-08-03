import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../domain/model/geometry.dart';
import '../../../domain/model/ink.dart';
import 'ink_picture_cache.dart';
import 'ink_painter.dart';

/// Retains expensive path construction for persisted ink across viewport moves
/// and unrelated controller rebuilds.
class PersistedInkLayer extends StatefulWidget {
  const PersistedInkLayer({
    required this.strokes,
    required this.worldToScreenScale,
    required this.worldToScreenOffset,
    this.worldClip,
    this.selectionIds = const <String>{},
    this.isolateRepaints = true,
    super.key,
  });

  final List<InkStroke> strokes;
  final double worldToScreenScale;
  final Offset worldToScreenOffset;
  final Rect2? worldClip;
  final Set<String> selectionIds;
  final bool isolateRepaints;

  @override
  State<PersistedInkLayer> createState() => _PersistedInkLayerState();
}

class _PersistedInkLayerState extends State<PersistedInkLayer> {
  final InkPictureCache _cache = InkPictureCache(livePreview: false);

  @override
  void didUpdateWidget(covariant PersistedInkLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.strokes, widget.strokes) ||
        !setEquals(oldWidget.selectionIds, widget.selectionIds)) {
      // Persisted ink is rendered exclusively by bounded batch pictures.
      // Selection halos are painted underneath those batches, so no historical
      // per-stroke picture may survive selection changes.
      _cache.retainOnly(const <String>{});
    }
  }

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paint = CustomPaint(
      painter: PersistedInkPainter(
        strokes: widget.strokes,
        worldToScreenScale: widget.worldToScreenScale,
        worldToScreenOffset: widget.worldToScreenOffset,
        worldClip: widget.worldClip,
        selectionIds: widget.selectionIds,
        cache: _cache,
      ),
    );
    return widget.isolateRepaints
        ? RepaintBoundary(child: paint)
        : ClipRect(child: paint);
  }
}

@visibleForTesting
class PersistedInkPainter extends CustomPainter {
  const PersistedInkPainter({
    required this.strokes,
    required this.worldToScreenScale,
    required this.worldToScreenOffset,
    required this.cache,
    this.worldClip,
    this.selectionIds = const <String>{},
  });

  final List<InkStroke> strokes;
  final double worldToScreenScale;
  final Offset worldToScreenOffset;
  final Rect2? worldClip;
  final Set<String> selectionIds;
  final InkPictureCache cache;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = worldToScreenScale;
    if (!scale.isFinite ||
        scale <= 0 ||
        !worldToScreenOffset.dx.isFinite ||
        !worldToScreenOffset.dy.isFinite) {
      // Recovered invalid viewport data is ignored defensively.
      return;
    }
    canvas
      ..save()
      ..translate(worldToScreenOffset.dx, worldToScreenOffset.dy)
      ..scale(scale);
    // Paint selection decoration first. The immutable base batches then cover
    // the centre of the halo and render every stroke exactly once. In
    // particular, a translucent marker must not be alpha-blended twice merely
    // because it is selected.
    if (selectionIds.isNotEmpty) {
      for (final stroke in strokes) {
        if (!selectionIds.contains(stroke.id) ||
            stroke.points.isEmpty ||
            (worldClip != null && !stroke.bounds.intersects(worldClip!))) {
          continue;
        }
        InkPainter.drawSelectionHalo(canvas, stroke, scale);
      }
    }
    for (final picture in cache.batchPicturesFor(strokes)) {
      canvas.drawPicture(picture);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant PersistedInkPainter oldDelegate) {
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
