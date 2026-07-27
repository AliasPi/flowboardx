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
    super.key,
  });

  final List<InkStroke> strokes;
  final double worldToScreenScale;
  final Offset worldToScreenOffset;
  final Rect2? worldClip;
  final Set<String> selectionIds;

  @override
  State<PersistedInkLayer> createState() => _PersistedInkLayerState();
}

class _PersistedInkLayerState extends State<PersistedInkLayer> {
  final InkPictureCache _cache = InkPictureCache(livePreview: false);

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: PersistedInkPainter(
          strokes: widget.strokes,
          worldToScreenScale: widget.worldToScreenScale,
          worldToScreenOffset: widget.worldToScreenOffset,
          worldClip: widget.worldClip,
          selectionIds: widget.selectionIds,
          cache: _cache,
        ),
      ),
    );
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
      // Invalid recovered viewport data must not keep pictures for strokes
      // that have already disappeared while painting is temporarily skipped.
      cache.retainOnly(const <String>{});
      return;
    }
    final retained = <String>{for (final stroke in strokes) stroke.id};
    canvas
      ..save()
      ..translate(worldToScreenOffset.dx, worldToScreenOffset.dy)
      ..scale(scale);
    for (final stroke in strokes) {
      if (stroke.points.isEmpty ||
          (worldClip != null && !stroke.bounds.intersects(worldClip!))) {
        continue;
      }
      if (selectionIds.contains(stroke.id)) {
        InkPainter.drawSelectionHalo(canvas, stroke, scale);
      }
      canvas.drawPicture(cache.pictureFor(stroke));
    }
    canvas.restore();
    cache.retainOnly(retained);
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
