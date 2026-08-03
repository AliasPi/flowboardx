import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../domain/model/board_object.dart';
import '../../domain/model/document.dart';
import '../../domain/model/geometry.dart';
import '../../domain/model/ink.dart';
import '../../domain/model/scene_order.dart';

enum SelectionCandidateType { object, stroke, letter, word, line, sketch }

class SelectionCandidate {
  const SelectionCandidate({
    required this.id,
    required this.itemIds,
    required this.bounds,
    required this.type,
    required this.score,
  });

  final String id;
  final List<String> itemIds;
  final Rect2 bounds;
  final SelectionCandidateType type;
  final double score;
}

/// The scene members behind one persisted editor selection.
///
/// Selection overlays need source indices as well as values so live transforms
/// can remain sparse. Resolving those members through the same identity-cached
/// indexes as hit testing keeps a passive selection proportional to the number
/// of selected items, rather than to every stroke on the page.
final class ResolvedSelectionMembers {
  const ResolvedSelectionMembers({
    required this.expandedIds,
    required this.objectIndices,
    required this.objects,
    required this.strokeIndices,
    required this.strokes,
    required this.selectedGroupBounds,
    required this.selectedContentGroup,
    required this.bounds,
  });

  static const empty = ResolvedSelectionMembers(
    expandedIds: <String>{},
    objectIndices: <int>[],
    objects: <BoardObject>[],
    strokeIndices: <int>[],
    strokes: <InkStroke>[],
    selectedGroupBounds: <Rect2>[],
    selectedContentGroup: null,
    bounds: Rect2.zero(),
  );

  final Set<String> expandedIds;
  final List<int> objectIndices;
  final List<BoardObject> objects;
  final List<int> strokeIndices;
  final List<InkStroke> strokes;
  final List<Rect2> selectedGroupBounds;
  final ContentGroup? selectedContentGroup;
  final Rect2 bounds;
}

@visibleForTesting
final class SelectionEngineDiagnostics {
  int strokeFullIndexBuilds = 0;
  int strokeIncrementalIndexUpdates = 0;
  int lastSpatialCandidateCount = 0;
}

class SelectionEngine {
  SelectionEngine({this.diagnostics, this.maximumCachedSnapshots = 2})
    : assert(maximumCachedSnapshots > 0),
      _objectIndexes =
          _IdentitySelectionCache<List<BoardObject>, _ObjectSelectionIndex>(
            _ObjectSelectionIndex.new,
            maximumEntries: maximumCachedSnapshots,
          ),
      _strokeIndexes = _StrokeSelectionIndexCache(maximumCachedSnapshots),
      _contentGroupIndexes =
          _IdentitySelectionCache<
            List<ContentGroup>,
            _ContentGroupSelectionIndex
          >(
            _ContentGroupSelectionIndex.new,
            maximumEntries: maximumCachedSnapshots,
          ),
      _inkGroupIndexes =
          _IdentitySelectionCache<List<InkGroup>, _InkGroupSelectionIndex>(
            _InkGroupSelectionIndex.new,
            maximumEntries: maximumCachedSnapshots,
          );

  /// Optional instrumentation for deterministic performance regressions.
  ///
  /// Production controllers leave this null, so hot queries only pay a null
  /// check. Tests use it to verify that a pen-up extends the cached stroke
  /// index instead of rebuilding every previously written stroke.
  @visibleForTesting
  final SelectionEngineDiagnostics? diagnostics;

  /// Spatial indexes duplicate IDs, bounds and cell memberships. Keeping them
  /// session-owned prevents a closed document from remaining reachable through
  /// a process-wide cache. Two snapshots are sufficient for the two visible
  /// participants while still making their page-local queries incremental.
  final int maximumCachedSnapshots;
  final _IdentitySelectionCache<List<BoardObject>, _ObjectSelectionIndex>
  _objectIndexes;
  final _StrokeSelectionIndexCache _strokeIndexes;
  final _IdentitySelectionCache<List<ContentGroup>, _ContentGroupSelectionIndex>
  _contentGroupIndexes;
  final _IdentitySelectionCache<List<InkGroup>, _InkGroupSelectionIndex>
  _inkGroupIndexes;

  @visibleForTesting
  int get cachedStrokeSnapshotCount => _strokeIndexes.entryCount;

  @visibleForTesting
  int get cachedObjectSnapshotCount => _objectIndexes.entryCount;

  @visibleForTesting
  int get cachedContentGroupSnapshotCount => _contentGroupIndexes.entryCount;

  @visibleForTesting
  int get cachedInkGroupSnapshotCount => _inkGroupIndexes.entryCount;

  /// Releases the duplicated lookup data at an editor lifecycle boundary.
  /// The engine remains reusable and lazily recreates only the next active
  /// snapshot if queried again.
  void clearCaches() {
    _objectIndexes.clear();
    _strokeIndexes.clear();
    _contentGroupIndexes.clear();
    _inkGroupIndexes.clear();
  }

  List<SelectionCandidate> candidatesAt(
    BoardPage page,
    Vec2 point, {
    double tolerance = 12,
    Iterable<InkGroup>? inkGroupCandidates,
  }) {
    if (!point.x.isFinite || !point.y.isFinite) {
      return const <SelectionCandidate>[];
    }
    final searchRadius = _safeTolerance(tolerance);
    final objectIndex = _objectIndexes.resolve(page.objects);
    final strokeIndex = _strokeIndexes.resolve(
      page.strokes,
      diagnostics: diagnostics,
    );
    final contentIndex = _contentGroupIndexes.resolve(page.contentGroups);
    final groupIndex = inkGroupCandidates == null
        ? _inkGroupIndexes.resolve(page.groups)
        : null;
    final searchBounds = _pointSearchBounds(point, searchRadius);
    final objectHits = objectIndex.query(searchBounds)..sort();
    final strokeHits = strokeIndex.query(searchBounds)..sort();
    final contentHits = contentIndex.query(searchBounds)..sort();
    final semanticHits = inkGroupCandidates?.toList(growable: false);
    final groupHits = semanticHits == null
        ? (groupIndex!.query(searchBounds)..sort())
        : const <int>[];
    diagnostics?.lastSpatialCandidateCount =
        objectHits.length +
        strokeHits.length +
        contentHits.length +
        (semanticHits?.length ?? groupHits.length);

    final result = <SelectionCandidate>[];
    final ordering = _SceneOrdering(objectIndex, strokeIndex);
    for (final hit in objectHits) {
      final entry = objectIndex.entries[hit];
      final object = entry.value;
      if (contentIndex.groupsByMember.containsKey(object.id)) continue;
      if (!object.locked &&
          object.transform.containsWorld(point, tolerance: searchRadius)) {
        result.add(
          SelectionCandidate(
            id: object.id,
            itemIds: <String>[object.id],
            bounds: entry.bounds,
            type: SelectionCandidateType.object,
            score: 10000 + ordering.objectRank(entry).toDouble(),
          ),
        );
      }
    }
    for (final hit in strokeHits) {
      final entry = strokeIndex.entries[hit];
      final stroke = entry.value;
      if (contentIndex.groupsByMember.containsKey(stroke.id) ||
          !entry.bounds.inflate(searchRadius).contains(point)) {
        continue;
      }
      if (_strokeIsWithin(point, stroke, searchRadius + stroke.width / 2)) {
        result.add(
          SelectionCandidate(
            id: stroke.id,
            itemIds: <String>[stroke.id],
            bounds: entry.bounds,
            type: SelectionCandidateType.stroke,
            score: 10000 + ordering.strokeRank(entry).toDouble(),
          ),
        );
      }
    }

    // The historic implementation visited persistent groups back-to-front.
    // Sorting the local indices preserves that stable tie order without
    // scanning every group on the page.
    for (final hit in contentHits.reversed) {
      final group = contentIndex.source[hit];
      if (group.locked || !group.bounds.inflate(searchRadius).contains(point)) {
        continue;
      }
      result.add(
        SelectionCandidate(
          id: group.id,
          itemIds: [group.id],
          bounds: group.bounds,
          type: SelectionCandidateType.object,
          score:
              10000 +
              group.memberIds.fold<int>(
                    -1,
                    (rank, id) => math.max(rank, ordering.rankOfId(id)),
                  ) /
                  1000,
        ),
      );
    }

    final groups =
        semanticHits ??
        <InkGroup>[for (final hit in groupHits) groupIndex!.source[hit]];
    for (final group in groups) {
      if (group.strokeIds.any(contentIndex.groupsByMember.containsKey)) {
        continue;
      }
      if (!group.bounds.inflate(searchRadius).contains(point)) continue;
      result.add(
        SelectionCandidate(
          id: group.id,
          itemIds: group.strokeIds,
          bounds: group.bounds,
          type: switch (group.kind) {
            InkGroupKind.letter => SelectionCandidateType.letter,
            InkGroupKind.word => SelectionCandidateType.word,
            InkGroupKind.line => SelectionCandidateType.line,
            InkGroupKind.sketch ||
            InkGroupKind.manual => SelectionCandidateType.sketch,
          },
          score:
              _groupScore(group.kind, group.bounds) +
              group.strokeIds.fold<int>(
                    -1,
                    (rank, id) => math.max(rank, ordering.rankOfId(id)),
                  ) /
                  1000,
        ),
      );
    }
    result.sort((a, b) => b.score.compareTo(a.score));
    return result;
  }

  /// Allocation-light occupancy check used by the empty-board long press.
  ///
  /// The previous route constructed and sorted every selection candidate just
  /// to ask whether the list was empty. This stops on the first real local hit
  /// and never walks off-screen page content.
  bool hasSelectableAt(
    BoardPage page,
    Vec2 point, {
    double tolerance = 12,
    Iterable<InkGroup>? inkGroupCandidates,
  }) {
    if (!point.x.isFinite || !point.y.isFinite) return false;
    final searchRadius = _safeTolerance(tolerance);
    final searchBounds = _pointSearchBounds(point, searchRadius);
    final contentIndex = _contentGroupIndexes.resolve(page.contentGroups);

    for (final hit in contentIndex.query(searchBounds)) {
      final group = contentIndex.source[hit];
      if (!group.locked && group.bounds.inflate(searchRadius).contains(point)) {
        return true;
      }
    }
    final objectIndex = _objectIndexes.resolve(page.objects);
    for (final hit in objectIndex.query(searchBounds)) {
      final object = objectIndex.entries[hit].value;
      if (contentIndex.groupsByMember.containsKey(object.id)) continue;
      if (!object.locked &&
          object.transform.containsWorld(point, tolerance: searchRadius)) {
        return true;
      }
    }
    final strokeIndex = _strokeIndexes.resolve(
      page.strokes,
      diagnostics: diagnostics,
    );
    for (final hit in strokeIndex.query(searchBounds)) {
      final entry = strokeIndex.entries[hit];
      final stroke = entry.value;
      if (contentIndex.groupsByMember.containsKey(stroke.id)) continue;
      if (entry.bounds.inflate(searchRadius).contains(point) &&
          _strokeIsWithin(point, stroke, searchRadius + stroke.width / 2)) {
        return true;
      }
    }
    final groups = inkGroupCandidates;
    if (groups != null) {
      for (final group in groups) {
        if (group.strokeIds.any(contentIndex.groupsByMember.containsKey)) {
          continue;
        }
        if (group.bounds.inflate(searchRadius).contains(point)) return true;
      }
      return false;
    }
    final groupIndex = _inkGroupIndexes.resolve(page.groups);
    for (final hit in groupIndex.query(searchBounds)) {
      final group = groupIndex.source[hit];
      if (group.strokeIds.any(contentIndex.groupsByMember.containsKey)) {
        continue;
      }
      if (group.bounds.inflate(searchRadius).contains(point)) return true;
    }
    return false;
  }

  Set<String> itemsInRectangle(BoardPage page, Rect2 selection) {
    if (!_validBounds(selection)) return const <String>{};
    final objectIndex = _objectIndexes.resolve(page.objects);
    final strokeIndex = _strokeIndexes.resolve(
      page.strokes,
      diagnostics: diagnostics,
    );
    final contentIndex = _contentGroupIndexes.resolve(page.contentGroups);
    final objectHits = objectIndex.query(selection)..sort();
    final strokeHits = strokeIndex.query(selection)..sort();
    diagnostics?.lastSpatialCandidateCount =
        objectHits.length + strokeHits.length;
    final selected = <String>{};
    for (final hit in objectHits) {
      final entry = objectIndex.entries[hit];
      final object = entry.value;
      if (!object.locked && selection.intersects(entry.bounds)) {
        selected.add(object.id);
      }
    }
    for (final hit in strokeHits) {
      final entry = strokeIndex.entries[hit];
      if (selection.intersects(entry.bounds)) selected.add(entry.value.id);
    }
    return _respectContentGroups(contentIndex, selected);
  }

  Set<String> itemsInLasso(BoardPage page, List<Vec2> polygon) {
    if (polygon.length < 3) return const <String>{};
    final boundedPolygon = simplifyLasso(polygon);
    final polygonBounds = Rect2.fromPoints(boundedPolygon);
    if (!_validBounds(polygonBounds)) return const <String>{};
    final objectIndex = _objectIndexes.resolve(page.objects);
    final strokeIndex = _strokeIndexes.resolve(
      page.strokes,
      diagnostics: diagnostics,
    );
    final contentIndex = _contentGroupIndexes.resolve(page.contentGroups);
    final objectHits = objectIndex.query(polygonBounds)..sort();
    final strokeHits = strokeIndex.query(polygonBounds)..sort();
    diagnostics?.lastSpatialCandidateCount =
        objectHits.length + strokeHits.length;
    final selected = <String>{};
    for (final hit in objectHits) {
      final entry = objectIndex.entries[hit];
      final object = entry.value;
      if (!object.locked &&
          entry.bounds.intersects(polygonBounds) &&
          _insidePolygonXY(
            entry.bounds.left + entry.bounds.width / 2,
            entry.bounds.top + entry.bounds.height / 2,
            boundedPolygon,
          )) {
        selected.add(object.id);
      }
    }
    for (final hit in strokeHits) {
      final entry = strokeIndex.entries[hit];
      if (entry.bounds.intersects(polygonBounds) &&
          _insidePolygonXY(
            entry.bounds.left + entry.bounds.width / 2,
            entry.bounds.top + entry.bounds.height / 2,
            boundedPolygon,
          )) {
        selected.add(entry.value.id);
      }
    }
    return _respectContentGroups(contentIndex, selected);
  }

  /// Keeps lasso hit testing bounded while retaining the strongest turn in
  /// every input bucket. Smartboards can emit thousands of samples for one
  /// outline; testing every scene item against all of them scales poorly.
  static List<Vec2> simplifyLasso(
    List<Vec2> source, {
    int maximumVertices = 256,
  }) {
    if (source.length <= maximumVertices || maximumVertices < 3) return source;
    final result = <Vec2>[source.first];
    final interiorCount = source.length - 2;
    final bucketCount = maximumVertices - 2;
    for (var bucket = 0; bucket < bucketCount; bucket++) {
      final start =
          1 +
          (bucket * interiorCount ~/ bucketCount)
              .clamp(0, interiorCount - 1)
              .toInt();
      final endExclusive =
          1 +
          ((bucket + 1) * interiorCount ~/ bucketCount)
              .clamp(1, interiorCount)
              .toInt();
      final chordStart = source[start - 1];
      final chordEnd = source[math.min(source.length - 1, endExclusive)];
      final chordX = chordEnd.x - chordStart.x;
      final chordY = chordEnd.y - chordStart.y;
      final chordLengthSquared = chordX * chordX + chordY * chordY;
      var selectedIndex = start;
      var greatestDeviation = -1.0;
      for (var index = start; index < endExclusive; index++) {
        final point = source[index];
        final deviation = chordLengthSquared <= 1e-12
            ? math.pow(point.x - chordStart.x, 2) +
                  math.pow(point.y - chordStart.y, 2)
            : math.pow(
                    (point.x - chordStart.x) * chordY -
                        (point.y - chordStart.y) * chordX,
                    2,
                  ) /
                  chordLengthSquared;
        if (deviation > greatestDeviation) {
          greatestDeviation = deviation.toDouble();
          selectedIndex = index;
        }
      }
      if (!identical(source[selectedIndex], result.last)) {
        result.add(source[selectedIndex]);
      }
    }
    if (!identical(result.last, source.last)) result.add(source.last);
    return result;
  }

  /// Selects persistent content groups atomically and leaves ungrouped items
  /// individually addressable.
  Set<String> allItems(BoardPage page) {
    final contentIndex = _contentGroupIndexes.resolve(page.contentGroups);
    return _respectContentGroups(contentIndex, <String>{
      ...page.objects.map((object) => object.id),
      ...page.strokes.map((stroke) => stroke.id),
    });
  }

  /// Retains valid selection IDs without rebuilding a full-page ID set.
  ///
  /// In two-person mode one participant can keep a selection while the other
  /// writes. The shared document publishes on every pen-up; scanning every
  /// stroke, object and group for each such commit made the inactive
  /// participant's selection check grow with page size. The same bounded LRU
  /// indexes used for hit testing already provide constant-time ID lookup.
  Set<String> retainExistingIds(BoardPage page, Iterable<String> ids) {
    final requested = ids is Set<String> ? ids : ids.toSet();
    if (requested.isEmpty) return const <String>{};
    final objects = _objectIndexes.resolve(page.objects);
    _StrokeSelectionIndex? strokes;
    _ContentGroupSelectionIndex? contentGroups;
    _InkGroupSelectionIndex? inkGroups;
    final retained = <String>{};
    for (final id in requested) {
      if (objects.byId.containsKey(id)) {
        retained.add(id);
        continue;
      }
      if ((strokes ??= _strokeIndexes.resolve(
        page.strokes,
        diagnostics: diagnostics,
      )).byId.containsKey(id)) {
        retained.add(id);
        continue;
      }
      if ((contentGroups ??= _contentGroupIndexes.resolve(
        page.contentGroups,
      )).byId.containsKey(id)) {
        retained.add(id);
        continue;
      }
      if ((inkGroups ??= _inkGroupIndexes.resolve(
        page.groups,
      )).byId.containsKey(id)) {
        retained.add(id);
      }
    }
    return retained;
  }

  /// Resolves selected groups and scene items without walking the full page.
  ///
  /// Direct object and stroke IDs deliberately take the fast path before group
  /// indexes are materialized. This is the common case while the other
  /// participant keeps writing: the stroke index advances by one append and a
  /// selected object does not even touch the ink-group index.
  ResolvedSelectionMembers resolveSelectionMembers(
    BoardPage page,
    Set<String> selectedIds,
  ) {
    if (selectedIds.isEmpty) return ResolvedSelectionMembers.empty;

    final objectIndex = _objectIndexes.resolve(page.objects);
    _StrokeSelectionIndex? strokeIndex;
    _ContentGroupSelectionIndex? contentIndex;
    _InkGroupSelectionIndex? inkGroupIndex;
    final expandedIds = <String>{};
    final selectedGroupBounds = <Rect2>[];
    ContentGroup? selectedContentGroup;
    Rect2? bounds;

    for (final id in selectedIds) {
      final object = objectIndex.byId[id];
      if (object != null) {
        expandedIds.add(id);
        bounds = bounds == null ? object.bounds : bounds.union(object.bounds);
        continue;
      }
      final stroke = (strokeIndex ??= _strokeIndexes.resolve(
        page.strokes,
        diagnostics: diagnostics,
      )).byId[id];
      if (stroke != null) {
        expandedIds.add(id);
        bounds = bounds == null ? stroke.bounds : bounds.union(stroke.bounds);
        continue;
      }
      final content = (contentIndex ??= _contentGroupIndexes.resolve(
        page.contentGroups,
      )).byId[id];
      if (content != null) {
        expandedIds.addAll(content.memberIds);
        selectedGroupBounds.add(content.bounds);
        bounds = bounds == null ? content.bounds : bounds.union(content.bounds);
        if (selectedIds.length == 1) selectedContentGroup = content;
        continue;
      }
      final inkGroup = (inkGroupIndex ??= _inkGroupIndexes.resolve(
        page.groups,
      )).byId[id];
      if (inkGroup != null) {
        expandedIds.addAll(inkGroup.strokeIds);
        selectedGroupBounds.add(inkGroup.bounds);
        bounds = bounds == null
            ? inkGroup.bounds
            : bounds.union(inkGroup.bounds);
        continue;
      }
      // Preserve the legacy behavior for a temporarily stale ID. It will not
      // resolve to a scene item below and is removed by the controller's
      // validity pass after the document event.
      expandedIds.add(id);
    }

    final objectEntries = <_IndexedValue<BoardObject>>[];
    final strokeEntries = <_IndexedValue<InkStroke>>[];
    for (final id in expandedIds) {
      final object = objectIndex.byId[id];
      if (object != null) {
        objectEntries.add(object);
        continue;
      }
      final stroke = (strokeIndex ??= _strokeIndexes.resolve(
        page.strokes,
        diagnostics: diagnostics,
      )).byId[id];
      if (stroke != null) strokeEntries.add(stroke);
    }
    objectEntries.sort((a, b) => a.sourceIndex.compareTo(b.sourceIndex));
    strokeEntries.sort((a, b) => a.sourceIndex.compareTo(b.sourceIndex));

    if (bounds == null) {
      for (final entry in objectEntries) {
        bounds = bounds == null ? entry.bounds : bounds.union(entry.bounds);
      }
      for (final entry in strokeEntries) {
        bounds = bounds == null ? entry.bounds : bounds.union(entry.bounds);
      }
    }
    return ResolvedSelectionMembers(
      expandedIds: Set<String>.unmodifiable(expandedIds),
      objectIndices: List<int>.unmodifiable(
        objectEntries.map((entry) => entry.sourceIndex),
      ),
      objects: List<BoardObject>.unmodifiable(
        objectEntries.map((entry) => entry.value),
      ),
      strokeIndices: List<int>.unmodifiable(
        strokeEntries.map((entry) => entry.sourceIndex),
      ),
      strokes: List<InkStroke>.unmodifiable(
        strokeEntries.map((entry) => entry.value),
      ),
      selectedGroupBounds: List<Rect2>.unmodifiable(selectedGroupBounds),
      selectedContentGroup: selectedContentGroup,
      bounds: bounds ?? const Rect2.zero(),
    );
  }

  Rect2 boundsOf(BoardPage page, Iterable<String> ids) {
    Rect2? bounds;
    final lookup = ids.toSet();
    for (final group in page.contentGroups) {
      if (lookup.contains(group.id)) {
        bounds = bounds == null ? group.bounds : bounds.union(group.bounds);
      }
    }
    for (final object in page.objects) {
      if (lookup.contains(object.id)) {
        bounds = bounds == null
            ? object.transform.bounds
            : bounds.union(object.transform.bounds);
      }
    }
    for (final stroke in page.strokes) {
      if (lookup.contains(stroke.id)) {
        bounds = bounds == null ? stroke.bounds : bounds.union(stroke.bounds);
      }
    }
    return bounds ?? const Rect2.zero();
  }

  /// Hit-tests one already known stroke without sorting or scanning the page.
  ///
  /// Selection drags call this for the handful of selected strokes. Routing
  /// that interaction through [candidatesAt] used to rebuild and sort the
  /// complete mixed scene on every new finger contact.
  bool strokeContainsPoint(
    InkStroke stroke,
    Vec2 point, {
    double tolerance = 12,
  }) {
    if (!point.x.isFinite ||
        !point.y.isFinite ||
        !tolerance.isFinite ||
        tolerance.isNegative ||
        !stroke.bounds.inflate(tolerance).contains(point)) {
      return false;
    }
    return _strokeIsWithin(point, stroke, tolerance + stroke.width / 2);
  }

  static double _groupScore(InkGroupKind kind, Rect2 bounds) {
    final base = switch (kind) {
      InkGroupKind.word => 760.0,
      InkGroupKind.letter => 720.0,
      InkGroupKind.line => 680.0,
      InkGroupKind.sketch => 640.0,
      InkGroupKind.manual => 800.0,
    };
    return base - math.log(math.max(1, bounds.width * bounds.height));
  }

  static bool _strokeIsWithin(Vec2 point, InkStroke stroke, double threshold) {
    if (stroke.points.isEmpty || !threshold.isFinite || threshold.isNegative) {
      return false;
    }
    final thresholdSquared = threshold * threshold;
    if (stroke.points.length == 1) {
      final only = stroke.points.first;
      final dx = point.x - only.x;
      final dy = point.y - only.y;
      return dx * dx + dy * dy <= thresholdSquared;
    }
    for (var i = 1; i < stroke.points.length; i++) {
      final first = stroke.points[i - 1];
      final second = stroke.points[i];
      if (_distanceSquaredToSegment(
            point.x,
            point.y,
            first.x,
            first.y,
            second.x,
            second.y,
          ) <=
          thresholdSquared) {
        // Boundary taps on large circles are the common case. Returning on
        // the first hit avoids walking every remaining segment and avoids the
        // temporary Vec2 allocation previously created for every point pair.
        return true;
      }
    }
    return false;
  }

  static double _distanceSquaredToSegment(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final dx = bx - ax;
    final dy = by - ay;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared <= 1e-12) {
      final pointDx = px - ax;
      final pointDy = py - ay;
      return pointDx * pointDx + pointDy * pointDy;
    }
    final t = (((px - ax) * dx + (py - ay) * dy) / lengthSquared).clamp(
      0.0,
      1.0,
    );
    final nearestX = ax + t * dx;
    final nearestY = ay + t * dy;
    final pointDx = px - nearestX;
    final pointDy = py - nearestY;
    return pointDx * pointDx + pointDy * pointDy;
  }

  static bool _insidePolygonXY(
    double pointX,
    double pointY,
    List<Vec2> polygon,
  ) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final a = polygon[i];
      final b = polygon[j];
      final crosses =
          (a.y > pointY) != (b.y > pointY) &&
          pointX < (b.x - a.x) * (pointY - a.y) / (b.y - a.y) + a.x;
      if (crosses) inside = !inside;
    }
    return inside;
  }

  static Set<String> _respectContentGroups(
    _ContentGroupSelectionIndex index,
    Set<String> selected,
  ) {
    if (selected.isEmpty || index.source.isEmpty) return selected;
    final groupIndices = <int>{};
    for (final itemId in selected) {
      final memberships = index.groupsByMember[itemId];
      if (memberships != null) groupIndices.addAll(memberships);
    }
    if (groupIndices.isEmpty) return selected;
    final result = selected.toSet();
    final orderedIndices = groupIndices.toList()..sort();
    for (final groupIndex in orderedIndices) {
      final group = index.source[groupIndex];
      result
        ..removeAll(group.memberIds)
        ..add(group.id);
    }
    return result;
  }
}

double _safeTolerance(double value) => value.isFinite ? math.max(0, value) : 12;

Rect2 _pointSearchBounds(Vec2 point, double radius) => Rect2(
  left: point.x - radius,
  top: point.y - radius,
  width: radius * 2,
  height: radius * 2,
);

bool _validBounds(Rect2 bounds) =>
    bounds.left.isFinite &&
    bounds.top.isFinite &&
    bounds.right.isFinite &&
    bounds.bottom.isFinite &&
    bounds.width >= 0 &&
    bounds.height >= 0;

final class _IndexedValue<T extends Object> {
  const _IndexedValue({
    required this.value,
    required this.sourceIndex,
    required this.bounds,
  });

  final T value;
  final int sourceIndex;
  final Rect2 bounds;
}

final class _ObjectSelectionIndex {
  _ObjectSelectionIndex(this.source) {
    var previousZ = -0x7FFFFFFFFFFFFFFF;
    for (var sourceIndex = 0; sourceIndex < source.length; sourceIndex++) {
      final object = source[sourceIndex];
      final entry = _IndexedValue<BoardObject>(
        value: object,
        sourceIndex: sourceIndex,
        bounds: object.transform.bounds,
      );
      entries.add(entry);
      byId[object.id] = entry;
      spatial.insert(sourceIndex, entry.bounds);
      if (object.zIndex < previousZ) monotonicZ = false;
      previousZ = object.zIndex;
    }
  }

  final List<BoardObject> source;
  final List<_IndexedValue<BoardObject>> entries =
      <_IndexedValue<BoardObject>>[];
  final Map<String, _IndexedValue<BoardObject>> byId =
      <String, _IndexedValue<BoardObject>>{};
  final _SelectionBoundsGrid spatial = _SelectionBoundsGrid();
  bool monotonicZ = true;

  List<int> query(Rect2 bounds) => spatial.query(bounds);
}

final class _StrokeSelectionIndex {
  _StrokeSelectionIndex(this.source) {
    for (var sourceIndex = 0; sourceIndex < source.length; sourceIndex++) {
      _insert(source[sourceIndex], sourceIndex);
    }
  }

  List<InkStroke> source;
  final List<_IndexedValue<InkStroke>> entries = <_IndexedValue<InkStroke>>[];
  final Map<String, _IndexedValue<InkStroke>> byId =
      <String, _IndexedValue<InkStroke>>{};
  final _SelectionBoundsGrid spatial = _SelectionBoundsGrid();
  bool monotonicZ = true;

  List<int> query(Rect2 bounds) => spatial.query(bounds);

  void advanceToSingleAppend(List<InkStroke> next) {
    assert(next.length == source.length + 1);
    _insert(next.last, source.length);
    source = next;
  }

  void _insert(InkStroke stroke, int sourceIndex) {
    if (entries.isNotEmpty && stroke.zIndex < entries.last.value.zIndex) {
      monotonicZ = false;
    }
    final entry = _IndexedValue<InkStroke>(
      value: stroke,
      sourceIndex: sourceIndex,
      bounds: stroke.bounds,
    );
    entries.add(entry);
    byId[stroke.id] = entry;
    spatial.insert(sourceIndex, entry.bounds);
  }
}

final class _ContentGroupSelectionIndex {
  _ContentGroupSelectionIndex(this.source) {
    for (var index = 0; index < source.length; index++) {
      final group = source[index];
      byId[group.id] = group;
      spatial.insert(index, group.bounds);
      for (final memberId in group.memberIds) {
        (groupsByMember[memberId] ??= <int>[]).add(index);
      }
    }
  }

  final List<ContentGroup> source;
  final Map<String, ContentGroup> byId = <String, ContentGroup>{};
  final Map<String, List<int>> groupsByMember = <String, List<int>>{};
  final _SelectionBoundsGrid spatial = _SelectionBoundsGrid();

  List<int> query(Rect2 bounds) => spatial.query(bounds);
}

final class _InkGroupSelectionIndex {
  _InkGroupSelectionIndex(this.source) {
    for (var index = 0; index < source.length; index++) {
      final group = source[index];
      byId[group.id] = group;
      spatial.insert(index, group.bounds);
    }
  }

  final List<InkGroup> source;
  final Map<String, InkGroup> byId = <String, InkGroup>{};
  final _SelectionBoundsGrid spatial = _SelectionBoundsGrid();

  List<int> query(Rect2 bounds) => spatial.query(bounds);
}

/// Small identity LRU. Document snapshots are immutable, so list identity is
/// a complete invalidation token and avoids hashing thousands of items.
final class _IdentitySelectionCache<K extends Object, V> {
  _IdentitySelectionCache(this.create, {required this.maximumEntries})
    : assert(maximumEntries > 0);

  final V Function(K source) create;
  final int maximumEntries;
  final List<(K, V)> _recent = <(K, V)>[];

  int get entryCount => _recent.length;

  V resolve(K source) {
    for (var index = _recent.length - 1; index >= 0; index--) {
      final entry = _recent[index];
      if (!identical(entry.$1, source)) continue;
      if (index != _recent.length - 1) {
        _recent
          ..removeAt(index)
          ..add(entry);
      }
      return entry.$2;
    }
    final value = create(source);
    if (_recent.length >= maximumEntries) _recent.removeAt(0);
    _recent.add((source, value));
    return value;
  }

  void clear() => _recent.clear();
}

/// The active stroke list normally changes by exactly one persistent append.
/// Move the cached index to that new immutable snapshot and insert only the
/// final stroke. Undo or any non-append edit safely takes the full rebuild
/// fallback.
final class _StrokeSelectionIndexCache {
  _StrokeSelectionIndexCache(this.maximumEntries) : assert(maximumEntries > 0);

  final int maximumEntries;
  final List<_StrokeSelectionIndex> _recent = <_StrokeSelectionIndex>[];

  int get entryCount => _recent.length;

  _StrokeSelectionIndex resolve(
    List<InkStroke> source, {
    SelectionEngineDiagnostics? diagnostics,
  }) {
    for (var index = _recent.length - 1; index >= 0; index--) {
      final value = _recent[index];
      if (!identical(value.source, source)) continue;
      _touch(index, value);
      return value;
    }
    final appendSource = source is SingleAppendSceneList<InkStroke>
        ? source as SingleAppendSceneList<InkStroke>
        : null;
    if (appendSource != null) {
      for (var index = _recent.length - 1; index >= 0; index--) {
        final value = _recent[index];
        if (!appendSource.isSingleAppendOf(value.source)) continue;
        _recent.removeAt(index);
        value.advanceToSingleAppend(source);
        _recent.add(value);
        diagnostics?.strokeIncrementalIndexUpdates++;
        return value;
      }
    }
    final value = _StrokeSelectionIndex(source);
    diagnostics?.strokeFullIndexBuilds++;
    if (_recent.length >= maximumEntries) _recent.removeAt(0);
    _recent.add(value);
    return value;
  }

  void _touch(int index, _StrokeSelectionIndex value) {
    if (index == _recent.length - 1) return;
    _recent
      ..removeAt(index)
      ..add(value);
  }

  void clear() => _recent.clear();
}

final class _SceneOrdering {
  _SceneOrdering(this.objects, this.strokes);

  final _ObjectSelectionIndex objects;
  final _StrokeSelectionIndex strokes;
  Map<String, int>? _fallbackRanks;

  int objectRank(_IndexedValue<BoardObject> entry) {
    if (!objects.monotonicZ || !strokes.monotonicZ) {
      return _fallbackRank(entry.value.id);
    }
    return entry.sourceIndex + _lowerBoundStrokeZ(entry.value.zIndex);
  }

  int strokeRank(_IndexedValue<InkStroke> entry) {
    if (!objects.monotonicZ || !strokes.monotonicZ) {
      return _fallbackRank(entry.value.id);
    }
    return entry.sourceIndex + _upperBoundObjectZ(entry.value.zIndex);
  }

  int rankOfId(String id) {
    final object = objects.byId[id];
    if (object != null) return objectRank(object);
    final stroke = strokes.byId[id];
    return stroke == null ? -1 : strokeRank(stroke);
  }

  int _lowerBoundStrokeZ(int zIndex) {
    var low = 0;
    var high = strokes.entries.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (strokes.entries[middle].value.zIndex < zIndex) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  int _upperBoundObjectZ(int zIndex) {
    var low = 0;
    var high = objects.entries.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (objects.entries[middle].value.zIndex <= zIndex) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  int _fallbackRank(String id) {
    final ranks = _fallbackRanks ??= <String, int>{
      for (final (index, item) in orderedBoardSceneItems(
        objects: objects.source,
        strokes: strokes.source,
      ).indexed)
        item.id: index,
    };
    return ranks[id] ?? -1;
  }
}

/// Compact uniform grid for selection bounds. Very large items live in a
/// separate short list, preventing a poster-sized PDF from filling thousands
/// of cells. Huge rectangle/lasso queries deliberately fall back to one linear
/// bounds pass instead of enumerating an even larger empty grid.
final class _SelectionBoundsGrid {
  static const double cellSize = 192;
  static const int maximumCellsPerItem = 96;

  final List<Rect2?> _bounds = <Rect2?>[];
  final Map<(int, int), List<int>> _cells = <(int, int), List<int>>{};
  final List<int> _largeEntries = <int>[];

  void insert(int index, Rect2 bounds) {
    while (_bounds.length <= index) {
      _bounds.add(null);
    }
    if (!_validBounds(bounds)) return;
    _bounds[index] = bounds;
    final left = (bounds.left / cellSize).floor();
    final right = (bounds.right / cellSize).floor();
    final top = (bounds.top / cellSize).floor();
    final bottom = (bounds.bottom / cellSize).floor();
    final horizontalCells = right - left + 1;
    final verticalCells = bottom - top + 1;
    if (horizontalCells > maximumCellsPerItem ||
        verticalCells > maximumCellsPerItem ||
        horizontalCells * verticalCells > maximumCellsPerItem) {
      _largeEntries.add(index);
      return;
    }
    for (var x = left; x <= right; x++) {
      for (var y = top; y <= bottom; y++) {
        (_cells[(x, y)] ??= <int>[]).add(index);
      }
    }
  }

  List<int> query(Rect2 area) {
    if (!_validBounds(area) || _bounds.isEmpty) return <int>[];
    final left = (area.left / cellSize).floor();
    final right = (area.right / cellSize).floor();
    final top = (area.top / cellSize).floor();
    final bottom = (area.bottom / cellSize).floor();
    final horizontalCells = right - left + 1;
    final verticalCells = bottom - top + 1;
    if (horizontalCells > _bounds.length ||
        verticalCells > _bounds.length ||
        horizontalCells * verticalCells > math.max(32, _bounds.length * 2)) {
      return <int>[
        for (var index = 0; index < _bounds.length; index++)
          if (_bounds[index]?.intersects(area) ?? false) index,
      ];
    }
    final candidates = <int>{..._largeEntries};
    for (var x = left; x <= right; x++) {
      for (var y = top; y <= bottom; y++) {
        final values = _cells[(x, y)];
        if (values != null) candidates.addAll(values);
      }
    }
    candidates.removeWhere(
      (index) => !(_bounds[index]?.intersects(area) ?? false),
    );
    return candidates.toList(growable: false);
  }
}
