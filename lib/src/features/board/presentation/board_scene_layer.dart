import 'package:flutter/material.dart';

import '../../../domain/model/board_object.dart';
import '../../../domain/model/geometry.dart';
import '../../../domain/model/ink.dart';
import '../../../domain/model/scene_order.dart';
import 'board_object_layer.dart';
import 'persisted_ink_layer.dart';

/// Paints free ink and board objects in one shared z-order. Consecutive ink
/// entries are split into bounded, stable batches. Completed batches retain
/// their vector cache when a new stroke is appended, without creating one
/// fullscreen render layer per stroke.
class BoardSceneLayer extends StatefulWidget {
  const BoardSceneLayer({
    required this.objects,
    required this.strokes,
    required this.annotationLayers,
    required this.scale,
    required this.offset,
    required this.assets,
    this.selectedIds = const <String>{},
    this.worldClip,
    super.key,
  });

  final List<BoardObject> objects;
  final List<InkStroke> strokes;
  final List<ObjectInkLayer> annotationLayers;
  final double scale;
  final Offset offset;
  final BoardAssetResolver assets;
  final Set<String> selectedIds;
  final Rect2? worldClip;

  @override
  State<BoardSceneLayer> createState() => _BoardSceneLayerState();
}

class _BoardSceneLayerState extends State<BoardSceneLayer> {
  late List<_SceneRun> _runs;
  late VisibleObjectInkLayerIndex _annotationIndex;

  @override
  void initState() {
    super.initState();
    _annotationIndex = VisibleObjectInkLayerIndex(widget.annotationLayers);
    _rebuildRuns();
  }

  @override
  void didUpdateWidget(covariant BoardSceneLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Viewport and overlay changes retain the page-list identities. Avoid an
    // O(N log N) scene sort for every pan, zoom and cursor frame.
    if (!identical(oldWidget.objects, widget.objects) ||
        !identical(oldWidget.strokes, widget.strokes)) {
      _rebuildRuns();
    }
    if (!identical(oldWidget.annotationLayers, widget.annotationLayers)) {
      _annotationIndex = VisibleObjectInkLayerIndex(widget.annotationLayers);
    }
  }

  void _rebuildRuns() {
    _runs = _buildRuns(
      orderedBoardSceneItems(objects: widget.objects, strokes: widget.strokes),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        for (var index = 0; index < _runs.length; index++)
          switch (_runs[index]) {
            final _ObjectRun run => BoardObjectLayer(
              key: ValueKey('scene-objects-$index-${run.objects.first.id}'),
              objects: run.objects,
              annotationLayers: widget.annotationLayers,
              annotationIndex: _annotationIndex,
              scale: widget.scale,
              offset: widget.offset,
              assets: widget.assets,
              selectedIds: widget.selectedIds,
              worldClip: widget.worldClip,
              objectsAreSceneOrdered: true,
            ),
            final _StrokeRun run => _buildStrokeRun(run, index),
          },
      ],
    );
  }

  Widget _buildStrokeRun(_StrokeRun run, int index) {
    final scale = widget.scale;
    if (!scale.isFinite ||
        scale <= 0 ||
        !widget.offset.dx.isFinite ||
        !widget.offset.dy.isFinite ||
        (widget.worldClip != null &&
            !run.worldBounds.intersects(widget.worldClip!))) {
      return const SizedBox.shrink();
    }
    // Stroke bounds already include half the physical nib width. The fixed
    // screen-space margin accommodates the selection halo and antialiasing.
    const screenMargin = 8.0;
    final left = widget.offset.dx + run.worldBounds.left * scale - screenMargin;
    final top = widget.offset.dy + run.worldBounds.top * scale - screenMargin;
    final width = run.worldBounds.width * scale + screenMargin * 2;
    final height = run.worldBounds.height * scale + screenMargin * 2;
    return Positioned(
      key: ValueKey('scene-ink-$index-${run.strokes.first.id}'),
      left: left,
      top: top,
      width: width.clamp(1.0, double.maxFinite).toDouble(),
      height: height.clamp(1.0, double.maxFinite).toDouble(),
      child: PersistedInkLayer(
        strokes: run.strokes,
        worldToScreenScale: scale,
        worldToScreenOffset: widget.offset - Offset(left, top),
        // The complete run is already culled before this widget is built.
        // Passing the moving viewport clip down would repaint every cached
        // picture during a pure pan even though this run-local transform is
        // stable.
        worldClip: null,
        // Keep each painter independent from the global selection set.
        // Select-all previously compared that full set in every run, turning
        // one frame into O(runs × selected items).
        selectionIds: <String>{
          for (final stroke in run.strokes)
            if (widget.selectedIds.contains(stroke.id)) stroke.id,
        },
      ),
    );
  }
}

List<_SceneRun> _buildRuns(List<BoardSceneItem> scene) {
  final result = <_SceneRun>[];
  for (final item in scene) {
    final object = item.object;
    if (object != null) {
      final previous = result.lastOrNull;
      if (previous is _ObjectRun) {
        previous.objects.add(object);
      } else {
        result.add(_ObjectRun(<BoardObject>[object]));
      }
      continue;
    }
    final previous = result.lastOrNull;
    if (previous is _StrokeRun && previous.canAppend(item.stroke!)) {
      previous.add(item.stroke!);
    } else {
      result.add(_StrokeRun(<InkStroke>[item.stroke!]));
    }
  }
  return result;
}

sealed class _SceneRun {}

final class _ObjectRun extends _SceneRun {
  _ObjectRun(this.objects);

  final List<BoardObject> objects;
}

final class _StrokeRun extends _SceneRun {
  _StrokeRun(this.strokes)
    : _pointCount = strokes.fold<int>(
        0,
        (total, stroke) => total + stroke.points.length,
      ),
      worldBounds = strokes.skip(1).fold<Rect2>(strokes.first.bounds, (
        bounds,
        stroke,
      ) {
        return bounds.union(stroke.bounds);
      });

  final List<InkStroke> strokes;
  int _pointCount;
  Rect2 worldBounds;

  bool canAppend(InkStroke stroke) {
    if (strokes.length >= _maxStrokeBatchLength ||
        _pointCount + stroke.points.length > _maxStrokeBatchPoints) {
      return false;
    }
    final combined = worldBounds.union(stroke.bounds);
    if (!combined.left.isFinite ||
        !combined.top.isFinite ||
        !combined.width.isFinite ||
        !combined.height.isFinite) {
      return false;
    }
    return combined.width <= _maxStrokeBatchWorldExtent &&
        combined.height <= _maxStrokeBatchWorldExtent &&
        combined.width * combined.height <= _maxStrokeBatchWorldArea;
  }

  void add(InkStroke stroke) {
    strokes.add(stroke);
    _pointCount += stroke.points.length;
    worldBounds = worldBounds.union(stroke.bounds);
  }
}

const int _maxStrokeBatchLength = 48;
const int _maxStrokeBatchPoints = 2048;
const double _maxStrokeBatchWorldExtent = 2048;
const double _maxStrokeBatchWorldArea = 2048 * 2048;
