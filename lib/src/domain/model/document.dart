import 'dart:math' as math;

import 'board_object.dart';
import 'geometry.dart';
import 'ink.dart';

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
       groups = List.unmodifiable(groups),
       contentGroups = List.unmodifiable(contentGroups),
       selection = selection ?? SelectionState.empty;

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
  }) => BoardPage(
    id: id ?? this.id,
    name: name ?? this.name,
    viewport: viewport ?? this.viewport,
    strokes: strokes ?? this.strokes,
    objects: objects ?? this.objects,
    annotationLayers: annotationLayers ?? this.annotationLayers,
    groups: groups ?? this.groups,
    contentGroups: contentGroups ?? this.contentGroups,
    selection: selection ?? this.selection,
    template: clearTemplate ? null : template ?? this.template,
    thumbnailAssetId: clearThumbnail
        ? null
        : thumbnailAssetId ?? this.thumbnailAssetId,
  );

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
    final validStrokes = strokes
        .where((stroke) => stroke.id.isNotEmpty && seen.add(stroke.id))
        .toList();
    final validObjects = objects
        .where((object) => object.id.isNotEmpty && seen.add(object.id))
        .toList();
    final strokeIds = validStrokes.map((stroke) => stroke.id).toSet();
    final objectIds = validObjects.map((object) => object.id).toSet();
    final validAnnotations = <ObjectInkLayer>[];
    for (final layer in annotationLayers) {
      if (!objectIds.contains(layer.objectId) || !seen.add(layer.id)) continue;
      final layerStrokes = layer.strokes
          .where((stroke) => stroke.id.isNotEmpty && seen.add(stroke.id))
          .toList();
      validAnnotations.add(layer.copyWith(strokes: layerStrokes));
    }
    final validGroups = <InkGroup>[];
    for (final group in groups) {
      final members = group.strokeIds.where(strokeIds.contains).toList();
      if (members.isNotEmpty && seen.add(group.id)) {
        validGroups.add(group.copyWith(strokeIds: members));
      }
    }
    final strokeById = {for (final stroke in validStrokes) stroke.id: stroke};
    final objectById = {for (final object in validObjects) object.id: object};
    final validItemIds = {...strokeIds, ...objectIds};
    final validContentGroups = <ContentGroup>[];
    for (final group in contentGroups) {
      final members = group.memberIds.where(validItemIds.contains).toList();
      if (members.length < 2 || !seen.add(group.id)) continue;
      Rect2? bounds;
      for (final memberId in members) {
        final memberBounds =
            strokeById[memberId]?.bounds ??
            objectById[memberId]?.transform.bounds;
        if (memberBounds != null) {
          bounds = bounds == null ? memberBounds : bounds.union(memberBounds);
        }
      }
      validContentGroups.add(
        group.copyWith(memberIds: members, bounds: bounds ?? group.bounds),
      );
    }
    final selectable = {
      ...validItemIds,
      ...validGroups.map((group) => group.id),
      ...validContentGroups.map((group) => group.id),
    };
    return copyWith(
      strokes: validStrokes,
      objects: validObjects,
      annotationLayers: validAnnotations,
      groups: validGroups,
      contentGroups: validContentGroups,
      selection: selection.copyWith(
        selectedItemIds: selection.selectedItemIds.where(selectable.contains),
      ),
    );
  }
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
       pages = List.unmodifiable(pages),
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
    final pageIds = this.pages.map((page) => page.id).toSet();
    if (pageIds.length != this.pages.length ||
        pageIds.any((id) => id.isEmpty)) {
      throw ArgumentError.value(
        pageIds,
        'pages',
        'Seiten-IDs müssen eindeutig und nicht leer sein',
      );
    }
  }

  factory WhiteboardDocument.create({
    required String id,
    String title = 'Unbenanntes Whiteboard',
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    return WhiteboardDocument(
      id: id,
      title: title,
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

  BoardPage get currentPage => pages[currentPageIndex];
  PenPreset get activePreset =>
      presets.where((preset) => preset.id == activePresetId).firstOrNull ??
      defaultPenPresets.first;

  BoardPage? pageById(String pageId) =>
      pages.where((page) => page.id == pageId).firstOrNull;

  WhiteboardDocument replacePage(BoardPage page, {DateTime? now}) {
    final index = pages.indexWhere((candidate) => candidate.id == page.id);
    if (index < 0) {
      throw StateError('Seite ${page.id} ist nicht Teil des Dokuments.');
    }
    final nextPages = pages.toList(growable: false);
    nextPages[index] = page;
    return copyWith(
      pages: nextPages,
      updatedAt: now ?? DateTime.now().toUtc(),
      revision: revision + 1,
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
  }) => WhiteboardDocument(
    id: id,
    title: title ?? this.title,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    pages: pages ?? this.pages,
    currentPageIndex: currentPageIndex ?? this.currentPageIndex,
    presets: presets ?? this.presets,
    activePresetId: activePresetId ?? this.activePresetId,
    assets: assets ?? this.assets,
    metadata: metadata ?? this.metadata,
    thumbnailAssetId: clearThumbnail
        ? null
        : thumbnailAssetId ?? this.thumbnailAssetId,
    revision: revision ?? this.revision,
  );

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
