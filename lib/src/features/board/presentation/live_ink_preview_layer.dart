import 'package:flutter/material.dart';

import '../../../domain/model/geometry.dart';
import '../../../domain/model/ink.dart';
import '../engine/ink_session_manager.dart';
import 'ink_painter.dart';
import 'ink_picture_cache.dart';

export 'ink_picture_cache.dart' show LiveInkPictureCache;

/// Bounded live ink overlay backed by immutable vector-picture batches.
///
/// A long gesture previously added one full-board RepaintBoundary per preview
/// segment. On a 4K board, circular writing stacked many overlapping raster
/// layers and became progressively slower. Completed chunks now share small,
/// spatially bounded batches while each moving tail stays separate. Ordinary
/// pointer events therefore repaint only the tail; a chunk boundary invalidates
/// at most the one open batch.
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
  List<FrozenInkPreviewBatch>? _frozenSnapshot;
  Map<int, List<FrozenInkPreviewBatch>> _frozenByPointer =
      const <int, List<FrozenInkPreviewBatch>>{};
  Map<int, List<InkStroke>> _activeByPointer = const <int, List<InkStroke>>{};
  int _sessionEpoch = 0;

  @override
  void didUpdateWidget(covariant LiveInkPreviewLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessions != widget.sessions) {
      _frozenSnapshot = null;
      _frozenByPointer = const <int, List<FrozenInkPreviewBatch>>{};
      _activeByPointer = const <int, List<InkStroke>>{};
      _sessionEpoch++;
    }
  }

  void _updateFrozenGroups(List<FrozenInkPreviewBatch> snapshot) {
    if (identical(_frozenSnapshot, snapshot)) return;
    final grouped = _groupBatchesByPointer(snapshot);
    final next = <int, List<FrozenInkPreviewBatch>>{};
    for (final entry in grouped.entries) {
      final previous = _frozenByPointer[entry.key];
      next[entry.key] =
          previous != null && _sameBatchIdentities(previous, entry.value)
          ? previous
          : entry.value;
    }
    _frozenSnapshot = snapshot;
    _frozenByPointer = Map<int, List<FrozenInkPreviewBatch>>.unmodifiable(next);
  }

  void _updateActiveGroups(List<InkStroke> snapshot) {
    final grouped = _groupStrokesByPointer(snapshot);
    final next = <int, List<InkStroke>>{};
    for (final entry in grouped.entries) {
      final previous = _activeByPointer[entry.key];
      next[entry.key] =
          previous != null && _sameActivePreview(previous, entry.value)
          ? previous
          : entry.value;
    }
    _activeByPointer = Map<int, List<InkStroke>>.unmodifiable(next);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasSize = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 0,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 0,
        );
        if (canvasSize.isEmpty) return const SizedBox.shrink();
        return AnimatedBuilder(
          animation: widget.sessions,
          builder: (context, _) {
            _updateFrozenGroups(widget.sessions.buildFrozenPreviewBatches());
            _updateActiveGroups(widget.sessions.buildActivePreviewStrokes());
            final pointers = <int>{
              ..._frozenByPointer.keys,
              ..._activeByPointer.keys,
            }.toList(growable: false)..sort();
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: <Widget>[
                for (final pointer in pointers)
                  _PointerLiveInkPreview(
                    key: ValueKey<(int, int)>((_sessionEpoch, pointer)),
                    pointer: pointer,
                    frozenBatches:
                        _frozenByPointer[pointer] ??
                        const <FrozenInkPreviewBatch>[],
                    activeStrokes:
                        _activeByPointer[pointer] ?? const <InkStroke>[],
                    worldToScreenScale: widget.worldToScreenScale,
                    worldToScreenOffset: widget.worldToScreenOffset,
                    worldClip: widget.worldClip,
                    canvasSize: canvasSize,
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

Map<int, List<FrozenInkPreviewBatch>> _groupBatchesByPointer(
  List<FrozenInkPreviewBatch> batches,
) {
  final grouped = <int, List<FrozenInkPreviewBatch>>{};
  for (final batch in batches) {
    (grouped[batch.pointer] ??= <FrozenInkPreviewBatch>[]).add(batch);
  }
  return <int, List<FrozenInkPreviewBatch>>{
    for (final entry in grouped.entries)
      entry.key: List<FrozenInkPreviewBatch>.unmodifiable(entry.value),
  };
}

bool _sameBatchIdentities(
  List<FrozenInkPreviewBatch> first,
  List<FrozenInkPreviewBatch> second,
) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (!identical(first[index], second[index])) return false;
  }
  return true;
}

Map<int, List<InkStroke>> _groupStrokesByPointer(List<InkStroke> strokes) {
  final grouped = <int, List<InkStroke>>{};
  for (final stroke in strokes) {
    // Live preview strokes always carry the physical pointer. Keep recovered
    // or custom test data defensive without merging it into a real pointer.
    final pointer = stroke.pointerId ?? -1;
    (grouped[pointer] ??= <InkStroke>[]).add(stroke);
  }
  return <int, List<InkStroke>>{
    for (final entry in grouped.entries)
      entry.key: List<InkStroke>.unmodifiable(entry.value),
  };
}

bool _sameActivePreview(List<InkStroke> first, List<InkStroke> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    final previous = first[index];
    final next = second[index];
    if (previous.id != next.id ||
        previous.colorArgb != next.colorArgb ||
        previous.width != next.width ||
        previous.type != next.type ||
        previous.points.length != next.points.length) {
      return false;
    }
    if (previous.points.isEmpty) continue;
    if (!_sameInkPoint(previous.points.first, next.points.first) ||
        !_sameInkPoint(previous.points.last, next.points.last)) {
      return false;
    }
  }
  return true;
}

bool _sameInkPoint(InkPoint first, InkPoint second) =>
    first.x == second.x &&
    first.y == second.y &&
    first.pressure == second.pressure &&
    first.timestampMicros == second.timestampMicros &&
    first.tiltX == second.tiltX &&
    first.tiltY == second.tiltY;

class _PointerLiveInkPreview extends StatefulWidget {
  const _PointerLiveInkPreview({
    required this.pointer,
    required this.frozenBatches,
    required this.activeStrokes,
    required this.worldToScreenScale,
    required this.worldToScreenOffset,
    required this.worldClip,
    required this.canvasSize,
    super.key,
  });

  final int pointer;
  final List<FrozenInkPreviewBatch> frozenBatches;
  final List<InkStroke> activeStrokes;
  final double worldToScreenScale;
  final Offset worldToScreenOffset;
  final Rect2? worldClip;
  final Size canvasSize;

  @override
  State<_PointerLiveInkPreview> createState() => _PointerLiveInkPreviewState();
}

class _PointerLiveInkPreviewState extends State<_PointerLiveInkPreview> {
  final LiveInkPictureCache _activeCache = LiveInkPictureCache();
  List<FrozenInkPreviewBatch>? _frozenLayerSource;
  double? _frozenLayerScale;
  Offset? _frozenLayerOffset;
  Rect2? _frozenLayerWorldClip;
  Size? _frozenLayerCanvasSize;
  Widget _frozenLayer = const SizedBox.shrink();

  @override
  void dispose() {
    _activeCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _updateFrozenLayer();
    final activeBounds = _screenPaintBounds(
      worldBounds: _strokeBounds(widget.activeStrokes),
      strokes: widget.activeStrokes,
      worldToScreenScale: widget.worldToScreenScale,
      worldToScreenOffset: widget.worldToScreenOffset,
      worldClip: widget.worldClip,
      canvasSize: widget.canvasSize,
    );
    return Stack(
      key: ValueKey<String>('live-ink-pointer-${widget.pointer}'),
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        _frozenLayer,
        if (activeBounds != null) _buildActiveRegion(bounds: activeBounds),
      ],
    );
  }

  void _updateFrozenLayer() {
    if (identical(_frozenLayerSource, widget.frozenBatches) &&
        _frozenLayerScale == widget.worldToScreenScale &&
        _frozenLayerOffset == widget.worldToScreenOffset &&
        _frozenLayerWorldClip == widget.worldClip &&
        _frozenLayerCanvasSize == widget.canvasSize) {
      return;
    }
    _frozenLayerSource = widget.frozenBatches;
    _frozenLayerScale = widget.worldToScreenScale;
    _frozenLayerOffset = widget.worldToScreenOffset;
    _frozenLayerWorldClip = widget.worldClip;
    _frozenLayerCanvasSize = widget.canvasSize;
    _frozenLayer = widget.frozenBatches.isEmpty
        ? const SizedBox.shrink()
        : Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: <Widget>[
              for (final batch in widget.frozenBatches)
                _FrozenInkBatchPreview(
                  key: ValueKey<String>(batch.id),
                  batch: batch,
                  worldToScreenScale: widget.worldToScreenScale,
                  worldToScreenOffset: widget.worldToScreenOffset,
                  worldClip: widget.worldClip,
                  canvasSize: widget.canvasSize,
                ),
            ],
          );
  }

  Widget _buildActiveRegion({required Rect bounds}) {
    return Positioned(
      left: bounds.left,
      top: bounds.top,
      width: bounds.width,
      height: bounds.height,
      child: RepaintBoundary(
        child: CustomPaint(
          key: const ValueKey<String>('live-ink-active-preview-paint'),
          // This display list changes on every delivered pointer packet. Do
          // not make the raster cache repeatedly promote and evict it.
          willChange: true,
          painter: LiveInkPreviewPainter(
            strokes: widget.activeStrokes,
            worldToScreenScale: widget.worldToScreenScale,
            worldToScreenOffset: widget.worldToScreenOffset - bounds.topLeft,
            worldClip: widget.worldClip,
            cache: _activeCache,
            cachePictures: false,
          ),
        ),
      ),
    );
  }
}

class _FrozenInkBatchPreview extends StatefulWidget {
  const _FrozenInkBatchPreview({
    required this.batch,
    required this.worldToScreenScale,
    required this.worldToScreenOffset,
    required this.worldClip,
    required this.canvasSize,
    super.key,
  });

  final FrozenInkPreviewBatch batch;
  final double worldToScreenScale;
  final Offset worldToScreenOffset;
  final Rect2? worldClip;
  final Size canvasSize;

  @override
  State<_FrozenInkBatchPreview> createState() => _FrozenInkBatchPreviewState();
}

class _FrozenInkBatchPreviewState extends State<_FrozenInkBatchPreview> {
  final LiveInkPictureCache _cache = LiveInkPictureCache();

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bounds = _screenPaintBounds(
      worldBounds: widget.batch.worldBounds,
      strokes: widget.batch.strokes,
      worldToScreenScale: widget.worldToScreenScale,
      worldToScreenOffset: widget.worldToScreenOffset,
      worldClip: widget.worldClip,
      canvasSize: widget.canvasSize,
    );
    if (bounds == null) return const SizedBox.shrink();
    return Positioned(
      left: bounds.left,
      top: bounds.top,
      width: bounds.width,
      height: bounds.height,
      child: RepaintBoundary(
        child: CustomPaint(
          key: ValueKey<String>(
            'live-ink-frozen-preview-paint-${widget.batch.id}',
          ),
          isComplex: true,
          painter: LiveInkPreviewPainter(
            strokes: widget.batch.strokes,
            worldToScreenScale: widget.worldToScreenScale,
            worldToScreenOffset: widget.worldToScreenOffset - bounds.topLeft,
            worldClip: widget.worldClip,
            cache: _cache,
          ),
        ),
      ),
    );
  }
}

Rect2? _strokeBounds(List<InkStroke> strokes) {
  Rect2? bounds;
  for (final stroke in strokes) {
    if (stroke.points.isEmpty) continue;
    bounds = bounds == null ? stroke.bounds : bounds.union(stroke.bounds);
  }
  return bounds;
}

Rect? _screenPaintBounds({
  required Rect2? worldBounds,
  required List<InkStroke> strokes,
  required double worldToScreenScale,
  required Offset worldToScreenOffset,
  required Rect2? worldClip,
  required Size canvasSize,
}) {
  if (worldBounds == null ||
      strokes.isEmpty ||
      (worldClip != null && !worldBounds.intersects(worldClip))) {
    return null;
  }
  final scale = worldToScreenScale;
  final offset = worldToScreenOffset;
  if (!scale.isFinite ||
      scale <= 0 ||
      !offset.dx.isFinite ||
      !offset.dy.isFinite ||
      !worldBounds.left.isFinite ||
      !worldBounds.top.isFinite ||
      !worldBounds.right.isFinite ||
      !worldBounds.bottom.isFinite) {
    return null;
  }
  final screenBounds = Rect.fromLTRB(
    offset.dx + worldBounds.left * scale,
    offset.dy + worldBounds.top * scale,
    offset.dx + worldBounds.right * scale,
    offset.dy + worldBounds.bottom * scale,
    // [InkStroke.bounds] already includes half the nib width in world space.
    // Keep only a tiny antialiasing guard here; inflating by the width again
    // needlessly enlarges every retained raster layer.
  ).inflate(_previewScreenPadding);
  final clipped = screenBounds.intersect(Offset.zero & canvasSize);
  if (!clipped.left.isFinite ||
      !clipped.top.isFinite ||
      !clipped.width.isFinite ||
      !clipped.height.isFinite ||
      clipped.width <= 0 ||
      clipped.height <= 0) {
    return null;
  }
  return clipped;
}

const double _previewScreenPadding = 2;

class LiveInkPreviewPainter extends CustomPainter {
  const LiveInkPreviewPainter({
    required this.strokes,
    required this.worldToScreenScale,
    required this.worldToScreenOffset,
    required this.cache,
    this.worldClip,
    this.cachePictures = true,
  });

  final List<InkStroke> strokes;
  final double worldToScreenScale;
  final Offset worldToScreenOffset;
  final Rect2? worldClip;
  final LiveInkPictureCache cache;
  final bool cachePictures;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = worldToScreenScale;
    if (!scale.isFinite ||
        scale <= 0 ||
        !worldToScreenOffset.dx.isFinite ||
        !worldToScreenOffset.dy.isFinite) {
      if (cachePictures) cache.retainOnly(const <String>{});
      return;
    }
    canvas
      ..save()
      ..translate(worldToScreenOffset.dx, worldToScreenOffset.dy)
      ..scale(scale);

    // The moving tail has a new immutable InkStroke identity on every MOVE, so
    // recording it into a Picture only to dispose and re-record that Picture
    // in the next frame adds an entire display-list pass without any reuse.
    // Frozen chunks still take the cached branch below.
    if (!cachePictures) {
      for (final stroke in strokes) {
        if (stroke.points.isEmpty ||
            (worldClip != null && !stroke.bounds.intersects(worldClip!))) {
          continue;
        }
        InkPainter.drawLivePreviewStroke(canvas, stroke);
      }
      canvas.restore();
      return;
    }

    final retained = <String>{};
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
        oldDelegate.cachePictures != cachePictures ||
        oldDelegate.strokes.length != strokes.length) {
      return true;
    }
    for (var index = 0; index < strokes.length; index++) {
      if (!identical(oldDelegate.strokes[index], strokes[index])) return true;
    }
    return false;
  }
}
