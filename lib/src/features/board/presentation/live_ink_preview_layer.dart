import 'package:flutter/material.dart';

import '../../../domain/model/geometry.dart';
import '../../../domain/model/ink.dart';
import '../engine/ink_session_manager.dart';
import 'ink_picture_cache.dart';

export 'ink_picture_cache.dart' show LiveInkPictureCache;

/// Fixed-size live ink overlay backed by immutable vector-picture chunks.
///
/// A long gesture previously added one full-board RepaintBoundary per preview
/// segment. On a 4K board, circular writing stacked many overlapping raster
/// layers and became progressively slower. Two bounded render objects separate
/// completed ink from the moving tails: ordinary pointer events repaint only
/// the tails, while frozen ink changes once per segment boundary.
class LiveInkPreviewLayer extends StatefulWidget {
  const LiveInkPreviewLayer({
    required this.sessions,
    required this.worldToScreenScale,
    required this.worldToScreenOffset,
    this.worldClip,
    super.key,
  });

  final InkSessionManager sessions;
  final double worldToScreenScale;
  final Offset worldToScreenOffset;
  final Rect2? worldClip;

  @override
  State<LiveInkPreviewLayer> createState() => _LiveInkPreviewLayerState();
}

class _LiveInkPreviewLayerState extends State<LiveInkPreviewLayer> {
  final LiveInkPictureCache _frozenCache = LiveInkPictureCache();
  final LiveInkPictureCache _activeCache = LiveInkPictureCache();

  @override
  void didUpdateWidget(covariant LiveInkPreviewLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessions != widget.sessions) {
      _frozenCache.clear();
      _activeCache.clear();
    }
  }

  @override
  void dispose() {
    _frozenCache.dispose();
    _activeCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.sessions,
      builder: (context, _) {
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey<String>('live-ink-frozen-preview-paint'),
                painter: LiveInkPreviewPainter(
                  strokes: widget.sessions.buildFrozenPreviewStrokes(),
                  worldToScreenScale: widget.worldToScreenScale,
                  worldToScreenOffset: widget.worldToScreenOffset,
                  worldClip: widget.worldClip,
                  cache: _frozenCache,
                ),
              ),
            ),
            RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey<String>('live-ink-active-preview-paint'),
                painter: LiveInkPreviewPainter(
                  strokes: widget.sessions.buildActivePreviewStrokes(),
                  worldToScreenScale: widget.worldToScreenScale,
                  worldToScreenOffset: widget.worldToScreenOffset,
                  worldClip: widget.worldClip,
                  cache: _activeCache,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class LiveInkPreviewPainter extends CustomPainter {
  const LiveInkPreviewPainter({
    required this.strokes,
    required this.worldToScreenScale,
    required this.worldToScreenOffset,
    required this.cache,
    this.worldClip,
  });

  final List<InkStroke> strokes;
  final double worldToScreenScale;
  final Offset worldToScreenOffset;
  final Rect2? worldClip;
  final LiveInkPictureCache cache;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = worldToScreenScale;
    if (!scale.isFinite ||
        scale <= 0 ||
        !worldToScreenOffset.dx.isFinite ||
        !worldToScreenOffset.dy.isFinite) {
      cache.retainOnly(const <String>{});
      return;
    }
    final retained = <String>{};
    canvas
      ..save()
      ..translate(worldToScreenOffset.dx, worldToScreenOffset.dy)
      ..scale(scale);
    for (final stroke in strokes) {
      if (stroke.points.isEmpty ||
          (worldClip != null && !stroke.bounds.intersects(worldClip!))) {
        continue;
      }
      retained.add(stroke.id);
      canvas.drawPicture(cache.pictureFor(stroke));
    }
    canvas.restore();
    cache.retainOnly(retained);
  }

  @override
  bool shouldRepaint(covariant LiveInkPreviewPainter oldDelegate) {
    if (oldDelegate.worldToScreenScale != worldToScreenScale ||
        oldDelegate.worldToScreenOffset != worldToScreenOffset ||
        oldDelegate.worldClip != worldClip ||
        oldDelegate.strokes.length != strokes.length) {
      return true;
    }
    for (var index = 0; index < strokes.length; index++) {
      if (!identical(oldDelegate.strokes[index], strokes[index])) return true;
    }
    return false;
  }
}
