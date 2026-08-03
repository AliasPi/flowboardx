import 'dart:collection';
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
    this.maxCachedPages = 6,
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
  final int maxCachedPages;
}

final class InkGroupingResult {
  InkGroupingResult({
    required Iterable<InkGroup> groups,
    required this.affectedRegion,
  }) : groups = ImmutableModelList(groups);

  final List<InkGroup> groups;
  final Rect2 affectedRegion;
}

/// Maintains explainable letter/word/line/sketch group candidates. Only the
/// region around changed strokes is recomputed; manual groups are never replaced.
final class InkGroupingEngine {
  InkGroupingEngine({this.config = const InkGroupingConfig()});

  final InkGroupingConfig config;
  final Map<String, _PageInkIndex> _indices = {};
  int _glyphPairComparisonCount = 0;
  int _tokenPairComparisonCount = 0;

  int get cachedPageCount => _indices.length;
  int get debugGlyphPairComparisonCount => _glyphPairComparisonCount;
  int get debugTokenPairComparisonCount => _tokenPairComparisonCount;
  int get debugGroupIndexRebuildCount =>
      _indices.values.fold(0, (sum, state) => sum + state.groups.rebuildCount);
  int get debugLastGroupCandidateCount => _indices.values.fold(
    0,
    (sum, state) => sum + state.groups.lastQueryCount,
  );

  InkGroupingResult regroupAll(BoardPage page) {
    final state = _stateFor(page);
    final region = _boundsOf(page.strokes) ?? const Rect2.zero();
    final manual = page.groups.where(
      (group) => group.kind == InkGroupKind.manual,
    );
    final automatic = _groupsFor(page.strokes);
    final groups = state.groups.replaceAll([...manual, ...automatic]);
    return InkGroupingResult(groups: groups, affectedRegion: region);
  }

  InkGroupingResult regroupIncrementally({
    required BoardPage page,
    required Iterable<String> changedStrokeIds,
    Rect2? dirtyRegion,
    BoardPage? pageBeforeAppend,
    InkStroke? appendedStroke,
  }) {
    final changed = changedStrokeIds.toSet();
    final state = _stateFor(
      page,
      pageBeforeAppend: pageBeforeAppend,
      appendedStroke: appendedStroke,
    );
    final index = state.index;
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

    // Query only groups whose indexed bounds touch the local edit. Two bounded
    // expansion passes retain boundary words/lines without rescanning the
    // complete, ever-growing group list after every pen-up.
    var affectedAutomaticGroups = <InkGroup>[];
    for (var pass = 0; pass < 2; pass++) {
      final candidates = state.groups.query(expanded);
      affectedAutomaticGroups = candidates
          .where(
            (group) =>
                group.kind != InkGroupKind.manual &&
                group.bounds.intersects(expanded),
          )
          .toList(growable: false);
      var nextExpanded = expanded;
      for (final group in affectedAutomaticGroups) {
        nextExpanded = nextExpanded.union(
          group.bounds.inflate(config.analysisMargin / 2),
        );
      }
      if (nextExpanded == expanded) break;
      expanded = nextExpanded;
    }
    // A dense sketch can contain thousands of strokes in one dirty region.
    // Never materialize and sort that complete candidate set on the UI
    // isolate. The fixed-size heap below retains changed strokes first and
    // otherwise only the nearest candidates needed by the local heuristic.
    final localStrokes = index.queryNearest(
      expanded,
      center: affected.center,
      limit: math.max(1, config.maxLocalStrokes),
      priorityStrokeIds: changed,
    );
    // Only replace groups observed before the final expansion. Their complete
    // bounds are guaranteed to lie inside `expanded`; a newly touched group at
    // its outer edge remains intact instead of being partially recomputed.
    final groups = state.groups.replaceRegion(
      affectedAutomaticGroups,
      _groupsFor(localStrokes),
    );
    return InkGroupingResult(groups: groups, affectedRegion: expanded);
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
    final searchRadius = math.max(0.0, tolerance);
    final candidates =
        _stateFor(page).groups
            .query(
              Rect2(
                left: point.x - searchRadius,
                top: point.y - searchRadius,
                width: searchRadius * 2,
                height: searchRadius * 2,
              ),
            )
            .where(
              (group) => group.bounds.inflate(searchRadius).contains(point),
            )
            .toList()
          ..sort((a, b) {
            final kind = order[a.kind]!.compareTo(order[b.kind]!);
            if (kind != 0) return kind;
            final area = (a.bounds.width * a.bounds.height).compareTo(
              b.bounds.width * b.bounds.height,
            );
            return area != 0 ? area : a.id.compareTo(b.id);
          });
    return candidates;
  }

  void invalidatePage(String pageId) => _indices.remove(pageId);

  _PageInkIndex _stateFor(
    BoardPage page, {
    BoardPage? pageBeforeAppend,
    InkStroke? appendedStroke,
  }) {
    final existing = _indices.remove(page.id);
    if (existing == null) {
      final index = InkSpatialIndex(cellSize: config.spatialCellSize)
        ..synchronize(page.strokes);
      while (_indices.length >= math.max(1, config.maxCachedPages)) {
        _indices.remove(_indices.keys.first);
      }
      final state = _PageInkIndex(
        index,
        page.strokes,
        _PageGroupIndex(page.groups, cellSize: config.spatialCellSize),
      );
      _indices[page.id] = state;
      return state;
    }
    // Dart maps retain insertion order. Reinsert a hit to maintain a compact
    // LRU of recently edited pages instead of retaining duplicate spatial maps
    // for every page visited in a 100-page document.
    _indices[page.id] = existing;
    existing.groups.synchronize(page.groups);
    if (identical(existing.strokes, page.strokes)) return existing;

    // The overwhelmingly common writing path appends exactly one immutable
    // stroke. Keep the existing grid and index only that stroke. Any undo,
    // transform or concurrent participant edit falls through to the complete
    // synchronization below.
    if (pageBeforeAppend != null &&
        appendedStroke != null &&
        identical(existing.strokes, pageBeforeAppend.strokes) &&
        page.strokes.length == pageBeforeAppend.strokes.length + 1 &&
        identical(page.strokes.last, appendedStroke)) {
      existing.index.upsert(appendedStroke);
      existing.strokes = page.strokes;
      return existing;
    }

    existing.index.synchronize(page.strokes);
    existing.strokes = page.strokes;
    return existing;
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

    final glyphSets = _components(
      strokes,
      _sameGlyph,
      maximumGap: config.letterTemporalGap,
    );
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

    final wordSets = _clusterTokens(
      textGlyphs,
      _sameWord,
      maximumGap: config.wordTemporalGap,
    );
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

    final lineSets = _clusterTokens(
      wordTokens,
      _sameLine,
      maximumGap: config.lineTemporalGap,
    );
    for (final indices in lineSets) {
      if (indices.length < 2) continue;
      final strokes = indices.expand((index) => wordTokens[index].strokes);
      groups.add(_group(InkGroupKind.line, strokes));
    }
    return groups;
  }

  List<List<int>> _components(
    List<InkStroke> strokes,
    bool Function(InkStroke, InkStroke) connected, {
    required Duration maximumGap,
  }) {
    final union = _UnionFind(strokes.length);
    final maximumGapMicros = math.max(0, maximumGap.inMicroseconds);
    // `strokes` is ordered by start time. A later stroke beyond this temporal
    // window cannot form the same glyph, so stop before doing spatial work.
    // This also avoids constructing a second point-level spatial index for the
    // same local strokes after the page index already selected them.
    for (var first = 0; first < strokes.length; first++) {
      final firstStroke = strokes[first];
      final firstEnd = _endMicros(firstStroke);
      for (var second = first + 1; second < strokes.length; second++) {
        final candidate = strokes[second];
        if (_startMicros(candidate) - firstEnd > maximumGapMicros) break;
        _glyphPairComparisonCount++;
        if (connected(firstStroke, candidate)) {
          union.join(first, second);
        }
      }
    }
    return union.groups();
  }

  List<List<int>> _clusterTokens(
    List<_StrokeCluster> tokens,
    bool Function(_StrokeCluster, _StrokeCluster) connected, {
    required Duration maximumGap,
  }) {
    if (tokens.isEmpty) return const [];
    final union = _UnionFind(tokens.length);
    final orderedIndices = List<int>.generate(tokens.length, (index) => index)
      ..sort((first, second) {
        final time = tokens[first].startMicros.compareTo(
          tokens[second].startMicros,
        );
        return time != 0 ? time : first.compareTo(second);
      });
    final maximumGapMicros = math.max(0, maximumGap.inMicroseconds);
    for (var firstOrder = 0; firstOrder < orderedIndices.length; firstOrder++) {
      final firstIndex = orderedIndices[firstOrder];
      final first = tokens[firstIndex];
      for (
        var secondOrder = firstOrder + 1;
        secondOrder < orderedIndices.length;
        secondOrder++
      ) {
        final secondIndex = orderedIndices[secondOrder];
        final second = tokens[secondIndex];
        if (second.startMicros - first.endMicros > maximumGapMicros) break;
        _tokenPairComparisonCount++;
        if (connected(first, second)) union.join(firstIndex, secondIndex);
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

final class _PageInkIndex {
  _PageInkIndex(this.index, this.strokes, this.groups);

  final InkSpatialIndex index;
  List<InkStroke> strokes;
  final _PageGroupIndex groups;
}

/// Cached per-page grouping state. The spatial grid finds the handful of
/// candidates affected by a pen-up, while the persistent AVL sequence changes
/// only O(log G) nodes for every removed/inserted group. Older Undo snapshots
/// retain their immutable roots without retaining a copied G-element array.
final class _PageGroupIndex {
  _PageGroupIndex(List<InkGroup> groups, {required double cellSize})
    : _spatial = _GroupSpatialIndex(cellSize: cellSize) {
    synchronize(groups);
  }

  final _GroupSpatialIndex _spatial;
  final Map<String, InkGroup> _byId = <String, InkGroup>{};
  late _PersistentInkGroupList _tree;
  List<InkGroup>? _source;
  int rebuildCount = 0;
  int lastQueryCount = 0;

  void synchronize(List<InkGroup> groups) {
    if (identical(_source, groups)) return;
    _tree = _PersistentInkGroupList.canonical(groups);
    _byId
      ..clear()
      ..addEntries(_tree.map((group) => MapEntry(group.id, group)));
    _spatial.synchronize(_tree);
    _source = groups;
    rebuildCount++;
  }

  List<InkGroup> query(Rect2 region) {
    final result = _spatial.query(region).toList(growable: false);
    lastQueryCount = result.length;
    return result;
  }

  ImmutableModelList<InkGroup> replaceAll(Iterable<InkGroup> groups) {
    _tree = _PersistentInkGroupList.canonical(groups);
    _byId
      ..clear()
      ..addEntries(_tree.map((group) => MapEntry(group.id, group)));
    _spatial.synchronize(_tree);
    final result = ImmutableModelList<InkGroup>(_tree);
    _source = result;
    return result;
  }

  ImmutableModelList<InkGroup> replaceRegion(
    Iterable<InkGroup> removedGroups,
    Iterable<InkGroup> replacements,
  ) {
    var root = _tree.root;
    final removedIds = <String>{};
    for (final removed in removedGroups) {
      if (!removedIds.add(removed.id)) continue;
      final current = _byId.remove(removed.id);
      if (current == null) continue;
      root = _removeGroupNode(root, current);
      _spatial.remove(current.id);
    }

    // `_deduplicate` provides the exact historic last-ID-wins behavior and
    // canonical order for the bounded replacement set.
    for (final replacement in _deduplicate(replacements)) {
      final collision = _byId.remove(replacement.id);
      if (collision != null) {
        root = _removeGroupNode(root, collision);
        _spatial.remove(collision.id);
      }
      root = _insertGroupNode(root, replacement);
      _byId[replacement.id] = replacement;
      _spatial.upsert(replacement);
    }

    _tree = _PersistentInkGroupList._(root);
    final result = ImmutableModelList<InkGroup>(_tree);
    _source = result;
    return result;
  }
}

/// Canonically ordered persistent list backed by an AVL tree with subtree
/// sizes. Index access is O(log G), iteration is O(G), and local group changes
/// share every unaffected branch with the preceding document snapshot.
final class _PersistentInkGroupList extends ListBase<InkGroup>
    implements ImmutableModelListSource<InkGroup> {
  const _PersistentInkGroupList._(this.root);

  factory _PersistentInkGroupList.canonical(Iterable<InkGroup> groups) {
    final values = _deduplicate(groups);
    return _PersistentInkGroupList._(
      _balancedGroupTree(values, 0, values.length),
    );
  }

  final _GroupNode? root;

  @override
  int get length => root?.size ?? 0;

  @override
  set length(int value) {
    throw UnsupportedError('Gruppenliste ist unveränderlich.');
  }

  @override
  InkGroup operator [](int index) {
    RangeError.checkValidIndex(index, this);
    var node = root!;
    var remaining = index;
    while (true) {
      final leftSize = node.left?.size ?? 0;
      if (remaining < leftSize) {
        node = node.left!;
      } else if (remaining == leftSize) {
        return node.value;
      } else {
        remaining -= leftSize + 1;
        node = node.right!;
      }
    }
  }

  @override
  void operator []=(int index, InkGroup value) {
    throw UnsupportedError('Gruppenliste ist unveränderlich.');
  }

  @override
  Iterator<InkGroup> get iterator => _GroupTreeIterator(root);

  @override
  Iterable<InkGroup> get reversed => _ReverseGroupTreeIterable(root);
}

final class _GroupTreeIterator implements Iterator<InkGroup> {
  _GroupTreeIterator(_GroupNode? root, {this.reverse = false}) {
    _pushEdge(root);
  }

  final bool reverse;
  final List<_GroupNode> _stack = <_GroupNode>[];
  InkGroup? _current;

  void _pushEdge(_GroupNode? node) {
    while (node != null) {
      _stack.add(node);
      node = reverse ? node.right : node.left;
    }
  }

  @override
  InkGroup get current => _current as InkGroup;

  @override
  bool moveNext() {
    if (_stack.isEmpty) {
      _current = null;
      return false;
    }
    final node = _stack.removeLast();
    _current = node.value;
    _pushEdge(reverse ? node.left : node.right);
    return true;
  }
}

final class _ReverseGroupTreeIterable extends Iterable<InkGroup> {
  const _ReverseGroupTreeIterable(this.root);

  final _GroupNode? root;

  @override
  Iterator<InkGroup> get iterator => _GroupTreeIterator(root, reverse: true);
}

final class _GroupNode {
  _GroupNode(this.value, this.left, this.right)
    : height =
          1 +
          (_groupNodeHeight(left) > _groupNodeHeight(right)
              ? _groupNodeHeight(left)
              : _groupNodeHeight(right)),
      size = 1 + _groupNodeSize(left) + _groupNodeSize(right);

  final InkGroup value;
  final _GroupNode? left;
  final _GroupNode? right;
  final int height;
  final int size;
}

int _groupNodeHeight(_GroupNode? node) => node?.height ?? 0;
int _groupNodeSize(_GroupNode? node) => node?.size ?? 0;

_GroupNode? _balancedGroupTree(List<InkGroup> values, int start, int end) {
  if (start >= end) return null;
  final middle = start + ((end - start) >> 1);
  return _GroupNode(
    values[middle],
    _balancedGroupTree(values, start, middle),
    _balancedGroupTree(values, middle + 1, end),
  );
}

_GroupNode _insertGroupNode(_GroupNode? node, InkGroup value) {
  if (node == null) return _GroupNode(value, null, null);
  final order = _compareGroups(value, node.value);
  if (order == 0) return _GroupNode(value, node.left, node.right);
  if (order < 0) {
    return _balanceGroupNode(
      _GroupNode(node.value, _insertGroupNode(node.left, value), node.right),
    );
  }
  return _balanceGroupNode(
    _GroupNode(node.value, node.left, _insertGroupNode(node.right, value)),
  );
}

_GroupNode? _removeGroupNode(_GroupNode? node, InkGroup value) {
  if (node == null) return null;
  final order = _compareGroups(value, node.value);
  if (order < 0) {
    final nextLeft = _removeGroupNode(node.left, value);
    if (identical(nextLeft, node.left)) return node;
    return _balanceGroupNode(_GroupNode(node.value, nextLeft, node.right));
  }
  if (order > 0) {
    final nextRight = _removeGroupNode(node.right, value);
    if (identical(nextRight, node.right)) return node;
    return _balanceGroupNode(_GroupNode(node.value, node.left, nextRight));
  }
  if (node.left == null) return node.right;
  if (node.right == null) return node.left;
  final successor = _firstGroupNode(node.right!);
  return _balanceGroupNode(
    _GroupNode(
      successor.value,
      node.left,
      _removeGroupNode(node.right, successor.value),
    ),
  );
}

_GroupNode _firstGroupNode(_GroupNode node) {
  var current = node;
  while (current.left != null) {
    current = current.left!;
  }
  return current;
}

_GroupNode _balanceGroupNode(_GroupNode node) {
  final balance = _groupNodeHeight(node.left) - _groupNodeHeight(node.right);
  if (balance > 1) {
    final left = node.left!;
    if (_groupNodeHeight(left.left) < _groupNodeHeight(left.right)) {
      return _rotateGroupRight(
        _GroupNode(node.value, _rotateGroupLeft(left), node.right),
      );
    }
    return _rotateGroupRight(node);
  }
  if (balance < -1) {
    final right = node.right!;
    if (_groupNodeHeight(right.right) < _groupNodeHeight(right.left)) {
      return _rotateGroupLeft(
        _GroupNode(node.value, node.left, _rotateGroupRight(right)),
      );
    }
    return _rotateGroupLeft(node);
  }
  return node;
}

_GroupNode _rotateGroupLeft(_GroupNode node) {
  final pivot = node.right!;
  return _GroupNode(
    pivot.value,
    _GroupNode(node.value, node.left, pivot.left),
    pivot.right,
  );
}

_GroupNode _rotateGroupRight(_GroupNode node) {
  final pivot = node.left!;
  return _GroupNode(
    pivot.value,
    pivot.left,
    _GroupNode(node.value, pivot.right, node.right),
  );
}

final class _GroupSpatialIndex {
  _GroupSpatialIndex({required this.cellSize}) {
    if (!cellSize.isFinite || cellSize <= 0) {
      throw ArgumentError.value(
        cellSize,
        'cellSize',
        'muss positiv und endlich sein',
      );
    }
  }

  static const int _maximumCellsPerGroup = 512;
  static const int _maximumCellsPerQuery = 4096;

  final double cellSize;
  final Map<String, InkGroup> _groups = <String, InkGroup>{};
  final Map<String, Set<_Cell>> _groupCells = <String, Set<_Cell>>{};
  final Map<_Cell, Set<String>> _buckets = <_Cell, Set<String>>{};
  final Set<String> _largeGroups = <String>{};

  void synchronize(Iterable<InkGroup> groups) {
    final next = <String, InkGroup>{
      for (final group in groups) group.id: group,
    };
    for (final id
        in _groups.keys.where((id) => !next.containsKey(id)).toList()) {
      remove(id);
    }
    for (final group in next.values) {
      final current = _groups[group.id];
      if (!identical(current, group) || current?.bounds != group.bounds) {
        upsert(group);
      }
    }
  }

  void upsert(InkGroup group) {
    remove(group.id);
    _groups[group.id] = group;
    final range = _cellRange(group.bounds);
    if (range == null || range.cellCount > _maximumCellsPerGroup) {
      _largeGroups.add(group.id);
      return;
    }
    final cells = range.cells.toSet();
    _groupCells[group.id] = cells;
    for (final cell in cells) {
      _buckets.putIfAbsent(cell, () => <String>{}).add(group.id);
    }
  }

  void remove(String groupId) {
    final cells = _groupCells.remove(groupId);
    _largeGroups.remove(groupId);
    _groups.remove(groupId);
    if (cells == null) return;
    for (final cell in cells) {
      final bucket = _buckets[cell];
      bucket?.remove(groupId);
      if (bucket != null && bucket.isEmpty) _buckets.remove(cell);
    }
  }

  Iterable<InkGroup> query(Rect2 region) sync* {
    final range = _cellRange(region);
    if (range == null || range.cellCount > _maximumCellsPerQuery) {
      for (final group in _groups.values) {
        if (group.bounds.intersects(region)) yield group;
      }
      return;
    }
    final seen = <String>{};
    for (final cell in range.cells) {
      for (final id in _buckets[cell] ?? const <String>{}) {
        if (!seen.add(id)) continue;
        final group = _groups[id];
        if (group != null && group.bounds.intersects(region)) yield group;
      }
    }
    for (final id in _largeGroups) {
      if (!seen.add(id)) continue;
      final group = _groups[id];
      if (group != null && group.bounds.intersects(region)) yield group;
    }
  }

  _CellRange? _cellRange(Rect2 bounds) {
    if (!bounds.left.isFinite ||
        !bounds.top.isFinite ||
        !bounds.right.isFinite ||
        !bounds.bottom.isFinite) {
      return null;
    }
    final left = (bounds.left / cellSize).floor();
    final right = (bounds.right / cellSize).floor();
    final top = (bounds.top / cellSize).floor();
    final bottom = (bounds.bottom / cellSize).floor();
    if (right < left || bottom < top) return null;
    return _CellRange(left, right, top, bottom);
  }
}

final class _CellRange {
  const _CellRange(this.left, this.right, this.top, this.bottom);

  final int left;
  final int right;
  final int top;
  final int bottom;

  int get cellCount => (right - left + 1) * (bottom - top + 1);

  Iterable<_Cell> get cells sync* {
    for (var x = left; x <= right; x++) {
      for (var y = top; y <= bottom; y++) {
        yield _Cell(x, y);
      }
    }
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
    // Index the polyline band, not every cell inside its bounding rectangle.
    // A large circle therefore occupies its perimeter instead of turning its
    // complete interior into false-positive grouping candidates.
    final cells = _cellsForStroke(stroke);
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

  /// Returns at most [limit] candidates, ordered by changed-stroke priority,
  /// distance to [center], and finally id for deterministic grouping.
  ///
  /// The bounded max-heap keeps the retained candidate set and final sort
  /// independent of the number of strokes in a densely occupied query region.
  List<InkStroke> queryNearest(
    Rect2 region, {
    required Vec2 center,
    required int limit,
    Set<String> priorityStrokeIds = const <String>{},
  }) {
    if (limit <= 0) return const <InkStroke>[];
    final heap = _BoundedStrokeCandidateHeap(limit);
    for (final stroke in query(region)) {
      final candidateCenter = stroke.bounds.center;
      final dx = candidateCenter.x - center.x;
      final dy = candidateCenter.y - center.y;
      final distanceSquared = dx * dx + dy * dy;
      heap.add(
        _StrokeCandidate(
          stroke,
          priority: priorityStrokeIds.contains(stroke.id) ? 0 : 1,
          distanceSquared: distanceSquared.isFinite
              ? distanceSquared
              : double.infinity,
        ),
      );
    }
    return heap.takeSorted();
  }

  Set<_Cell> _cellsForStroke(InkStroke stroke) {
    final centerline = <_Cell>{};
    InkPoint? previous;
    for (final point in stroke.points) {
      if (!point.x.isFinite || !point.y.isFinite) continue;
      final prior = previous;
      if (prior == null) {
        centerline.add(_cellAt(point.x, point.y));
      } else {
        centerline.addAll(
          _cellsAlongSegment(prior.x, prior.y, point.x, point.y),
        );
      }
      previous = point;
    }
    if (centerline.isEmpty) return <_Cell>{};

    // Match the renderer's defensive width ceiling. Expanding whole cells is
    // conservative at grid boundaries while still retaining a narrow band
    // around the actual path.
    final safeWidth = stroke.width.isFinite
        ? stroke.width.clamp(0.0, 512.0)
        : 0.0;
    final padding = (safeWidth / 2 / cellSize).ceil();
    if (padding <= 0) return centerline;
    return <_Cell>{
      for (final cell in centerline)
        for (var dx = -padding; dx <= padding; dx++)
          for (var dy = -padding; dy <= padding; dy++)
            _Cell(cell.x + dx, cell.y + dy),
    };
  }

  _Cell _cellAt(double x, double y) =>
      _Cell((x / cellSize).floor(), (y / cellSize).floor());

  /// Amanatides-Woo traversal with super-cover corner handling. It visits
  /// cells proportional to segment length, never to the segment's AABB area.
  Iterable<_Cell> _cellsAlongSegment(
    double startX,
    double startY,
    double endX,
    double endY,
  ) sync* {
    var current = _cellAt(startX, startY);
    final target = _cellAt(endX, endY);
    yield current;
    if (current == target) return;

    final dx = endX - startX;
    final dy = endY - startY;
    final stepX = dx > 0
        ? 1
        : dx < 0
        ? -1
        : 0;
    final stepY = dy > 0
        ? 1
        : dy < 0
        ? -1
        : 0;
    final tDeltaX = stepX == 0 ? double.infinity : cellSize / dx.abs();
    final tDeltaY = stepY == 0 ? double.infinity : cellSize / dy.abs();
    var tMaxX = stepX == 0
        ? double.infinity
        : ((stepX > 0 ? (current.x + 1) * cellSize : current.x * cellSize) -
                  startX) /
              dx;
    var tMaxY = stepY == 0
        ? double.infinity
        : ((stepY > 0 ? (current.y + 1) * cellSize : current.y * cellSize) -
                  startY) /
              dy;

    // A segment cannot cross more grid boundaries than this. The guard keeps
    // floating-point corner noise from stepping beyond the target cell.
    final maximumSteps =
        (target.x - current.x).abs() + (target.y - current.y).abs() + 2;
    var steps = 0;
    while (current != target && steps++ < maximumSteps) {
      if ((tMaxX - tMaxY).abs() <= 1e-12) {
        // At a grid corner the mathematical line touches both side cells.
        // Including them makes queries stable on either side of the boundary.
        if (stepX != 0) yield _Cell(current.x + stepX, current.y);
        if (stepY != 0) yield _Cell(current.x, current.y + stepY);
        current = _Cell(current.x + stepX, current.y + stepY);
        tMaxX += tDeltaX;
        tMaxY += tDeltaY;
      } else if (tMaxX < tMaxY) {
        current = _Cell(current.x + stepX, current.y);
        tMaxX += tDeltaX;
      } else {
        current = _Cell(current.x, current.y + stepY);
        tMaxY += tDeltaY;
      }
      yield current;
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

final class _StrokeCandidate {
  const _StrokeCandidate(
    this.stroke, {
    required this.priority,
    required this.distanceSquared,
  });

  final InkStroke stroke;
  final int priority;
  final double distanceSquared;
}

/// Fixed-size max-heap. The worst retained candidate remains at index zero so
/// a better incoming value replaces it in O(log limit).
final class _BoundedStrokeCandidateHeap {
  _BoundedStrokeCandidateHeap(this.limit);

  final int limit;
  final List<_StrokeCandidate> _values = <_StrokeCandidate>[];

  void add(_StrokeCandidate candidate) {
    if (_values.length < limit) {
      _values.add(candidate);
      _bubbleUp(_values.length - 1);
      return;
    }
    if (_compareCandidates(candidate, _values.first) >= 0) return;
    _values[0] = candidate;
    _bubbleDown(0);
  }

  List<InkStroke> takeSorted() {
    _values.sort(_compareCandidates);
    return List<InkStroke>.unmodifiable(
      _values.map((candidate) => candidate.stroke),
    );
  }

  void _bubbleUp(int index) {
    while (index > 0) {
      final parent = (index - 1) >> 1;
      if (_compareCandidates(_values[parent], _values[index]) >= 0) return;
      final swap = _values[parent];
      _values[parent] = _values[index];
      _values[index] = swap;
      index = parent;
    }
  }

  void _bubbleDown(int index) {
    while (true) {
      final left = index * 2 + 1;
      if (left >= _values.length) return;
      final right = left + 1;
      var worse = left;
      if (right < _values.length &&
          _compareCandidates(_values[right], _values[left]) > 0) {
        worse = right;
      }
      if (_compareCandidates(_values[index], _values[worse]) >= 0) return;
      final swap = _values[index];
      _values[index] = _values[worse];
      _values[worse] = swap;
      index = worse;
    }
  }
}

int _compareCandidates(_StrokeCandidate first, _StrokeCandidate second) {
  final priority = first.priority.compareTo(second.priority);
  if (priority != 0) return priority;
  final distance = first.distanceSquared.compareTo(second.distanceSquared);
  if (distance != 0) return distance;
  return first.stroke.id.compareTo(second.stroke.id);
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
  final result = byId.values.toList()..sort(_compareGroups);
  return result;
}

int _compareGroups(InkGroup first, InkGroup second) {
  final kind = first.kind.index.compareTo(second.kind.index);
  return kind != 0 ? kind : first.id.compareTo(second.id);
}
