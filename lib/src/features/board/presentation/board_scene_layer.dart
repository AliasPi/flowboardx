import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/model/board_object.dart';
import '../../../domain/model/geometry.dart';
import '../../../domain/model/ink.dart';
import '../../../domain/model/scene_order.dart';
import '../engine/spatial_index.dart';
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
  final Map<String, _SceneLocation> _locations = <String, _SceneLocation>{};
  final SpatialIndex<int> _strokeRunVisibility = SpatialIndex<int>(
    cellSize: _strokeVisibilityCellSize,
  );
  final SpatialIndex<int> _objectRunVisibility = SpatialIndex<int>(
    cellSize: _objectVisibilityCellSize,
  );
  final List<int> _unindexedStrokeRunIndices = <int>[];
  final List<int> _unindexedObjectRunIndices = <int>[];
  int _maximumSceneZIndex = -1;

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
      if (!_tryAppendTopmostStroke(oldWidget) &&
          !_tryRefreshSparseScene(oldWidget) &&
          !_tryRefreshStableScene(oldWidget)) {
        _rebuildRuns();
      }
    }
    if (!identical(oldWidget.annotationLayers, widget.annotationLayers)) {
      _annotationIndex = VisibleObjectInkLayerIndex(widget.annotationLayers);
    }
  }

  void _rebuildRuns() {
    final scene = orderedBoardSceneItems(
      objects: widget.objects,
      strokes: widget.strokes,
    );
    _runs = _buildRuns(scene);
    _rebuildLocations();
    _rebuildRunVisibility();
    _maximumSceneZIndex = scene.isEmpty ? -1 : scene.last.zIndex;
  }

  void _rebuildRunVisibility() {
    _strokeRunVisibility.clear();
    _objectRunVisibility.clear();
    _unindexedStrokeRunIndices.clear();
    _unindexedObjectRunIndices.clear();
    for (var index = 0; index < _runs.length; index++) {
      switch (_runs[index]) {
        case final _ObjectRun run:
          _indexObjectRun(index, run);
        case final _StrokeRun run:
          _indexStrokeRun(index, run);
      }
    }
  }

  void _indexObjectRun(int index, _ObjectRun run) {
    if (!_indexRunBounds(
      _objectRunVisibility,
      index,
      run.worldBounds,
      cellSize: _objectVisibilityCellSize,
    )) {
      _unindexedObjectRunIndices.add(index);
    }
  }

  void _indexStrokeRun(int index, _StrokeRun run) {
    if (!_indexRunBounds(
      _strokeRunVisibility,
      index,
      run.worldBounds,
      cellSize: _strokeVisibilityCellSize,
    )) {
      _unindexedStrokeRunIndices.add(index);
    }
  }

  bool _indexRunBounds(
    SpatialIndex<int> index,
    int runIndex,
    Rect2 bounds, {
    required double cellSize,
  }) {
    if (!bounds.left.isFinite ||
        !bounds.top.isFinite ||
        !bounds.right.isFinite ||
        !bounds.bottom.isFinite) {
      return false;
    }
    final horizontalCells = bounds.width / cellSize + 2;
    final verticalCells = bounds.height / cellSize + 2;
    if (!horizontalCells.isFinite ||
        !verticalCells.isFinite ||
        horizontalCells * verticalCells >
            _maximumRunVisibilityCellMemberships) {
      // A malformed import (or one exceptionally large gesture) must never
      // expand a uniform grid across millions of cells. Such rare runs remain
      // correct through a tiny linear fallback list.
      return false;
    }
    // SpatialIndex uses Rect.overlaps (exclusive at touching edges), while the
    // document model deliberately treats touching bounds as visible.
    index.insert(
      runIndex,
      Rect.fromLTRB(
        bounds.left,
        bounds.top,
        bounds.right,
        bounds.bottom,
      ).inflate(.0001),
    );
    return true;
  }

  void _replaceRun(int index, _SceneRun replacement) {
    final previous = _runs[index];
    switch (previous) {
      case _ObjectRun():
        _objectRunVisibility.remove(index);
        _unindexedObjectRunIndices.remove(index);
      case _StrokeRun():
        _strokeRunVisibility.remove(index);
        _unindexedStrokeRunIndices.remove(index);
    }
    _runs[index] = replacement;
    switch (replacement) {
      case final _ObjectRun run:
        _indexObjectRun(index, run);
      case final _StrokeRun run:
        _indexStrokeRun(index, run);
    }
  }

  void _rebuildLocations() {
    _locations.clear();
    for (var runIndex = 0; runIndex < _runs.length; runIndex++) {
      switch (_runs[runIndex]) {
        case final _ObjectRun run:
          for (var itemIndex = 0; itemIndex < run.objects.length; itemIndex++) {
            _locations[run.objects[itemIndex].id] = _SceneLocation(
              runIndex: runIndex,
              itemIndex: itemIndex,
              kind: BoardSceneItemKind.object,
            );
          }
        case final _StrokeRun run:
          for (var itemIndex = 0; itemIndex < run.strokes.length; itemIndex++) {
            _locations[run.strokes[itemIndex].id] = _SceneLocation(
              runIndex: runIndex,
              itemIndex: itemIndex,
              kind: BoardSceneItemKind.stroke,
            );
          }
      }
    }
  }

  /// Handles the overwhelmingly common completed-ink update without sorting
  /// and partitioning the complete page scene again.
  ///
  /// The identity prefix check is intentionally strict. Erasing, transforms
  /// and participant merges can also increase the list length by one; those
  /// updates must take the full correctness path.
  bool _tryAppendTopmostStroke(BoardSceneLayer oldWidget) {
    if (!identical(oldWidget.objects, widget.objects) ||
        widget.strokes.length != oldWidget.strokes.length + 1) {
      return false;
    }
    final nextStrokes = widget.strokes;
    final hasProvenSingleAppend = switch (nextStrokes) {
      final SingleAppendSceneList<InkStroke> appendList =>
        appendList.isSingleAppendOf(oldWidget.strokes),
      _ => false,
    };
    if (!hasProvenSingleAppend) {
      // Plain List implementations do not expose immutable ancestry. Retain
      // the strict compatibility path for them rather than guessing from
      // length/last item and accidentally accepting an erase-plus-append.
      for (var index = 0; index < oldWidget.strokes.length; index++) {
        if (!identical(oldWidget.strokes[index], nextStrokes[index])) {
          return false;
        }
      }
    }
    final appended = nextStrokes.last;
    if (appended.zIndex < _maximumSceneZIndex) return false;

    final previous = _runs.lastOrNull;
    if (previous is _StrokeRun && previous.canAppend(appended)) {
      // Never mutate [previous.strokes]: that list is still owned by the
      // previous PersistedInkLayer widget. Replacing only the bounded final
      // batch keeps every earlier run and vector cache exactly intact.
      _replaceRun(
        _runs.length - 1,
        _StrokeRun(<InkStroke>[...previous.strokes, appended]),
      );
      _locations[appended.id] = _SceneLocation(
        runIndex: _runs.length - 1,
        itemIndex: previous.strokes.length,
        kind: BoardSceneItemKind.stroke,
      );
    } else {
      _runs.add(_StrokeRun(<InkStroke>[appended]));
      _indexStrokeRun(_runs.length - 1, _runs.last as _StrokeRun);
      _locations[appended.id] = _SceneLocation(
        runIndex: _runs.length - 1,
        itemIndex: 0,
        kind: BoardSceneItemKind.stroke,
      );
    }
    _maximumSceneZIndex = math.max(_maximumSceneZIndex, appended.zIndex);
    return true;
  }

  /// Applies a fixed-length sparse preview without inspecting the rest of the
  /// page. Selection and cover drags expose their changed source indices
  /// through [FixedSceneListOverlay], so this path stays proportional to the
  /// selected item count even on a page containing thousands of strokes.
  bool _tryRefreshSparseScene(BoardSceneLayer oldWidget) {
    final objectChanges = _sparseChanges(oldWidget.objects, widget.objects);
    if (objectChanges == null) return false;
    final strokeChanges = _sparseChanges(oldWidget.strokes, widget.strokes);
    if (strokeChanges == null) return false;
    return _applyStableReplacements(
      objectChanges: objectChanges,
      strokeChanges: strokeChanges,
    );
  }

  /// Refreshes item instances without sorting or repartitioning an unchanged
  /// scene order.
  ///
  /// Selection previews, cover reveals and other live transforms replace a
  /// small number of immutable objects/strokes while retaining every item id,
  /// z-index and source-list position. Re-sorting the complete page for every
  /// pointer packet made those interactions scale as O(N log N). The strict
  /// shape check below proves that the existing run partition is still valid;
  /// only runs containing a changed instance are then replaced.
  bool _tryRefreshStableScene(BoardSceneLayer oldWidget) {
    if (oldWidget.objects.length != widget.objects.length ||
        oldWidget.strokes.length != widget.strokes.length) {
      return false;
    }

    final objectChanges = <BoardObject>[];
    for (var index = 0; index < widget.objects.length; index++) {
      final previous = oldWidget.objects[index];
      final next = widget.objects[index];
      if (previous.id != next.id || previous.zIndex != next.zIndex) {
        return false;
      }
      if (!identical(previous, next)) objectChanges.add(next);
    }
    final strokeChanges = <InkStroke>[];
    for (var index = 0; index < widget.strokes.length; index++) {
      final previous = oldWidget.strokes[index];
      final next = widget.strokes[index];
      if (previous.id != next.id || previous.zIndex != next.zIndex) {
        return false;
      }
      if (!identical(previous, next)) strokeChanges.add(next);
    }
    return _applyStableReplacements(
      objectChanges: objectChanges,
      strokeChanges: strokeChanges,
    );
  }

  bool _applyStableReplacements({
    required Iterable<BoardObject> objectChanges,
    required Iterable<InkStroke> strokeChanges,
  }) {
    final objectReplacements = <int, Map<int, BoardObject>>{};
    for (final object in objectChanges) {
      final location = _locations[object.id];
      if (location == null ||
          location.kind != BoardSceneItemKind.object ||
          location.runIndex >= _runs.length) {
        return false;
      }
      final sourceRun = _runs[location.runIndex];
      if (sourceRun is! _ObjectRun ||
          location.itemIndex >= sourceRun.objects.length ||
          sourceRun.objects[location.itemIndex].id != object.id ||
          sourceRun.objects[location.itemIndex].zIndex != object.zIndex) {
        return false;
      }
      (objectReplacements[location.runIndex] ??=
              <int, BoardObject>{})[location.itemIndex] =
          object;
    }
    final strokeReplacements = <int, Map<int, InkStroke>>{};
    for (final stroke in strokeChanges) {
      final location = _locations[stroke.id];
      if (location == null ||
          location.kind != BoardSceneItemKind.stroke ||
          location.runIndex >= _runs.length) {
        return false;
      }
      final sourceRun = _runs[location.runIndex];
      if (sourceRun is! _StrokeRun ||
          location.itemIndex >= sourceRun.strokes.length ||
          sourceRun.strokes[location.itemIndex].id != stroke.id ||
          sourceRun.strokes[location.itemIndex].zIndex != stroke.zIndex) {
        return false;
      }
      (strokeReplacements[location.runIndex] ??=
              <int, InkStroke>{})[location.itemIndex] =
          stroke;
    }
    final nextObjectRuns = <int, _ObjectRun>{};
    for (final entry in objectReplacements.entries) {
      final sourceRun = _runs[entry.key] as _ObjectRun;
      final nextObjects = List<BoardObject>.of(sourceRun.objects);
      for (final replacement in entry.value.entries) {
        nextObjects[replacement.key] = replacement.value;
      }
      final nextRun = _ObjectRun(nextObjects);
      if (!nextRun.isValidBatch) return false;
      nextObjectRuns[entry.key] = nextRun;
    }
    final nextStrokeRuns = <int, _StrokeRun>{};
    for (final entry in strokeReplacements.entries) {
      final sourceRun = _runs[entry.key] as _StrokeRun;
      final nextStrokes = List<InkStroke>.of(sourceRun.strokes);
      for (final replacement in entry.value.entries) {
        nextStrokes[replacement.key] = replacement.value;
      }
      final nextRun = _StrokeRun(nextStrokes);
      if (!nextRun.isValidBatch) return false;
      nextStrokeRuns[entry.key] = nextRun;
    }
    for (final entry in nextObjectRuns.entries) {
      _replaceRun(entry.key, entry.value);
    }
    for (final entry in nextStrokeRuns.entries) {
      _replaceRun(entry.key, entry.value);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final visibleRunIndices = _visibleRunIndices();
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        for (final index in visibleRunIndices)
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

  Iterable<int> _visibleRunIndices() sync* {
    final clip = widget.worldClip;
    if (clip == null ||
        !clip.left.isFinite ||
        !clip.top.isFinite ||
        !clip.right.isFinite ||
        !clip.bottom.isFinite ||
        clip.width < 0 ||
        clip.height < 0 ||
        (clip.width / _strokeVisibilityCellSize + 2) *
                (clip.height / _strokeVisibilityCellSize + 2) >
            _maximumRunVisibilityCellMemberships) {
      for (var index = 0; index < _runs.length; index++) {
        yield index;
      }
      return;
    }

    final visibleStrokeIndexSet = _strokeRunVisibility.query(
      Rect.fromLTRB(clip.left, clip.top, clip.right, clip.bottom),
    );
    final visibleObjectIndexSet = _objectRunVisibility.query(
      Rect.fromLTRB(clip.left, clip.top, clip.right, clip.bottom),
    );
    for (final index in _unindexedStrokeRunIndices) {
      final run = _runs[index];
      if (run is _StrokeRun && run.worldBounds.intersects(clip)) {
        visibleStrokeIndexSet.add(index);
      }
    }
    for (final index in _unindexedObjectRunIndices) {
      final run = _runs[index];
      if (run is _ObjectRun && run.worldBounds.intersects(clip)) {
        visibleObjectIndexSet.add(index);
      }
    }
    visibleStrokeIndexSet.addAll(visibleObjectIndexSet);
    final visibleRunIndices = visibleStrokeIndexSet.toList(growable: false)
      ..sort();
    yield* visibleRunIndices;
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
    var screenBounds = Rect.fromLTRB(
      widget.offset.dx + run.worldBounds.left * scale - screenMargin,
      widget.offset.dy + run.worldBounds.top * scale - screenMargin,
      widget.offset.dx + run.worldBounds.right * scale + screenMargin,
      widget.offset.dy + run.worldBounds.bottom * scale + screenMargin,
    );
    var isolateRepaints = _canIsolateInkBounds(screenBounds);
    final clip = widget.worldClip;
    if (!isolateRepaints && clip != null) {
      final clipBounds = Rect.fromLTRB(
        widget.offset.dx + clip.left * scale - screenMargin,
        widget.offset.dy + clip.top * scale - screenMargin,
        widget.offset.dx + clip.right * scale + screenMargin,
        widget.offset.dy + clip.bottom * scale + screenMargin,
      );
      screenBounds = screenBounds.intersect(clipBounds);
    }
    if (!_validScreenBounds(screenBounds)) return const SizedBox.shrink();
    // Large circles and zoomed strokes must not retain one enormous raster
    // layer. Their vector picture remains cached, but painting is clipped to
    // the viewport and participates in the surrounding scene layer instead.
    isolateRepaints = isolateRepaints && _canIsolateInkBounds(screenBounds);
    final left = screenBounds.left;
    final top = screenBounds.top;
    return Positioned(
      key: ValueKey('scene-ink-$index-${run.strokes.first.id}'),
      left: left,
      top: top,
      width: screenBounds.width,
      height: screenBounds.height,
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
        selectionIds: run.selectionSubset(widget.selectedIds),
        isolateRepaints: isolateRepaints,
      ),
    );
  }
}

List<T>? _sparseChanges<T>(List<T> previous, List<T> next) {
  final FixedSceneListOverlay<T>? previousOverlay =
      previous is FixedSceneListOverlay<T>
      ? previous as FixedSceneListOverlay<T>
      : null;
  final FixedSceneListOverlay<T>? nextOverlay = next is FixedSceneListOverlay<T>
      ? next as FixedSceneListOverlay<T>
      : null;
  final previousSource = previousOverlay?.sceneSource ?? previous;
  final nextSource = nextOverlay?.sceneSource ?? next;
  if (!identical(previousSource, nextSource) ||
      previous.length != next.length) {
    return null;
  }
  final changedIndices = <int>{
    ...?previousOverlay?.sceneReplacements.keys,
    ...?nextOverlay?.sceneReplacements.keys,
  };
  final changes = <T>[];
  for (final index in changedIndices) {
    if (index < 0 || index >= next.length) return null;
    final before = previous[index];
    final after = next[index];
    if (!identical(before, after)) changes.add(after);
  }
  return changes;
}

List<_SceneRun> _buildRuns(List<BoardSceneItem> scene) {
  final result = <_SceneRun>[];
  for (final item in scene) {
    final object = item.object;
    if (object != null) {
      final previous = result.lastOrNull;
      if (previous is _ObjectRun && previous.canAppend(object)) {
        previous.add(object);
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

final class _SceneLocation {
  const _SceneLocation({
    required this.runIndex,
    required this.itemIndex,
    required this.kind,
  });

  final int runIndex;
  final int itemIndex;
  final BoardSceneItemKind kind;
}

final class _ObjectRun extends _SceneRun {
  _ObjectRun(this.objects)
    : worldBounds = objects
          .skip(1)
          .fold<Rect2>(
            objects.first.transform.bounds,
            (bounds, object) => bounds.union(object.transform.bounds),
          );

  final List<BoardObject> objects;
  Rect2 worldBounds;

  bool canAppend(BoardObject object) {
    if (objects.length >= _maxObjectBatchLength) return false;
    final combined = worldBounds.union(object.transform.bounds);
    return _validObjectBatchBounds(combined);
  }

  void add(BoardObject object) {
    objects.add(object);
    worldBounds = worldBounds.union(object.transform.bounds);
  }

  bool get isValidBatch =>
      objects.length <= 1 ||
      (objects.length <= _maxObjectBatchLength &&
          _validObjectBatchBounds(worldBounds));
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
  Set<String>? _selectionSource;
  Set<String> _selectedSubset = const <String>{};

  Set<String> selectionSubset(Set<String> selectedIds) {
    if (selectedIds.isEmpty) {
      // Do not let every retained run keep a former select-all set alive.
      _selectionSource = null;
      _selectedSubset = const <String>{};
      return _selectedSubset;
    }
    if (identical(_selectionSource, selectedIds)) return _selectedSubset;
    _selectionSource = selectedIds;
    _selectedSubset = Set<String>.unmodifiable(<String>{
      for (final stroke in strokes)
        if (selectedIds.contains(stroke.id)) stroke.id,
    });
    return _selectedSubset;
  }

  bool canAppend(InkStroke stroke) {
    if (strokes.length >= _maxStrokeBatchLength ||
        _pointCount + stroke.points.length > _maxStrokeBatchPoints) {
      return false;
    }
    final combined = worldBounds.union(stroke.bounds);
    return _validStrokeBatchBounds(combined);
  }

  void add(InkStroke stroke) {
    strokes.add(stroke);
    _pointCount += stroke.points.length;
    worldBounds = worldBounds.union(stroke.bounds);
  }

  bool get isValidBatch =>
      strokes.length <= 1 ||
      (strokes.length <= _maxStrokeBatchLength &&
          _pointCount <= _maxStrokeBatchPoints &&
          _validStrokeBatchBounds(worldBounds));
}

const int _maxStrokeBatchLength = 48;
const int _maxStrokeBatchPoints = 2048;
const double _maxStrokeBatchWorldExtent = 2048;
const double _maxStrokeBatchWorldArea = 2048 * 2048;
const int _maxObjectBatchLength = 32;
const double _maxObjectBatchWorldExtent = 2048;
const double _maxObjectBatchWorldArea = 2048 * 2048;
const double _strokeVisibilityCellSize = 1024;
const double _objectVisibilityCellSize = 1024;
const double _maximumRunVisibilityCellMemberships = 4096;
const double _maximumIsolatedInkLayerExtent = 2048;
const double _maximumIsolatedInkLayerArea = 2 * 1024 * 1024;

bool _validScreenBounds(Rect bounds) =>
    bounds.left.isFinite &&
    bounds.top.isFinite &&
    bounds.width.isFinite &&
    bounds.height.isFinite &&
    bounds.width > 0 &&
    bounds.height > 0;

bool _validObjectBatchBounds(Rect2 bounds) =>
    bounds.left.isFinite &&
    bounds.top.isFinite &&
    bounds.width.isFinite &&
    bounds.height.isFinite &&
    bounds.width <= _maxObjectBatchWorldExtent &&
    bounds.height <= _maxObjectBatchWorldExtent &&
    bounds.width * bounds.height <= _maxObjectBatchWorldArea;

bool _validStrokeBatchBounds(Rect2 bounds) =>
    bounds.left.isFinite &&
    bounds.top.isFinite &&
    bounds.width.isFinite &&
    bounds.height.isFinite &&
    bounds.width <= _maxStrokeBatchWorldExtent &&
    bounds.height <= _maxStrokeBatchWorldExtent &&
    bounds.width * bounds.height <= _maxStrokeBatchWorldArea;

bool _canIsolateInkBounds(Rect bounds) =>
    _validScreenBounds(bounds) &&
    bounds.width <= _maximumIsolatedInkLayerExtent &&
    bounds.height <= _maximumIsolatedInkLayerExtent &&
    bounds.width * bounds.height <= _maximumIsolatedInkLayerArea;
