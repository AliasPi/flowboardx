import 'dart:collection';
import 'dart:math' as math;

import 'board_object.dart';
import 'geometry.dart';
import 'ink.dart';
import 'scene_order.dart';

/// Marker for package-owned immutable list storage that can safely be shared
/// between independent document snapshots.
///
/// Implementations must reject every mutating [List] operation. The marker
/// lets model code retain persistent/chunked storage without turning each
/// small edit back into a full-list copy.
abstract interface class ImmutableModelListSource<E> implements List<E> {}

/// Immutable list revision that proves exactly one source position changed.
///
/// Consumers such as page-thumbnail invalidation can update one entry without
/// comparing the other 99 immutable pages after every completed pen stroke.
abstract interface class SingleReplacementModelList<E> implements List<E> {
  int? singleReplacementIndexFrom(List<E> previous);
}

/// An immutable model list whose storage can safely be shared by independently
/// immutable document snapshots.
///
/// Unlike `List.unmodifiable`, constructing this around an existing
/// [ImmutableModelList] does not copy its complete backing store again. Public
/// callers still cannot mutate either the wrapper or its private backing list.
final class ImmutableModelList<E> extends ListBase<E>
    implements ImmutableModelListSource<E> {
  factory ImmutableModelList(Iterable<E> values) {
    if (values is ImmutableModelList<E>) return values;
    return ImmutableModelList<E>._(
      values is ImmutableModelListSource<E>
          ? values
          : List<E>.unmodifiable(values),
    );
  }

  const ImmutableModelList._(this._values);

  final List<E> _values;

  @override
  int get length => _values.length;

  @override
  set length(int value) {
    throw UnsupportedError('ImmutableModelList ist unveränderlich.');
  }

  @override
  E operator [](int index) => _values[index];

  @override
  Iterator<E> get iterator => _values.iterator;

  @override
  Iterable<E> get reversed => _values.reversed;

  @override
  void operator []=(int index, E value) {
    throw UnsupportedError('ImmutableModelList ist unveränderlich.');
  }
}

enum SelectionMode { direct, rectangle, lasso }

enum InkGroupKind { letter, word, line, sketch, manual }

enum TemplateKind {
  overlappingCircles,
  mindMap,
  primarySchoolLines,
  vennDiagram,
}

enum DocumentAssetType { image, pdf, thumbnail, other }

final class ViewportState {
  const ViewportState({this.offsetX = 0, this.offsetY = 0, this.zoom = 1});

  static const minZoom = 0.1;
  static const maxZoom = 8.0;

  final double offsetX;
  final double offsetY;
  final double zoom;

  ViewportState normalized() => ViewportState(
    offsetX: offsetX.isFinite ? offsetX : 0,
    offsetY: offsetY.isFinite ? offsetY : 0,
    zoom: (zoom.isFinite ? zoom : 1.0).clamp(minZoom, maxZoom),
  );

  ViewportState copyWith({double? offsetX, double? offsetY, double? zoom}) =>
      ViewportState(
        offsetX: offsetX ?? this.offsetX,
        offsetY: offsetY ?? this.offsetY,
        zoom: zoom ?? this.zoom,
      ).normalized();

  Map<String, Object> toJson() => {
    'offsetX': offsetX,
    'offsetY': offsetY,
    'zoom': zoom,
  };

  factory ViewportState.fromJson(Map<String, Object?> json) => ViewportState(
    offsetX: _double(json['offsetX'], _double(json['x'], 0)),
    offsetY: _double(json['offsetY'], _double(json['y'], 0)),
    zoom: _double(json['zoom'], _double(json['scale'], 1)),
  ).normalized();

  @override
  bool operator ==(Object other) =>
      other is ViewportState &&
      other.offsetX == offsetX &&
      other.offsetY == offsetY &&
      other.zoom == zoom;

  @override
  int get hashCode => Object.hash(offsetX, offsetY, zoom);
}

final class SelectionState {
  SelectionState({
    Iterable<String> selectedItemIds = const [],
    this.mode = SelectionMode.direct,
  }) : selectedItemIds = List.unmodifiable(selectedItemIds.toSet());

  static final empty = SelectionState();

  final List<String> selectedItemIds;
  final SelectionMode mode;

  bool get isEmpty => selectedItemIds.isEmpty;

  SelectionState copyWith({
    Iterable<String>? selectedItemIds,
    SelectionMode? mode,
  }) => SelectionState(
    selectedItemIds: selectedItemIds ?? this.selectedItemIds,
    mode: mode ?? this.mode,
  );

  Map<String, Object> toJson() => {
    'selectedItemIds': selectedItemIds,
    'mode': mode.name,
  };

  factory SelectionState.fromJson(Map<String, Object?> json) => SelectionState(
    selectedItemIds: _stringList(json['selectedItemIds']),
    mode: _enumByName(SelectionMode.values, json['mode'], SelectionMode.direct),
  );
}

final class InkGroup {
  InkGroup({
    required this.id,
    required this.kind,
    required Iterable<String> strokeIds,
    required this.bounds,
    DateTime? createdAt,
  }) : strokeIds = List.unmodifiable(strokeIds.toSet()),
       createdAt = (createdAt ?? DateTime.now().toUtc()).toUtc();

  final String id;
  final InkGroupKind kind;
  final List<String> strokeIds;
  final Rect2 bounds;
  final DateTime createdAt;

  InkGroup copyWith({
    InkGroupKind? kind,
    Iterable<String>? strokeIds,
    Rect2? bounds,
  }) => InkGroup(
    id: id,
    kind: kind ?? this.kind,
    strokeIds: strokeIds ?? this.strokeIds,
    bounds: bounds ?? this.bounds,
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'strokeIds': strokeIds,
    'bounds': bounds.toJson(),
    'createdAt': createdAt.toIso8601String(),
  };

  factory InkGroup.fromJson(Map<String, Object?> json) => InkGroup(
    id: _string(json['id'], 'group'),
    kind: _enumByName(InkGroupKind.values, json['kind'], InkGroupKind.sketch),
    strokeIds: _stringList(json['strokeIds']),
    bounds: _rect(json['bounds']),
    createdAt: _date(json['createdAt']),
  );
}

/// A persistent selection group that may contain ink and/or board objects.
/// Geometric handwriting candidates remain in [InkGroup], so both concepts can
/// evolve independently.
final class ContentGroup {
  ContentGroup({
    required this.id,
    required Iterable<String> memberIds,
    required this.bounds,
    this.locked = false,
    DateTime? createdAt,
  }) : memberIds = List.unmodifiable(memberIds.toSet()),
       createdAt = (createdAt ?? DateTime.now().toUtc()).toUtc();

  final String id;
  final List<String> memberIds;
  final Rect2 bounds;
  final bool locked;
  final DateTime createdAt;

  ContentGroup copyWith({
    Iterable<String>? memberIds,
    Rect2? bounds,
    bool? locked,
  }) => ContentGroup(
    id: id,
    memberIds: memberIds ?? this.memberIds,
    bounds: bounds ?? this.bounds,
    locked: locked ?? this.locked,
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'memberIds': memberIds,
    'bounds': bounds.toJson(),
    'locked': locked,
    'createdAt': createdAt.toIso8601String(),
  };

  factory ContentGroup.fromJson(Map<String, Object?> json) => ContentGroup(
    id: _string(json['id'], 'content-group'),
    memberIds: _stringList(json['memberIds']),
    bounds: _rect(json['bounds']),
    locked: json['locked'] is bool && json['locked']! as bool,
    createdAt: _date(json['createdAt']),
  );
}

final class TemplateInstance {
  TemplateInstance({
    required this.id,
    required this.kind,
    this.version = 1,
    Map<String, Object?> properties = const {},
  }) : properties = Map.unmodifiable(properties);

  final String id;
  final TemplateKind kind;
  final int version;
  final Map<String, Object?> properties;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'version': version,
    'properties': properties,
  };

  factory TemplateInstance.fromJson(Map<String, Object?> json) =>
      TemplateInstance(
        id: _string(json['id'], 'template'),
        kind: _enumByName(
          TemplateKind.values,
          json['kind'],
          TemplateKind.vennDiagram,
        ),
        version: math.max(1, _integer(json['version'], 1)),
        properties: _objectMap(json['properties']),
      );
}

final class DocumentAsset {
  DocumentAsset({
    required this.id,
    required this.type,
    required this.relativePath,
    required this.mimeType,
    this.originalFileName,
    this.byteLength,
    this.sha256,
    DateTime? createdAt,
  }) : createdAt = (createdAt ?? DateTime.now().toUtc()).toUtc();

  final String id;
  final DocumentAssetType type;
  final String relativePath;
  final String mimeType;
  final String? originalFileName;
  final int? byteLength;
  final String? sha256;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type.name,
    'relativePath': relativePath,
    'mimeType': mimeType,
    if (originalFileName != null) 'originalFileName': originalFileName,
    if (byteLength != null) 'byteLength': byteLength,
    if (sha256 != null) 'sha256': sha256,
    'createdAt': createdAt.toIso8601String(),
  };

  factory DocumentAsset.fromJson(Map<String, Object?> json) => DocumentAsset(
    id: _string(json['id'], 'asset'),
    type: _enumByName(
      DocumentAssetType.values,
      json['type'],
      DocumentAssetType.other,
    ),
    relativePath: _string(json['relativePath'], ''),
    mimeType: _string(json['mimeType'], 'application/octet-stream'),
    originalFileName: _nullableString(json['originalFileName']),
    byteLength: json['byteLength'] is num
        ? math.max(0, (json['byteLength']! as num).toInt())
        : null,
    sha256: _nullableString(json['sha256']),
    createdAt: _date(json['createdAt']),
  );
}

final class DocumentMetadata {
  DocumentMetadata({
    this.author,
    this.deviceId,
    this.recoveredFromCrash = false,
    this.lastOpenedAt,
    Map<String, String> custom = const {},
  }) : custom = Map.unmodifiable(custom);

  final String? author;
  final String? deviceId;
  final bool recoveredFromCrash;
  final DateTime? lastOpenedAt;
  final Map<String, String> custom;

  DocumentMetadata copyWith({
    String? author,
    String? deviceId,
    bool? recoveredFromCrash,
    DateTime? lastOpenedAt,
    Map<String, String>? custom,
  }) => DocumentMetadata(
    author: author ?? this.author,
    deviceId: deviceId ?? this.deviceId,
    recoveredFromCrash: recoveredFromCrash ?? this.recoveredFromCrash,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
    custom: custom ?? this.custom,
  );

  Map<String, Object?> toJson() => {
    if (author != null) 'author': author,
    if (deviceId != null) 'deviceId': deviceId,
    'recoveredFromCrash': recoveredFromCrash,
    if (lastOpenedAt != null)
      'lastOpenedAt': lastOpenedAt!.toUtc().toIso8601String(),
    'custom': custom,
  };

  factory DocumentMetadata.fromJson(Map<String, Object?> json) =>
      DocumentMetadata(
        author: _nullableString(json['author']),
        deviceId: _nullableString(json['deviceId']),
        recoveredFromCrash:
            json['recoveredFromCrash'] is bool &&
            json['recoveredFromCrash']! as bool,
        lastOpenedAt: _nullableDate(json['lastOpenedAt']),
        custom: _stringMap(json['custom']),
      );
}

final class BoardPage {
  BoardPage({
    required this.id,
    required this.name,
    this.viewport = const ViewportState(),
    Iterable<InkStroke> strokes = const [],
    Iterable<BoardObject> objects = const [],
    Iterable<ObjectInkLayer> annotationLayers = const [],
    Iterable<InkGroup> groups = const [],
    Iterable<ContentGroup> contentGroups = const [],
    SelectionState? selection,
    this.template,
    this.thumbnailAssetId,
  }) : strokes = List.unmodifiable(strokes),
       objects = List.unmodifiable(objects),
       annotationLayers = List.unmodifiable(annotationLayers),
       groups = ImmutableModelList(groups),
       contentGroups = List.unmodifiable(contentGroups),
       selection = selection ?? SelectionState.empty,
       _sceneSummaryCache = null;

  BoardPage._({
    required this.id,
    required this.name,
    required this.viewport,
    required this.strokes,
    required this.objects,
    required this.annotationLayers,
    required this.groups,
    required this.contentGroups,
    required this.selection,
    required this.template,
    required this.thumbnailAssetId,
    required _BoardPageSceneSummary? sceneSummary,
  }) : _sceneSummaryCache = sceneSummary;

  factory BoardPage.empty({required String id, String name = 'Seite 1'}) =>
      BoardPage(id: id, name: name);

  final String id;
  final String name;
  final ViewportState viewport;
  final List<InkStroke> strokes;
  final List<BoardObject> objects;
  final List<ObjectInkLayer> annotationLayers;
  final List<InkGroup> groups;
  final List<ContentGroup> contentGroups;
  final SelectionState selection;
  final TemplateInstance? template;
  final String? thumbnailAssetId;
  _BoardPageSceneSummary? _sceneSummaryCache;

  _BoardPageSceneSummary get _sceneSummary =>
      _sceneSummaryCache ??= _BoardPageSceneSummary.fromPage(this);

  /// Constant-depth duplicate lookup for the normal append path. The index is
  /// persistent, so older snapshots retained by Undo/Redo remain independent.
  bool containsTopLevelStrokeId(String strokeId) =>
      _sceneSummary.strokeIds.contains(strokeId);

  /// Cached maximum across objects and top-level strokes.
  int get nextTopLevelSceneZIndex => _sceneSummary.maximumZIndex + 1;

  /// Appends without rebuilding the complete stroke list. Storage is split
  /// into shallow fixed-size chunks, preserving O(1) indexing and iteration
  /// while sharing all completed chunks with history snapshots.
  BoardPage appendTopLevelStroke(InkStroke stroke) => BoardPage._(
    id: id,
    name: name,
    viewport: viewport,
    strokes: _ChunkedImmutableList<InkStroke>.from(strokes).appended(stroke),
    objects: objects,
    annotationLayers: annotationLayers,
    groups: groups,
    contentGroups: contentGroups,
    selection: selection,
    template: template,
    thumbnailAssetId: thumbnailAssetId,
    sceneSummary: _sceneSummary.appended(stroke),
  );

  InkStroke? strokeById(String id) =>
      strokes.where((stroke) => stroke.id == id).firstOrNull;
  BoardObject? objectById(String id) =>
      objects.where((object) => object.id == id).firstOrNull;
  ObjectInkLayer? annotationFor(String objectId, {int? pdfPageIndex}) {
    final matching = annotationLayers.where(
      (layer) => layer.objectId == objectId,
    );
    if (pdfPageIndex != null) {
      return matching
              .where((layer) => layer.pdfPageIndex == pdfPageIndex)
              .firstOrNull ??
          matching.where((layer) => layer.pdfPageIndex == null).firstOrNull;
    }
    return matching.where((layer) => layer.pdfPageIndex == null).firstOrNull ??
        matching.firstOrNull;
  }

  BoardPage copyWith({
    String? id,
    String? name,
    ViewportState? viewport,
    Iterable<InkStroke>? strokes,
    Iterable<BoardObject>? objects,
    Iterable<ObjectInkLayer>? annotationLayers,
    Iterable<InkGroup>? groups,
    Iterable<ContentGroup>? contentGroups,
    SelectionState? selection,
    TemplateInstance? template,
    bool clearTemplate = false,
    String? thumbnailAssetId,
    bool clearThumbnail = false,
  }) {
    final nextStrokes = strokes == null || identical(strokes, this.strokes)
        ? this.strokes
        : List<InkStroke>.unmodifiable(strokes);
    final nextObjects = objects == null || identical(objects, this.objects)
        ? this.objects
        : List<BoardObject>.unmodifiable(objects);
    return BoardPage._(
      id: id ?? this.id,
      name: name ?? this.name,
      viewport: viewport ?? this.viewport,
      strokes: nextStrokes,
      objects: nextObjects,
      annotationLayers:
          annotationLayers == null ||
              identical(annotationLayers, this.annotationLayers)
          ? this.annotationLayers
          : List<ObjectInkLayer>.unmodifiable(annotationLayers),
      groups: groups == null || identical(groups, this.groups)
          ? this.groups
          : ImmutableModelList(groups),
      contentGroups:
          contentGroups == null || identical(contentGroups, this.contentGroups)
          ? this.contentGroups
          : List<ContentGroup>.unmodifiable(contentGroups),
      selection: selection ?? this.selection,
      template: clearTemplate ? null : template ?? this.template,
      thumbnailAssetId: clearThumbnail
          ? null
          : thumbnailAssetId ?? this.thumbnailAssetId,
      sceneSummary: identical(nextStrokes, this.strokes)
          ? identical(nextObjects, this.objects)
                ? _sceneSummaryCache
                : _sceneSummaryCache?.withObjects(nextObjects)
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'viewport': viewport.toJson(),
    'strokes': strokes.map((stroke) => stroke.toJson()).toList(growable: false),
    'objects': objects.map((object) => object.toJson()).toList(growable: false),
    'annotationLayers': annotationLayers
        .map((layer) => layer.toJson())
        .toList(growable: false),
    'groups': groups.map((group) => group.toJson()).toList(growable: false),
    'contentGroups': contentGroups
        .map((group) => group.toJson())
        .toList(growable: false),
    'selection': selection.toJson(),
    if (template != null) 'template': template!.toJson(),
    if (thumbnailAssetId != null) 'thumbnailAssetId': thumbnailAssetId,
  };

  factory BoardPage.fromJson(Map<String, Object?> json) {
    final objects = <BoardObject>[];
    for (final item in _mapList(json['objects'])) {
      objects.add(BoardObject.fromJson(item));
    }
    final objectIds = objects.map((object) => object.id).toSet();
    return BoardPage(
      id: _string(json['id'], 'page'),
      name: _string(json['name'], 'Seite'),
      viewport:
          _typedMap(json['viewport'], ViewportState.fromJson) ??
          const ViewportState(),
      strokes: _mapList(json['strokes']).map(InkStroke.fromJson),
      objects: objects,
      annotationLayers: _mapList(json['annotationLayers'])
          .map(ObjectInkLayer.fromJson)
          .where((layer) => objectIds.contains(layer.objectId)),
      groups: _mapList(json['groups']).map(InkGroup.fromJson),
      contentGroups: _mapList(json['contentGroups']).map(ContentGroup.fromJson),
      selection:
          _typedMap(json['selection'], SelectionState.fromJson) ??
          SelectionState.empty,
      template: _typedMap(json['template'], TemplateInstance.fromJson),
      thumbnailAssetId: _nullableString(json['thumbnailAssetId']),
    ).sanitized();
  }

  /// Repairs cross references without changing valid content.
  BoardPage sanitized() {
    final seen = <String>{};
    var changed = false;
    final validStrokes = <InkStroke>[];
    for (final stroke in strokes) {
      if (stroke.id.isEmpty || !seen.add(stroke.id)) {
        changed = true;
      } else {
        validStrokes.add(stroke);
      }
    }
    final validObjects = <BoardObject>[];
    for (final object in objects) {
      if (object.id.isEmpty || !seen.add(object.id)) {
        changed = true;
      } else {
        validObjects.add(object);
      }
    }
    final strokeIds = validStrokes.map((stroke) => stroke.id).toSet();
    final objectIds = validObjects.map((object) => object.id).toSet();
    final validAnnotations = <ObjectInkLayer>[];
    for (final layer in annotationLayers) {
      if (!objectIds.contains(layer.objectId) || !seen.add(layer.id)) {
        changed = true;
        continue;
      }
      final layerStrokes = <InkStroke>[];
      var layerChanged = false;
      for (final stroke in layer.strokes) {
        if (stroke.id.isEmpty || !seen.add(stroke.id)) {
          changed = true;
          layerChanged = true;
        } else {
          layerStrokes.add(stroke);
        }
      }
      validAnnotations.add(
        layerChanged ? layer.copyWith(strokes: layerStrokes) : layer,
      );
    }
    final validGroups = <InkGroup>[];
    for (final group in groups) {
      final members = group.strokeIds.where(strokeIds.contains).toList();
      if (members.isEmpty || !seen.add(group.id)) {
        changed = true;
        continue;
      }
      final groupChanged = members.length != group.strokeIds.length;
      if (groupChanged) changed = true;
      validGroups.add(
        groupChanged ? group.copyWith(strokeIds: members) : group,
      );
    }
    final strokeById = {for (final stroke in validStrokes) stroke.id: stroke};
    final objectById = {for (final object in validObjects) object.id: object};
    final validItemIds = {...strokeIds, ...objectIds};
    final validContentGroups = <ContentGroup>[];
    for (final group in contentGroups) {
      final members = group.memberIds.where(validItemIds.contains).toList();
      if (members.length < 2 || !seen.add(group.id)) {
        changed = true;
        continue;
      }
      Rect2? bounds;
      for (final memberId in members) {
        final memberBounds =
            strokeById[memberId]?.bounds ??
            objectById[memberId]?.transform.bounds;
        if (memberBounds != null) {
          bounds = bounds == null ? memberBounds : bounds.union(memberBounds);
        }
      }
      final nextBounds = bounds ?? group.bounds;
      final groupChanged =
          members.length != group.memberIds.length ||
          nextBounds != group.bounds;
      if (groupChanged) changed = true;
      validContentGroups.add(
        groupChanged
            ? group.copyWith(memberIds: members, bounds: nextBounds)
            : group,
      );
    }
    final selectable = {
      ...validItemIds,
      ...validGroups.map((group) => group.id),
      ...validContentGroups.map((group) => group.id),
    };
    final selectedIds = selection.selectedItemIds
        .where(selectable.contains)
        .toList(growable: false);
    final selectionChanged =
        selectedIds.length != selection.selectedItemIds.length;
    if (selectionChanged) changed = true;
    if (!changed) return this;
    return copyWith(
      strokes: validStrokes,
      objects: validObjects,
      annotationLayers: validAnnotations,
      groups: validGroups,
      contentGroups: validContentGroups,
      selection: selectionChanged
          ? selection.copyWith(selectedItemIds: selectedIds)
          : selection,
    );
  }
}

/// Flat, fixed-size chunk storage for append-heavy immutable lists.
///
/// A linked persistent list would make random access and chronological
/// iteration proportional to the number of completed strokes. Here both stay
/// O(1): only the at-most 63-item tail is copied on an ordinary append, and
/// every 64th append copies the much smaller chunk directory.
final class _ChunkedImmutableList<E> extends ListBase<E>
    implements SingleAppendSceneList<E> {
  factory _ChunkedImmutableList.from(Iterable<E> values) {
    if (values is _ChunkedImmutableList<E>) return values;
    final chunks = <List<E>>[];
    var tail = <E>[];
    var length = 0;
    for (final value in values) {
      tail.add(value);
      length++;
      if (tail.length == _chunkSize) {
        chunks.add(List<E>.unmodifiable(tail));
        tail = <E>[];
      }
    }
    return _ChunkedImmutableList<E>._(
      List<List<E>>.unmodifiable(chunks),
      List<E>.unmodifiable(tail),
      length,
      Object(),
      null,
      values is List<E> ? values : null,
      null,
    );
  }

  _ChunkedImmutableList._(
    this._chunks,
    this._tail,
    this._length,
    this._revision,
    this._parentRevision,
    this._equivalentSource,
    this._plainParentSource,
  );

  static const int _chunkSize = 64;

  final List<List<E>> _chunks;
  final List<E> _tail;
  final int _length;
  final Object _revision;
  final Object? _parentRevision;
  // [BoardPage] always exposes an immutable list. Remembering that identity
  // while converting its first plain/recovered snapshot lets the appended
  // child prove ancestry without comparing every old stroke.
  final List<E>? _equivalentSource;
  final List<E>? _plainParentSource;

  _ChunkedImmutableList<E> appended(E value) {
    if (_tail.length < _chunkSize - 1) {
      return _ChunkedImmutableList<E>._(
        _chunks,
        List<E>.unmodifiable(_tail.followedBy(<E>[value])),
        _length + 1,
        Object(),
        _revision,
        null,
        _equivalentSource,
      );
    }
    final completedTail = List<E>.unmodifiable(_tail.followedBy(<E>[value]));
    return _ChunkedImmutableList<E>._(
      List<List<E>>.unmodifiable(_chunks.followedBy(<List<E>>[completedTail])),
      List<E>.empty(growable: false),
      _length + 1,
      Object(),
      _revision,
      null,
      _equivalentSource,
    );
  }

  @override
  bool isSingleAppendOf(List<E> previous) {
    if (_length != previous.length + 1) return false;
    if (identical(_plainParentSource, previous)) return true;
    return previous is _ChunkedImmutableList<E> &&
        identical(_parentRevision, previous._revision);
  }

  @override
  int get length => _length;

  @override
  set length(int value) {
    throw UnsupportedError('Stroke-Liste ist unveränderlich.');
  }

  @override
  E operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final chunkIndex = index ~/ _chunkSize;
    if (chunkIndex < _chunks.length) {
      return _chunks[chunkIndex][index % _chunkSize];
    }
    return _tail[index - _chunks.length * _chunkSize];
  }

  @override
  void operator []=(int index, E value) {
    throw UnsupportedError('Stroke-Liste ist unveränderlich.');
  }
}

/// Fixed-depth persistent storage for a document's at-most-100 pages.
///
/// Replacing the active page copies one at-most-16-entry chunk and the small
/// chunk directory. Older command-history snapshots keep the other chunks by
/// identity, and indexed access never follows a linked revision chain.
final class _ChunkedPageList<E> extends ListBase<E>
    implements ImmutableModelListSource<E>, SingleReplacementModelList<E> {
  factory _ChunkedPageList.from(Iterable<E> values) {
    if (values is _ChunkedPageList<E>) return values;
    final chunks = <List<E>>[];
    var current = <E>[];
    var length = 0;
    for (final value in values) {
      current.add(value);
      length++;
      if (current.length == _chunkSize) {
        chunks.add(List<E>.unmodifiable(current));
        current = <E>[];
      }
    }
    if (current.isNotEmpty) chunks.add(List<E>.unmodifiable(current));
    return _ChunkedPageList<E>._(
      List<List<E>>.unmodifiable(chunks),
      length,
      Object(),
      null,
      null,
    );
  }

  _ChunkedPageList._(
    this._chunks,
    this._length,
    this._revision,
    this._parentRevision,
    this._replacementIndex,
  );

  static const int _chunkSize = 16;

  final List<List<E>> _chunks;
  final int _length;
  final Object _revision;
  final Object? _parentRevision;
  final int? _replacementIndex;

  _ChunkedPageList<E> replaced(int index, E value) {
    RangeError.checkValidIndex(index, this);
    final chunkIndex = index ~/ _chunkSize;
    final itemIndex = index % _chunkSize;
    final nextChunk = List<E>.of(_chunks[chunkIndex], growable: false);
    nextChunk[itemIndex] = value;
    final nextChunks = List<List<E>>.of(_chunks, growable: false);
    nextChunks[chunkIndex] = List<E>.unmodifiable(nextChunk);
    return _ChunkedPageList<E>._(
      List<List<E>>.unmodifiable(nextChunks),
      _length,
      Object(),
      _revision,
      index,
    );
  }

  @override
  int? singleReplacementIndexFrom(List<E> previous) =>
      previous is _ChunkedPageList<E> &&
          previous.length == _length &&
          identical(_parentRevision, previous._revision)
      ? _replacementIndex
      : null;

  @override
  int get length => _length;

  @override
  set length(int value) {
    throw UnsupportedError('Seiten-Liste ist unveränderlich.');
  }

  @override
  E operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _chunks[index ~/ _chunkSize][index % _chunkSize];
  }

  @override
  void operator []=(int index, E value) {
    throw UnsupportedError('Seiten-Liste ist unveränderlich.');
  }
}

final class _BoardPageSceneSummary {
  const _BoardPageSceneSummary({
    required this.maximumZIndex,
    required this.maximumStrokeZIndex,
    required this.strokeIds,
  });

  factory _BoardPageSceneSummary.fromPage(BoardPage page) {
    var maximumStroke = -1;
    _PersistentStringSet strokeIds = const _PersistentStringSet.empty();
    for (final stroke in page.strokes) {
      if (stroke.zIndex > maximumStroke) maximumStroke = stroke.zIndex;
      strokeIds = strokeIds.added(stroke.id);
    }
    var maximumObject = -1;
    for (final object in page.objects) {
      if (object.zIndex > maximumObject) maximumObject = object.zIndex;
    }
    return _BoardPageSceneSummary(
      maximumZIndex: math.max(maximumStroke, maximumObject),
      maximumStrokeZIndex: maximumStroke,
      strokeIds: strokeIds,
    );
  }

  final int maximumZIndex;
  final int maximumStrokeZIndex;
  final _PersistentStringSet strokeIds;

  _BoardPageSceneSummary appended(InkStroke stroke) => _BoardPageSceneSummary(
    maximumZIndex: stroke.zIndex > maximumZIndex
        ? stroke.zIndex
        : maximumZIndex,
    maximumStrokeZIndex: stroke.zIndex > maximumStrokeZIndex
        ? stroke.zIndex
        : maximumStrokeZIndex,
    strokeIds: strokeIds.added(stroke.id),
  );

  /// Object transforms/reordering do not invalidate the persistent stroke-ID
  /// trie. Recompute only the usually small object maximum; otherwise the next
  /// pen-up after moving a table/PDF would rescan every historic stroke.
  _BoardPageSceneSummary withObjects(Iterable<BoardObject> objects) {
    var maximumObject = -1;
    for (final object in objects) {
      if (object.zIndex > maximumObject) maximumObject = object.zIndex;
    }
    return _BoardPageSceneSummary(
      maximumZIndex: math.max(maximumStrokeZIndex, maximumObject),
      maximumStrokeZIndex: maximumStrokeZIndex,
      strokeIds: strokeIds,
    );
  }
}

/// A compact persistent hash trie. An append copies only the hash path (at
/// most 30 small nodes), rather than copying an ever-growing ID set retained by
/// every Undo/Redo snapshot.
final class _PersistentStringSet {
  const _PersistentStringSet.empty() : _root = null;
  const _PersistentStringSet._(this._root);

  final _StringTrieNode? _root;

  bool contains(String value) =>
      _root?.contains(value, _stringHash(value), 0) ?? false;

  _PersistentStringSet added(String value) {
    final hash = _stringHash(value);
    final root = _root;
    if (root == null) {
      return _PersistentStringSet._(_StringTrieLeaf(hash, <String>[value]));
    }
    return _PersistentStringSet._(root.added(value, hash, 0));
  }
}

sealed class _StringTrieNode {
  const _StringTrieNode();

  bool contains(String value, int hash, int shift);

  _StringTrieNode added(String value, int hash, int shift);
}

final class _StringTrieLeaf extends _StringTrieNode {
  _StringTrieLeaf(this.hash, Iterable<String> values)
    : values = List<String>.unmodifiable(values);

  final int hash;
  final List<String> values;

  @override
  bool contains(String value, int hash, int shift) =>
      this.hash == hash && values.contains(value);

  @override
  _StringTrieNode added(String value, int hash, int shift) {
    if (this.hash == hash) {
      if (values.contains(value)) return this;
      return _StringTrieLeaf(hash, values.followedBy(<String>[value]));
    }
    return _mergeStringTrieLeaves(
      this,
      _StringTrieLeaf(hash, <String>[value]),
      shift,
    );
  }
}

final class _StringTrieBranch extends _StringTrieNode {
  const _StringTrieBranch(this.zero, this.one);

  final _StringTrieNode? zero;
  final _StringTrieNode? one;

  @override
  bool contains(String value, int hash, int shift) {
    final child = _stringHashBit(hash, shift) == 0 ? zero : one;
    return child?.contains(value, hash, shift + 1) ?? false;
  }

  @override
  _StringTrieNode added(String value, int hash, int shift) {
    if (_stringHashBit(hash, shift) == 0) {
      final current = zero;
      final next = current == null
          ? _StringTrieLeaf(hash, <String>[value])
          : current.added(value, hash, shift + 1);
      return identical(current, next) ? this : _StringTrieBranch(next, one);
    }
    final current = one;
    final next = current == null
        ? _StringTrieLeaf(hash, <String>[value])
        : current.added(value, hash, shift + 1);
    return identical(current, next) ? this : _StringTrieBranch(zero, next);
  }
}

_StringTrieNode _mergeStringTrieLeaves(
  _StringTrieLeaf first,
  _StringTrieLeaf second,
  int shift,
) {
  final firstBit = _stringHashBit(first.hash, shift);
  final secondBit = _stringHashBit(second.hash, shift);
  if (firstBit != secondBit) {
    return firstBit == 0
        ? _StringTrieBranch(first, second)
        : _StringTrieBranch(second, first);
  }
  final child = _mergeStringTrieLeaves(first, second, shift + 1);
  return firstBit == 0
      ? _StringTrieBranch(child, null)
      : _StringTrieBranch(null, child);
}

int _stringHash(String value) => value.hashCode & 0x3fffffff;

int _stringHashBit(int hash, int shift) => (hash >> shift) & 1;

/// Formats the local creation time used as the title of a new whiteboard.
///
/// Keeping this independent from locale-specific formatters makes filenames
/// and document cards deterministic on every supported platform.
String formatNewWhiteboardTitle(DateTime timestamp) {
  final local = timestamp.toLocal();
  String padded(int value, int width) => value.toString().padLeft(width, '0');
  return '${padded(local.year, 4)}'
      '${padded(local.month, 2)}'
      '${padded(local.day, 2)}-'
      '${padded(local.hour, 2)}_'
      '${padded(local.minute, 2)}';
}

final class WhiteboardDocument {
  WhiteboardDocument({
    required this.id,
    required this.title,
    required DateTime createdAt,
    required DateTime updatedAt,
    required Iterable<BoardPage> pages,
    this.currentPageIndex = 0,
    Iterable<PenPreset> presets = const [],
    this.activePresetId = 'black',
    Iterable<DocumentAsset> assets = const [],
    DocumentMetadata? metadata,
    this.thumbnailAssetId,
    this.revision = 0,
  }) : createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc(),
       pages = _ChunkedPageList<BoardPage>.from(pages),
       presets = List.unmodifiable(presets),
       assets = List.unmodifiable(assets),
       metadata = metadata ?? DocumentMetadata() {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'darf nicht leer sein');
    }
    if (this.pages.isEmpty || this.pages.length > maxPageCount) {
      throw ArgumentError.value(
        this.pages.length,
        'pages.length',
        'muss zwischen 1 und $maxPageCount liegen',
      );
    }
    if (currentPageIndex < 0 || currentPageIndex >= this.pages.length) {
      throw RangeError.range(
        currentPageIndex,
        0,
        this.pages.length - 1,
        'currentPageIndex',
      );
    }
    final pageIndices = <String, int>{};
    for (var index = 0; index < this.pages.length; index++) {
      pageIndices[this.pages[index].id] = index;
    }
    if (pageIndices.length != this.pages.length ||
        pageIndices.keys.any((id) => id.isEmpty)) {
      throw ArgumentError.value(
        pageIndices.keys,
        'pages',
        'Seiten-IDs müssen eindeutig und nicht leer sein',
      );
    }
    _pageIndexByIdCache = Map<String, int>.unmodifiable(pageIndices);
  }

  WhiteboardDocument._trusted({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.pages,
    required this.currentPageIndex,
    required this.presets,
    required this.activePresetId,
    required this.assets,
    required this.metadata,
    required this.thumbnailAssetId,
    required this.revision,
    Map<String, int>? pageIndexById,
  }) : _pageIndexByIdCache = pageIndexById;

  factory WhiteboardDocument.create({
    required String id,
    String? title,
    DateTime? now,
  }) {
    final creationTime = now ?? DateTime.now();
    final timestamp = creationTime.toUtc();
    return WhiteboardDocument(
      id: id,
      title: title ?? formatNewWhiteboardTitle(creationTime),
      createdAt: timestamp,
      updatedAt: timestamp,
      pages: [BoardPage.empty(id: '${id}_page_1')],
      presets: defaultPenPresets,
    );
  }

  static const maxPageCount = 100;
  static const defaultPenPresets = [
    PenPreset(id: 'black', name: 'Schwarz', width: 8),
    PenPreset(
      id: 'marker-yellow',
      name: 'Marker Gelb',
      colorArgb: 0x80FFEB3B,
      width: 18,
      type: InkToolType.marker,
    ),
    PenPreset(
      id: 'line-blue',
      name: 'Linie Blau',
      colorArgb: 0xFF2196F3,
      width: 4,
      type: InkToolType.straightLine,
    ),
  ];

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<BoardPage> pages;
  final int currentPageIndex;
  final List<PenPreset> presets;
  final String activePresetId;
  final List<DocumentAsset> assets;
  final DocumentMetadata metadata;
  final String? thumbnailAssetId;
  final int revision;
  Map<String, int>? _pageIndexByIdCache;

  Map<String, int> get _pageIndexById =>
      _pageIndexByIdCache ??= Map<String, int>.unmodifiable(<String, int>{
        for (var index = 0; index < pages.length; index++)
          pages[index].id: index,
      });

  BoardPage get currentPage => pages[currentPageIndex];
  PenPreset get activePreset =>
      presets.where((preset) => preset.id == activePresetId).firstOrNull ??
      defaultPenPresets.first;

  int? pageIndexById(String pageId) => _pageIndexById[pageId];

  BoardPage? pageById(String pageId) {
    final index = pageIndexById(pageId);
    return index == null ? null : pages[index];
  }

  WhiteboardDocument replacePage(BoardPage page, {DateTime? now}) {
    final index = pageIndexById(page.id);
    if (index == null) {
      throw StateError('Seite ${page.id} ist nicht Teil des Dokuments.');
    }
    // `page.id` is the same validated ID at [index], so replacing it cannot
    // violate the document's page-ID invariant. Build the immutable list once
    // and use the trusted snapshot constructor instead of copying and
    // revalidating all pages again on every committed stroke.
    final nextPages = _ChunkedPageList<BoardPage>.from(
      pages,
    ).replaced(index, page);
    return WhiteboardDocument._trusted(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: (now ?? DateTime.now()).toUtc(),
      pages: nextPages,
      currentPageIndex: currentPageIndex,
      presets: presets,
      activePresetId: activePresetId,
      assets: assets,
      metadata: metadata,
      thumbnailAssetId: thumbnailAssetId,
      revision: revision + 1,
      pageIndexById: _pageIndexById,
    );
  }

  WhiteboardDocument copyWith({
    String? title,
    DateTime? updatedAt,
    Iterable<BoardPage>? pages,
    int? currentPageIndex,
    Iterable<PenPreset>? presets,
    String? activePresetId,
    Iterable<DocumentAsset>? assets,
    DocumentMetadata? metadata,
    String? thumbnailAssetId,
    bool clearThumbnail = false,
    int? revision,
  }) {
    final nextPages = pages == null || identical(pages, this.pages)
        ? this.pages
        : _ChunkedPageList<BoardPage>.from(pages);
    final nextPageIndex = currentPageIndex ?? this.currentPageIndex;
    if (nextPages.isEmpty || nextPages.length > maxPageCount) {
      throw ArgumentError.value(
        nextPages.length,
        'pages.length',
        'muss zwischen 1 und $maxPageCount liegen',
      );
    }
    if (nextPageIndex < 0 || nextPageIndex >= nextPages.length) {
      throw RangeError.range(
        nextPageIndex,
        0,
        nextPages.length - 1,
        'currentPageIndex',
      );
    }
    if (!identical(nextPages, this.pages)) {
      final pageIds = nextPages.map((page) => page.id).toSet();
      if (pageIds.length != nextPages.length ||
          pageIds.any((pageId) => pageId.isEmpty)) {
        throw ArgumentError.value(
          pageIds,
          'pages',
          'Seiten-IDs müssen eindeutig und nicht leer sein',
        );
      }
    }
    final nextPresets = presets == null || identical(presets, this.presets)
        ? this.presets
        : List<PenPreset>.unmodifiable(presets);
    final nextAssets = assets == null || identical(assets, this.assets)
        ? this.assets
        : List<DocumentAsset>.unmodifiable(assets);
    return WhiteboardDocument._trusted(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: (updatedAt ?? this.updatedAt).toUtc(),
      pages: nextPages,
      currentPageIndex: nextPageIndex,
      presets: nextPresets,
      activePresetId: activePresetId ?? this.activePresetId,
      assets: nextAssets,
      metadata: metadata ?? this.metadata,
      thumbnailAssetId: clearThumbnail
          ? null
          : thumbnailAssetId ?? this.thumbnailAssetId,
      revision: revision ?? this.revision,
      pageIndexById: identical(nextPages, this.pages)
          ? _pageIndexByIdCache
          : null,
    );
  }

  Map<String, Object?> toJson({required int schemaVersion}) => {
    'schemaVersion': schemaVersion,
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'revision': revision,
    'currentPageIndex': currentPageIndex,
    'pages': pages.map((page) => page.toJson()).toList(growable: false),
    'presets': presets.map((preset) => preset.toJson()).toList(growable: false),
    'activePresetId': activePresetId,
    'assets': assets.map((asset) => asset.toJson()).toList(growable: false),
    'metadata': metadata.toJson(),
    if (thumbnailAssetId != null) 'thumbnailAssetId': thumbnailAssetId,
  };

  factory WhiteboardDocument.fromJson(Map<String, Object?> json) {
    final documentId = _string(json['id'], 'document');
    final decodedPages = _mapList(
      json['pages'],
    ).take(maxPageCount).map(BoardPage.fromJson).toList();
    if (decodedPages.isEmpty) {
      throw const FormatException('Das Dokument enthält keine gültige Seite.');
    }
    final pageIds = <String>{};
    final rawPages = <BoardPage>[];
    for (var index = 0; index < decodedPages.length; index++) {
      final page = decodedPages[index];
      var pageId = page.id;
      if (pageId.isEmpty || pageIds.contains(pageId)) {
        pageId = '${documentId}_page_${index + 1}';
        var suffix = 2;
        while (pageIds.contains(pageId)) {
          pageId = '${documentId}_page_${index + 1}_$suffix';
          suffix++;
        }
      }
      pageIds.add(pageId);
      rawPages.add(pageId == page.id ? page : page.copyWith(id: pageId));
    }
    final presetById = <String, PenPreset>{};
    for (final preset in _mapList(json['presets']).map(PenPreset.fromJson)) {
      presetById.putIfAbsent(preset.id, () => preset);
    }
    if (presetById.isEmpty) {
      for (final preset in defaultPenPresets) {
        presetById[preset.id] = preset;
      }
    }
    presetById.putIfAbsent('black', () => defaultPenPresets.first);
    final presets = presetById.values.toList();
    final assetById = <String, DocumentAsset>{};
    for (final asset in _mapList(json['assets']).map(DocumentAsset.fromJson)) {
      assetById.putIfAbsent(asset.id, () => asset);
    }
    final current = _integer(
      json['currentPageIndex'],
      0,
    ).clamp(0, rawPages.length - 1);
    final createdAt = _date(json['createdAt']);
    final updatedAt = _date(json['updatedAt']);
    return WhiteboardDocument(
      id: documentId,
      title: _string(json['title'], 'Unbenanntes Whiteboard'),
      createdAt: createdAt,
      updatedAt: updatedAt.isBefore(createdAt) ? createdAt : updatedAt,
      pages: rawPages,
      currentPageIndex: current,
      presets: presets,
      activePresetId: presetById.containsKey(json['activePresetId'])
          ? json['activePresetId']! as String
          : 'black',
      assets: assetById.values,
      metadata:
          _typedMap(json['metadata'], DocumentMetadata.fromJson) ??
          DocumentMetadata(),
      thumbnailAssetId: _nullableString(json['thumbnailAssetId']),
      revision: math.max(0, _integer(json['revision'], 0)),
    );
  }
}

T _enumByName<T extends Enum>(List<T> values, Object? value, T fallback) =>
    values
        .where((candidate) => candidate.name == value?.toString())
        .firstOrNull ??
    fallback;

double _double(Object? value, double fallback) {
  final result = value is num ? value.toDouble() : fallback;
  return result.isFinite ? result : fallback;
}

int _integer(Object? value, int fallback) =>
    value is num ? value.toInt() : fallback;
String _string(Object? value, String fallback) =>
    value is String && value.isNotEmpty ? value : fallback;
String? _nullableString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;
DateTime _date(Object? value) =>
    DateTime.tryParse(value?.toString() ?? '')?.toUtc() ??
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
DateTime? _nullableDate(Object? value) =>
    DateTime.tryParse(value?.toString() ?? '')?.toUtc();

List<String> _stringList(Object? value) =>
    value is List ? List.unmodifiable(value.whereType<String>()) : const [];

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const {};
  return Map.unmodifiable(
    value.map((key, item) => MapEntry(key.toString(), item.toString())),
  );
}

Map<String, Object?> _objectMap(Object? value) => value is Map
    ? Map<String, Object?>.unmodifiable(Map<String, Object?>.from(value))
    : const {};

Iterable<Map<String, Object?>> _mapList(Object? value) sync* {
  if (value is! List) return;
  for (final item in value) {
    if (item is Map) yield Map<String, Object?>.from(item);
  }
}

T? _typedMap<T>(Object? value, T Function(Map<String, Object?>) decode) =>
    value is Map ? decode(Map<String, Object?>.from(value)) : null;

Rect2 _rect(Object? value) => value is Map
    ? Rect2.fromJson(Map<String, Object?>.from(value))
    : const Rect2.zero();
