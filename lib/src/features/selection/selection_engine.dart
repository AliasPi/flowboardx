import 'dart:math' as math;

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

class SelectionEngine {
  const SelectionEngine();

  List<SelectionCandidate> candidatesAt(
    BoardPage page,
    Vec2 point, {
    double tolerance = 12,
  }) {
    final result = <SelectionCandidate>[];
    final memberGroup = <String, ContentGroup>{
      for (final group in page.contentGroups)
        for (final memberId in group.memberIds) memberId: group,
    };
    final scene = orderedBoardSceneItems(
      objects: page.objects,
      strokes: page.strokes,
    );
    final sceneRank = <String, int>{
      for (var index = 0; index < scene.length; index++) scene[index].id: index,
    };
    for (var index = scene.length - 1; index >= 0; index--) {
      final item = scene[index];
      final object = item.object;
      if (object != null) {
        if (memberGroup.containsKey(object.id)) continue;
        if (!object.locked &&
            object.transform.containsWorld(point, tolerance: tolerance)) {
          result.add(
            SelectionCandidate(
              id: object.id,
              itemIds: [object.id],
              bounds: object.transform.bounds,
              type: SelectionCandidateType.object,
              score: 10000 + index.toDouble(),
            ),
          );
        }
        continue;
      }
      final stroke = item.stroke!;
      if (memberGroup.containsKey(stroke.id)) continue;
      if (!stroke.bounds.inflate(tolerance).contains(point)) continue;
      if (_distanceToStroke(point, stroke) <= tolerance + stroke.width / 2) {
        result.add(
          SelectionCandidate(
            id: stroke.id,
            itemIds: [stroke.id],
            bounds: stroke.bounds,
            type: SelectionCandidateType.stroke,
            score: 10000 + index.toDouble(),
          ),
        );
      }
    }

    for (final group in page.contentGroups.reversed) {
      if (group.locked || !group.bounds.inflate(tolerance).contains(point)) {
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
                    (rank, id) => math.max(rank, sceneRank[id] ?? -1),
                  ) /
                  1000,
        ),
      );
    }

    for (final group in page.groups) {
      if (group.strokeIds.any(memberGroup.containsKey)) continue;
      if (!group.bounds.inflate(tolerance).contains(point)) continue;
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
                    (rank, id) => math.max(rank, sceneRank[id] ?? -1),
                  ) /
                  1000,
        ),
      );
    }
    result.sort((a, b) => b.score.compareTo(a.score));
    return result;
  }

  Set<String> itemsInRectangle(BoardPage page, Rect2 selection) {
    final selected = <String>{};
    for (final object in page.objects) {
      if (!object.locked && selection.intersects(object.transform.bounds)) {
        selected.add(object.id);
      }
    }
    for (final stroke in page.strokes) {
      if (selection.intersects(stroke.bounds)) selected.add(stroke.id);
    }
    return _respectContentGroups(page, selected);
  }

  Set<String> itemsInLasso(BoardPage page, List<Vec2> polygon) {
    if (polygon.length < 3) return const <String>{};
    final boundedPolygon = simplifyLasso(polygon);
    final polygonBounds = Rect2.fromPoints(boundedPolygon);
    final selected = <String>{};
    for (final object in page.objects) {
      if (!object.locked &&
          object.transform.bounds.intersects(polygonBounds) &&
          _insidePolygon(object.transform.bounds.center, boundedPolygon)) {
        selected.add(object.id);
      }
    }
    for (final stroke in page.strokes) {
      if (stroke.bounds.intersects(polygonBounds) &&
          _insidePolygon(stroke.bounds.center, boundedPolygon)) {
        selected.add(stroke.id);
      }
    }
    return _respectContentGroups(page, selected);
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
  Set<String> allItems(BoardPage page) => _respectContentGroups(page, {
    ...page.objects.map((object) => object.id),
    ...page.strokes.map((stroke) => stroke.id),
  });

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

  static double _distanceToStroke(Vec2 point, InkStroke stroke) {
    if (stroke.points.isEmpty) return double.infinity;
    if (stroke.points.length == 1) {
      return point.distanceTo(stroke.points.first.position);
    }
    var minimum = double.infinity;
    for (var i = 1; i < stroke.points.length; i++) {
      minimum = math.min(
        minimum,
        _distanceToSegment(
          point,
          stroke.points[i - 1].position,
          stroke.points[i].position,
        ),
      );
    }
    return minimum;
  }

  static double _distanceToSegment(Vec2 p, Vec2 a, Vec2 b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared == 0) return p.distanceTo(a);
    final t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared).clamp(
      0.0,
      1.0,
    );
    return p.distanceTo(Vec2(a.x + t * dx, a.y + t * dy));
  }

  static bool _insidePolygon(Vec2 point, List<Vec2> polygon) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final a = polygon[i];
      final b = polygon[j];
      final crosses =
          (a.y > point.y) != (b.y > point.y) &&
          point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x;
      if (crosses) inside = !inside;
    }
    return inside;
  }

  static Set<String> _respectContentGroups(
    BoardPage page,
    Set<String> selected,
  ) {
    if (selected.isEmpty || page.contentGroups.isEmpty) return selected;
    final result = selected.toSet();
    for (final group in page.contentGroups) {
      if (!group.memberIds.any(selected.contains)) continue;
      result
        ..removeAll(group.memberIds)
        ..add(group.id);
    }
    return result;
  }
}
