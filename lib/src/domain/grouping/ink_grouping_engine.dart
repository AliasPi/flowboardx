import 'dart:math' as math;

import '../model/document.dart';
import '../model/geometry.dart';
import '../model/ink.dart';

final class InkGroupingConfig {
  const InkGroupingConfig({
    this.spatialCellSize = 160,
    this.analysisMargin = 240,
    this.letterTemporalGap = const Duration(milliseconds: 1400),
    this.wordTemporalGap = const Duration(seconds: 4),
    this.lineTemporalGap = const Duration(seconds: 12),
    this.wordGapHeightFactor = 0.75,
    this.lineGapHeightFactor = 3.2,
    this.sketchWidthThreshold = 220,
    this.sketchHeightThreshold = 160,
    this.maxLocalStrokes = 256,
  });

  final double spatialCellSize;
  final double analysisMargin;
  final Duration letterTemporalGap;
  final Duration wordTemporalGap;
  final Duration lineTemporalGap;
  final double wordGapHeightFactor;
  final double lineGapHeightFactor;
  final double sketchWidthThreshold;
  final double sketchHeightThreshold;
  final int maxLocalStrokes;
}

final class InkGroupingResult {
  InkGroupingResult({
    required Iterable<InkGroup> groups,
    required this.affectedRegion,
  }) : groups = List.unmodifiable(groups);

  final List<InkGroup> groups;
  final Rect2 affectedRegion;
}

/// Maintains explainable letter/word/line/sketch group candidates. Only the
/// region around changed strokes is recomputed; manual groups are never replaced.
final class InkGroupingEngine {
  InkGroupingEngine({this.config = const InkGroupingConfig()});

  final InkGroupingConfig config;
  final Map<String, InkSpatialIndex> _indices = {};

  InkGroupingResult regroupAll(BoardPage page) {
    _indexFor(page);
    final region = _boundsOf(page.strokes) ?? const Rect2.zero();
    final manual = page.groups.where(
      (group) => group.kind == InkGroupKind.manual,
    );
    final automatic = _groupsFor(page.strokes);
    return InkGroupingResult(
      groups: _deduplicate([...manual, ...automatic]),
      affectedRegion: region,
    );
  }

  InkGroupingResult regroupIncrementally({
    required BoardPage page,
    required Iterable<String> changedStrokeIds,
    Rect2? dirtyRegion,
  }) {
    final changed = changedStrokeIds.toSet();
    final index = _indexFor(page);
    Rect2? affected = dirtyRegion;
    for (final id in changed) {
      final stroke = index.strokeById(id);
      if (stroke != null) {
        affected = affected == null
            ? stroke.bounds
            : affected.union(stroke.bounds);
      }
    }
    if (affected == null) return regroupAll(page);
    var expanded = affected.inflate(config.analysisMargin);

    // Include full existing groups touching the dirty region, then query the
    // spatial grid once more so boundary words/lines remain stable.
    for (final group in page.groups) {
      if (group.kind != InkGroupKind.manual &&
          group.bounds.intersects(expanded)) {
        expanded = expanded.union(
          group.bounds.inflate(config.analysisMargin / 2),
        );
      }
    }
    final localStrokes = index.query(expanded).toList();
    if (localStrokes.length > config.maxLocalStrokes) {
      final center = affected.center;
      localStrokes.sort((first, second) {
        final firstChanged = changed.contains(first.id) ? 0 : 1;
        final secondChanged = changed.contains(second.id) ? 0 : 1;
        if (firstChanged != secondChanged) {
          return firstChanged.compareTo(secondChanged);
        }
        return first.bounds.center
            .distanceTo(center)
            .compareTo(second.bounds.center.distanceTo(center));
      });
      localStrokes.removeRange(config.maxLocalStrokes, localStrokes.length);
    }
    final preserved = page.groups.where(
      (group) =>
          group.kind == InkGroupKind.manual ||
          !group.bounds.intersects(expanded),
    );
    return InkGroupingResult(
      groups: _deduplicate([...preserved, ..._groupsFor(localStrokes)]),
      affectedRegion: expanded,
    );
  }

  /// Returns the semantic choices under a tap, from most specific to broadest.
  List<InkGroup> selectionCandidatesAt(
    BoardPage page,
    Vec2 point, {
    double tolerance = 12,
  }) {
    const order = {
      InkGroupKind.letter: 0,
      InkGroupKind.word: 1,
      InkGroupKind.line: 2,
      InkGroupKind.sketch: 3,
      InkGroupKind.manual: 4,
    };
    final candidates =
        page.groups
            .where((group) => group.bounds.inflate(tolerance).contains(point))
            .toList()
          ..sort((a, b) {
            final kind = order[a.kind]!.compareTo(order[b.kind]!);
            if (kind != 0) return kind;
            return (a.bounds.width * a.bounds.height).compareTo(
              b.bounds.width * b.bounds.height,
            );
          });
    return candidates;
  }

  void invalidatePage(String pageId) => _indices.remove(pageId);

  InkSpatialIndex _indexFor(BoardPage page) {
    final index = _indices.putIfAbsent(
      page.id,
      () => InkSpatialIndex(cellSize: config.spatialCellSize),
    );
    index.synchronize(page.strokes);
    return index;
  }

  List<InkGroup> _groupsFor(Iterable<InkStroke> source) {
    final strokes =
        source
            .where((stroke) => !stroke.isEmpty && stroke.authorId != 'template')
            .toList()
          ..sort((a, b) {
            final time = _startMicros(a).compareTo(_startMicros(b));
            return time != 0 ? time : a.id.compareTo(b.id);
          });
    if (strokes.isEmpty) return const [];

    final glyphSets = _components(strokes, _sameGlyph);
    final glyphs = glyphSets
        .map((indices) => _StrokeCluster(indices.map((i) => strokes[i])))
        .toList();
    final groups = <InkGroup>[];
    final textGlyphs = <_StrokeCluster>[];
    for (final glyph in glyphs) {
      final kind = _looksLikeSketch(glyph)
          ? InkGroupKind.sketch
          : InkGroupKind.letter;
      groups.add(_group(kind, glyph.strokes));
      if (kind == InkGroupKind.letter) textGlyphs.add(glyph);
    }

    final wordSets = _clusterTokens(textGlyphs, _sameWord);
    final wordTokens = <_StrokeCluster>[];
    for (final indices in wordSets) {
      final cluster = _StrokeCluster(
        indices.expand((index) => textGlyphs[index].strokes),
      );
      wordTokens.add(cluster);
      if (indices.length > 1) {
        groups.add(_group(InkGroupKind.word, cluster.strokes));
      }
    }

    final lineSets = _clusterTokens(wordTokens, _sameLine);
    for (final indices in lineSets) {
      if (indices.length < 2) continue;
      final strokes = indices.expand((index) => wordTokens[index].strokes);
      groups.add(_group(InkGroupKind.line, strokes));
    }
    return groups;
  }

  List<List<int>> _components(
    List<InkStroke> strokes,
    bool Function(InkStroke, InkStroke) connected,
  ) {
    final union = _UnionFind(strokes.length);
    final localIndex = InkSpatialIndex(cellSize: config.spatialCellSize)
      ..synchronize(strokes);
    final positions = {
      for (var index = 0; index < strokes.length; index++)
        strokes[index].id: index,
    };
    for (var first = 0; first < strokes.length; first++) {
      for (final candidate in localIndex.query(
        strokes[first].bounds.inflate(50),
      )) {
        final second = positions[candidate.id]!;
        if (second > first && connected(strokes[first], candidate)) {
          union.join(first, second);
        }
      }
    }
    return union.groups();
  }

  List<List<int>> _clusterTokens(
    List<_StrokeCluster> tokens,
    bool Function(_StrokeCluster, _StrokeCluster) connected,
  ) {
    if (tokens.isEmpty) return const [];
    final union = _UnionFind(tokens.length);
    for (var first = 0; first < tokens.length; first++) {
      for (var second = first + 1; second < tokens.length; second++) {
        if (connected(tokens[first], tokens[second])) union.join(first, second);
      }
    }
    return union.groups();
  }

  bool _sameGlyph(InkStroke first, InkStroke second) {
    if (_timeGap(first, second) > config.letterTemporalGap) return false;
    final a = first.bounds;
    final b = second.bounds;
    if (a.inflate(7).intersects(b)) return true;
    final horizontalAlignment =
        (a.center.x - b.center.x).abs() <=
        math.max(a.width, b.width) * 0.65 + 6;
    final verticalGap = _axisGap(a.top, a.bottom, b.top, b.bottom);
    return horizontalAlignment &&
        verticalGap <= math.max(a.height, b.height) * 0.45 + 8;
  }

  bool _sameWord(_StrokeCluster first, _StrokeCluster second) {
    if (_clusterTimeGap(first, second) > config.wordTemporalGap) return false;
    final left = first.bounds.left <= second.bounds.left ? first : second;
    final right = identical(left, first) ? second : first;
    final height = math.max(8, (left.bounds.height + right.bounds.height) / 2);
    final gap = right.bounds.left - left.bounds.right;
    final verticallyAligned =
        _verticalOverlap(left.bounds, right.bounds) >= 0.25 ||
        (left.bounds.center.y - right.bounds.center.y).abs() <= height * 0.48;
    return verticallyAligned &&
        gap <= height * config.wordGapHeightFactor &&
        gap >= -height * 0.8;
  }

  bool _sameLine(_StrokeCluster first, _StrokeCluster second) {
    if (_clusterTimeGap(first, second) > config.lineTemporalGap) return false;
    final height = math.max(
      8,
      (first.bounds.height + second.bounds.height) / 2,
    );
    final sameBaseline =
        (first.bounds.bottom - second.bounds.bottom).abs() <= height * 0.65;
    final horizontalGap = _axisGap(
      first.bounds.left,
      first.bounds.right,
      second.bounds.left,
      second.bounds.right,
    );
    return sameBaseline && horizontalGap <= height * config.lineGapHeightFactor;
  }

  bool _looksLikeSketch(_StrokeCluster cluster) {
    final bounds = cluster.bounds;
    if (bounds.width >= config.sketchWidthThreshold ||
        bounds.height >= config.sketchHeightThreshold) {
      return true;
    }
    final area = bounds.width * bounds.height;
    return cluster.strokes.length >= 6 && area >= 13000;
  }

  InkGroup _group(InkGroupKind kind, Iterable<InkStroke> source) {
    final strokes = source.toList()..sort((a, b) => a.id.compareTo(b.id));
    return InkGroup(
      id: _stableGroupId(kind, strokes.map((stroke) => stroke.id)),
      kind: kind,
      strokeIds: strokes.map((stroke) => stroke.id),
      bounds: _boundsOf(strokes) ?? const Rect2.zero(),
      createdAt: strokes
          .map((stroke) => stroke.createdAt)
          .reduce((first, second) => first.isBefore(second) ? first : second),
    );
  }
}

final class InkSpatialIndex {
  InkSpatialIndex({this.cellSize = 160}) {
    if (!cellSize.isFinite || cellSize <= 0) {
      throw ArgumentError.value(
        cellSize,
        'cellSize',
        'muss positiv und endlich sein',
      );
    }
  }

  final double cellSize;
  final Map<String, InkStroke> _strokes = {};
  final Map<String, Set<_Cell>> _strokeCells = {};
  final Map<_Cell, Set<String>> _buckets = {};

  int get length => _strokes.length;
  InkStroke? strokeById(String id) => _strokes[id];

  void synchronize(Iterable<InkStroke> strokes) {
    final next = {for (final stroke in strokes) stroke.id: stroke};
    for (final id
        in _strokes.keys.where((id) => !next.containsKey(id)).toList()) {
      remove(id);
    }
    for (final stroke in next.values) {
      final old = _strokes[stroke.id];
      if (!identical(old, stroke) || old?.bounds != stroke.bounds) {
        upsert(stroke);
      }
    }
  }

  void upsert(InkStroke stroke) {
    remove(stroke.id);
    _strokes[stroke.id] = stroke;
    final cells = _cellsFor(stroke.bounds).toSet();
    _strokeCells[stroke.id] = cells;
    for (final cell in cells) {
      _buckets.putIfAbsent(cell, () => <String>{}).add(stroke.id);
    }
  }

  void remove(String strokeId) {
    final cells = _strokeCells.remove(strokeId);
    _strokes.remove(strokeId);
    if (cells == null) return;
    for (final cell in cells) {
      final bucket = _buckets[cell];
      bucket?.remove(strokeId);
      if (bucket != null && bucket.isEmpty) _buckets.remove(cell);
    }
  }

  Iterable<InkStroke> query(Rect2 region) sync* {
    final seen = <String>{};
    for (final cell in _cellsFor(region)) {
      for (final id in _buckets[cell] ?? const <String>{}) {
        if (seen.add(id)) {
          final stroke = _strokes[id];
          if (stroke != null && stroke.bounds.intersects(region)) yield stroke;
        }
      }
    }
  }

  Iterable<_Cell> _cellsFor(Rect2 bounds) sync* {
    final left = (bounds.left / cellSize).floor();
    final right = (bounds.right / cellSize).floor();
    final top = (bounds.top / cellSize).floor();
    final bottom = (bounds.bottom / cellSize).floor();
    for (var x = left; x <= right; x++) {
      for (var y = top; y <= bottom; y++) {
        yield _Cell(x, y);
      }
    }
  }
}

final class _StrokeCluster {
  _StrokeCluster(Iterable<InkStroke> source)
    : strokes = List.unmodifiable(source) {
    bounds = _boundsOf(strokes) ?? const Rect2.zero();
    startMicros = strokes.map(_startMicros).reduce(math.min);
    endMicros = strokes.map(_endMicros).reduce(math.max);
  }

  final List<InkStroke> strokes;
  late final Rect2 bounds;
  late final int startMicros;
  late final int endMicros;
}

final class _UnionFind {
  _UnionFind(int length)
    : _parent = List.generate(length, (index) => index),
      _rank = List.filled(length, 0);

  final List<int> _parent;
  final List<int> _rank;

  int find(int item) {
    if (_parent[item] != item) _parent[item] = find(_parent[item]);
    return _parent[item];
  }

  void join(int first, int second) {
    var rootA = find(first);
    var rootB = find(second);
    if (rootA == rootB) return;
    if (_rank[rootA] < _rank[rootB]) {
      final swap = rootA;
      rootA = rootB;
      rootB = swap;
    }
    _parent[rootB] = rootA;
    if (_rank[rootA] == _rank[rootB]) _rank[rootA]++;
  }

  List<List<int>> groups() {
    final result = <int, List<int>>{};
    for (var index = 0; index < _parent.length; index++) {
      result.putIfAbsent(find(index), () => []).add(index);
    }
    return result.values.toList(growable: false);
  }
}

final class _Cell {
  const _Cell(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is _Cell && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

Rect2? _boundsOf(Iterable<InkStroke> strokes) {
  Rect2? bounds;
  for (final stroke in strokes) {
    bounds = bounds == null ? stroke.bounds : bounds.union(stroke.bounds);
  }
  return bounds;
}

int _startMicros(InkStroke stroke) => stroke.firstTimestampMicros > 0
    ? stroke.firstTimestampMicros
    : stroke.createdAt.microsecondsSinceEpoch;

int _endMicros(InkStroke stroke) => stroke.lastTimestampMicros > 0
    ? stroke.lastTimestampMicros
    : stroke.createdAt.microsecondsSinceEpoch;

Duration _timeGap(InkStroke first, InkStroke second) {
  final gap =
      math.max(_startMicros(first), _startMicros(second)) -
      math.min(_endMicros(first), _endMicros(second));
  return Duration(microseconds: math.max(0, gap).toInt());
}

Duration _clusterTimeGap(_StrokeCluster first, _StrokeCluster second) {
  final gap =
      math.max(first.startMicros, second.startMicros) -
      math.min(first.endMicros, second.endMicros);
  return Duration(microseconds: math.max(0, gap).toInt());
}

double _axisGap(double aStart, double aEnd, double bStart, double bEnd) =>
    math.max(0, math.max(aStart, bStart) - math.min(aEnd, bEnd));

double _verticalOverlap(Rect2 first, Rect2 second) {
  final overlap = math.max(
    0,
    math.min(first.bottom, second.bottom) - math.max(first.top, second.top),
  );
  final denominator = math.max(1, math.min(first.height, second.height));
  return overlap / denominator;
}

String _stableGroupId(InkGroupKind kind, Iterable<String> strokeIds) {
  // 32-bit FNV-1a stays deterministic on both native Dart and JavaScript.
  var hash = 0x811C9DC5;
  for (final unit in '${kind.name}:${strokeIds.join(',')}'.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return 'auto_${kind.name}_${hash.toRadixString(16).padLeft(8, '0')}';
}

List<InkGroup> _deduplicate(Iterable<InkGroup> groups) {
  final byId = <String, InkGroup>{};
  for (final group in groups) {
    byId[group.id] = group;
  }
  final result = byId.values.toList()
    ..sort((a, b) {
      final kind = a.kind.index.compareTo(b.kind.index);
      return kind != 0 ? kind : a.id.compareTo(b.id);
    });
  return result;
}
