import 'dart:async';
import 'dart:convert';

import '../model/board_object.dart';
import '../model/document.dart';
import '../model/ink.dart';
import 'document_command.dart';

final class CommandHistory {
  static const String defaultOwnerId = 'default';

  CommandHistory(
    WhiteboardDocument initial, {
    this.maxDepth = 200,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _document = initial {
    if (maxDepth < 1) {
      throw ArgumentError.value(maxDepth, 'maxDepth', 'muss positiv sein');
    }
  }

  final int maxDepth;
  final DateTime Function() _clock;
  final List<_HistoryEntry> _entries = [];
  final Map<String, List<_HistoryEntry>> _undoStacks = {};
  final Map<String, List<_HistoryEntry>> _redoStacks = {};
  final StreamController<WhiteboardDocument> _changes =
      StreamController.broadcast(sync: true);
  WhiteboardDocument _document;
  bool _disposed = false;

  WhiteboardDocument get document => _document;
  bool get canUndo => canUndoFor(defaultOwnerId);
  bool get canRedo => canRedoFor(defaultOwnerId);
  int get undoDepth => undoDepthFor(defaultOwnerId);
  int get redoDepth => redoDepthFor(defaultOwnerId);
  Stream<WhiteboardDocument> get changes => _changes.stream;

  bool canUndoFor(String ownerId) => _stack(_undoStacks, ownerId).isNotEmpty;
  bool canRedoFor(String ownerId) => _stack(_redoStacks, ownerId).isNotEmpty;
  int undoDepthFor(String ownerId) => _stack(_undoStacks, ownerId).length;
  int redoDepthFor(String ownerId) => _stack(_redoStacks, ownerId).length;

  WhiteboardDocument execute(
    DocumentCommand command, {
    String ownerId = defaultOwnerId,
  }) {
    _ensureActive();
    final normalizedOwner = _normalizeOwnerId(ownerId);
    final before = _document;
    final candidate = command.apply(before);
    if (identical(candidate, before)) return _document;
    final after = _withMonotonicRevision(candidate, after: before);
    final entry = _HistoryEntry(command.label, normalizedOwner, before, after);
    _entries.add(entry);
    _stack(_undoStacks, normalizedOwner).add(entry);
    final abandonedRedo = _stack(_redoStacks, normalizedOwner);
    if (abandonedRedo.isNotEmpty) {
      _entries.removeWhere(abandonedRedo.contains);
      abandonedRedo.clear();
    }
    _trimToMaximumDepth();
    return _publish(after);
  }

  /// Applies persistent UI state (page/viewport) without consuming Undo/Redo.
  WhiteboardDocument executeUntracked(DocumentCommand command) {
    _ensureActive();
    final before = _document;
    final candidate = command.apply(before);
    if (identical(candidate, before)) return _document;
    return _publish(_withMonotonicRevision(candidate, after: before));
  }

  WhiteboardDocument undo({String ownerId = defaultOwnerId}) {
    _ensureActive();
    final normalizedOwner = _normalizeOwnerId(ownerId);
    final undoStack = _stack(_undoStacks, normalizedOwner);
    if (undoStack.isEmpty) return _document;
    final entry = undoStack.last;
    final restored = _applyTransition(
      current: _document,
      from: entry.after,
      to: entry.before,
    );
    final nextDocument = _withMonotonicRevision(restored, after: _document);
    undoStack.removeLast();
    _stack(_redoStacks, normalizedOwner).add(entry);
    return _publish(nextDocument);
  }

  WhiteboardDocument redo({String ownerId = defaultOwnerId}) {
    _ensureActive();
    final normalizedOwner = _normalizeOwnerId(ownerId);
    final redoStack = _stack(_redoStacks, normalizedOwner);
    if (redoStack.isEmpty) return _document;
    final entry = redoStack.last;
    final restored = _applyTransition(
      current: _document,
      from: entry.before,
      to: entry.after,
    );
    final nextDocument = _withMonotonicRevision(restored, after: _document);
    redoStack.removeLast();
    _stack(_undoStacks, normalizedOwner).add(entry);
    return _publish(nextDocument);
  }

  /// Replaces the loaded document and starts a fresh history boundary.
  void reset(WhiteboardDocument document) {
    _ensureActive();
    _document = document;
    _entries.clear();
    _undoStacks.clear();
    _redoStacks.clear();
    _changes.add(document);
  }

  void clear() {
    _ensureActive();
    _entries.clear();
    _undoStacks.clear();
    _redoStacks.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _changes.close();
  }

  WhiteboardDocument _publish(WhiteboardDocument document) {
    _document = document;
    _changes.add(document);
    return document;
  }

  WhiteboardDocument _withMonotonicRevision(
    WhiteboardDocument candidate, {
    required WhiteboardDocument after,
  }) {
    var timestamp = candidate.updatedAt;
    if (!timestamp.isAfter(after.updatedAt)) {
      final clockValue = _clock().toUtc();
      timestamp = clockValue.isAfter(after.updatedAt)
          ? clockValue
          : after.updatedAt.add(const Duration(microseconds: 1));
    }
    return candidate.copyWith(
      updatedAt: timestamp,
      revision: candidate.revision > after.revision
          ? candidate.revision
          : after.revision + 1,
    );
  }

  List<_HistoryEntry> _stack(
    Map<String, List<_HistoryEntry>> stacks,
    String ownerId,
  ) => stacks.putIfAbsent(_normalizeOwnerId(ownerId), () => <_HistoryEntry>[]);

  String _normalizeOwnerId(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, 'ownerId', 'darf nicht leer sein');
    }
    return normalized;
  }

  void _trimToMaximumDepth() {
    while (_entries.length > maxDepth) {
      final removed = _entries.removeAt(0);
      _undoStacks[removed.ownerId]?.remove(removed);
      _redoStacks[removed.ownerId]?.remove(removed);
    }
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('CommandHistory wurde bereits geschlossen.');
    }
  }
}

final class _HistoryEntry {
  const _HistoryEntry(this.label, this.ownerId, this.before, this.after);

  final String label;
  final String ownerId;
  final WhiteboardDocument before;
  final WhiteboardDocument after;
}

WhiteboardDocument _applyTransition({
  required WhiteboardDocument current,
  required WhiteboardDocument from,
  required WhiteboardDocument to,
}) {
  final currentPageId = current.currentPage.id;
  final pages = _mergeItems<BoardPage>(
    current: current.pages,
    from: from.pages,
    to: to.pages,
    idOf: (page) => page.id,
    same: _samePage,
    mergeModified: _mergePage,
  );
  if (pages.isEmpty) {
    // A valid command may never remove the final page. Treat malformed history
    // defensively and retain the current document instead of publishing an
    // invalid snapshot that would crash persistence and every listener.
    return current;
  }
  final matchingIndex = pages.indexWhere((page) => page.id == currentPageId);
  final fallbackIndex = current.currentPageIndex.clamp(0, pages.length - 1);
  final presets = _mergeItems<PenPreset>(
    current: current.presets,
    from: from.presets,
    to: to.presets,
    idOf: (preset) => preset.id,
    same: (left, right) => _sameEncoded(left, right, (value) => value.toJson()),
    mergeModified: _mergePreset,
  );
  final mergedAssets = _mergeItems<DocumentAsset>(
    current: current.assets,
    from: from.assets,
    to: to.assets,
    idOf: (asset) => asset.id,
    same: (left, right) => _sameEncoded(left, right, (value) => value.toJson()),
    mergeModified: _mergeAsset,
  );
  final thumbnailChanged = from.thumbnailAssetId != to.thumbnailAssetId;
  final nextThumbnail = thumbnailChanged
      ? current.thumbnailAssetId == from.thumbnailAssetId
            ? to.thumbnailAssetId
            : current.thumbnailAssetId
      : current.thumbnailAssetId;
  final assets = _retainReferencedAssets(
    merged: mergedAssets,
    current: current.assets,
    pages: pages,
    documentThumbnailAssetId: nextThumbnail,
  );
  return current.copyWith(
    title: from.title != to.title && current.title == from.title
        ? to.title
        : current.title,
    pages: pages,
    currentPageIndex: matchingIndex >= 0 ? matchingIndex : fallbackIndex,
    presets: presets,
    activePresetId:
        from.activePresetId != to.activePresetId &&
            current.activePresetId == from.activePresetId
        ? to.activePresetId
        : current.activePresetId,
    assets: assets,
    metadata: _mergeMetadata(current.metadata, from.metadata, to.metadata),
    thumbnailAssetId: nextThumbnail,
    clearThumbnail: thumbnailChanged && nextThumbnail == null,
  );
}

BoardPage _mergePage(BoardPage current, BoardPage from, BoardPage to) {
  final thumbnailChanged = from.thumbnailAssetId != to.thumbnailAssetId;
  final templateChanged = !_sameNullableJson(
    from.template?.toJson(),
    to.template?.toJson(),
  );
  final protectedItemIds = _foreignPersistentReferences(current, from);
  return current
      .copyWith(
        name: from.name != to.name && current.name == from.name
            ? to.name
            : current.name,
        // Viewports are navigation state and intentionally survive all content
        // undo/redo, including participant-scoped operations.
        viewport: current.viewport,
        strokes: _mergeItems<InkStroke>(
          current: current.strokes,
          from: from.strokes,
          to: to.strokes,
          idOf: (stroke) => stroke.id,
          same: (left, right) =>
              _sameEncoded(left, right, (value) => value.toJson()),
          mergeModified: _mergeStroke,
          canRemove: (stroke, _) => !protectedItemIds.contains(stroke.id),
        ),
        objects: _mergeItems<BoardObject>(
          current: current.objects,
          from: from.objects,
          to: to.objects,
          idOf: (object) => object.id,
          same: (left, right) =>
              _sameEncoded(left, right, (value) => value.toJson()),
          mergeModified: _mergeBoardObject,
          canRemove: (object, _) => !protectedItemIds.contains(object.id),
        ),
        annotationLayers: _mergeItems<ObjectInkLayer>(
          current: current.annotationLayers,
          from: from.annotationLayers,
          to: to.annotationLayers,
          idOf: (layer) => layer.id,
          same: (left, right) =>
              _sameEncoded(left, right, (value) => value.toJson()),
          mergeModified: _mergeAnnotationLayer,
        ),
        groups: _mergeItems<InkGroup>(
          current: current.groups,
          from: from.groups,
          to: to.groups,
          idOf: (group) => group.id,
          same: (left, right) =>
              _sameEncoded(left, right, (value) => value.toJson()),
          mergeModified: _mergeInkGroup,
        ),
        contentGroups: _mergeItems<ContentGroup>(
          current: current.contentGroups,
          from: from.contentGroups,
          to: to.contentGroups,
          idOf: (group) => group.id,
          same: (left, right) =>
              _sameEncoded(left, right, (value) => value.toJson()),
          mergeModified: _mergeContentGroup,
        ),
        selection:
            !_sameEncoded(
              from.selection,
              to.selection,
              (value) => value.toJson(),
            )
            ? _mergeSelection(current.selection, from.selection, to.selection)
            : current.selection,
        template:
            templateChanged &&
                _sameNullableJson(
                  current.template?.toJson(),
                  from.template?.toJson(),
                )
            ? to.template
            : current.template,
        clearTemplate:
            templateChanged &&
            to.template == null &&
            _sameNullableJson(
              current.template?.toJson(),
              from.template?.toJson(),
            ),
        thumbnailAssetId: thumbnailChanged
            ? current.thumbnailAssetId == from.thumbnailAssetId
                  ? to.thumbnailAssetId
                  : current.thumbnailAssetId
            : current.thumbnailAssetId,
        clearThumbnail:
            thumbnailChanged &&
            to.thumbnailAssetId == null &&
            current.thumbnailAssetId == from.thumbnailAssetId,
      )
      .sanitized();
}

ObjectInkLayer _mergeAnnotationLayer(
  ObjectInkLayer current,
  ObjectInkLayer from,
  ObjectInkLayer to,
) => ObjectInkLayer(
  id: current.id,
  objectId: current.objectId,
  pdfPageIndex: from.pdfPageIndex != to.pdfPageIndex
      ? current.pdfPageIndex == from.pdfPageIndex
            ? to.pdfPageIndex
            : current.pdfPageIndex
      : current.pdfPageIndex,
  visible: from.visible != to.visible && current.visible == from.visible
      ? to.visible
      : current.visible,
  strokes: _mergeItems<InkStroke>(
    current: current.strokes,
    from: from.strokes,
    to: to.strokes,
    idOf: (stroke) => stroke.id,
    same: (left, right) => _sameEncoded(left, right, (value) => value.toJson()),
    mergeModified: _mergeStroke,
  ),
);

DocumentMetadata _mergeMetadata(
  DocumentMetadata current,
  DocumentMetadata from,
  DocumentMetadata to,
) {
  final custom = Map<String, String>.from(current.custom);
  final keys = <String>{...from.custom.keys, ...to.custom.keys};
  for (final key in keys) {
    if (from.custom[key] == to.custom[key]) continue;
    if (current.custom[key] != from.custom[key]) continue;
    final target = to.custom[key];
    if (target == null) {
      custom.remove(key);
    } else {
      custom[key] = target;
    }
  }
  return DocumentMetadata(
    author: from.author != to.author && current.author == from.author
        ? to.author
        : current.author,
    deviceId: from.deviceId != to.deviceId && current.deviceId == from.deviceId
        ? to.deviceId
        : current.deviceId,
    recoveredFromCrash:
        from.recoveredFromCrash != to.recoveredFromCrash &&
            current.recoveredFromCrash == from.recoveredFromCrash
        ? to.recoveredFromCrash
        : current.recoveredFromCrash,
    lastOpenedAt:
        from.lastOpenedAt != to.lastOpenedAt &&
            current.lastOpenedAt == from.lastOpenedAt
        ? to.lastOpenedAt
        : current.lastOpenedAt,
    custom: custom,
  );
}

Set<String> _foreignPersistentReferences(BoardPage current, BoardPage from) {
  final protected = <String>{};
  final sourceLayers = <String, ObjectInkLayer>{
    for (final layer in from.annotationLayers) layer.id: layer,
  };
  for (final layer in current.annotationLayers) {
    final source = sourceLayers[layer.id];
    if (source == null ||
        !_sameEncoded(source, layer, (value) => value.toJson())) {
      protected.add(layer.objectId);
    }
  }
  final sourceGroups = <String, ContentGroup>{
    for (final group in from.contentGroups) group.id: group,
  };
  for (final group in current.contentGroups) {
    final source = sourceGroups[group.id];
    if (source == null ||
        !_sameEncoded(source, group, (value) => value.toJson())) {
      protected.addAll(group.memberIds);
    }
  }
  return protected;
}

List<DocumentAsset> _retainReferencedAssets({
  required List<DocumentAsset> merged,
  required List<DocumentAsset> current,
  required List<BoardPage> pages,
  required String? documentThumbnailAssetId,
}) {
  final referenced = <String>{
    ?documentThumbnailAssetId,
    for (final page in pages) ?page.thumbnailAssetId,
    for (final page in pages)
      for (final object in page.objects)
        if (object is ImageObject)
          object.assetId
        else if (object is PdfObject)
          object.assetId,
  };
  final result = merged.toList();
  final present = result.map((asset) => asset.id).toSet();
  for (final asset in current) {
    if (referenced.contains(asset.id) && present.add(asset.id)) {
      result.add(asset);
    }
  }
  return List<DocumentAsset>.unmodifiable(result);
}

InkStroke _mergeStroke(InkStroke current, InkStroke from, InkStroke to) {
  if (_sameEncoded(current, from, (value) => value.toJson())) return to;
  return InkStroke.fromJson(
    _mergeJsonObject(current.toJson(), from.toJson(), to.toJson()),
  );
}

BoardObject _mergeBoardObject(
  BoardObject current,
  BoardObject from,
  BoardObject to,
) {
  if (_sameEncoded(current, from, (value) => value.toJson())) return to;
  return BoardObject.fromJson(
    _mergeJsonObject(current.toJson(), from.toJson(), to.toJson()),
  );
}

InkGroup _mergeInkGroup(InkGroup current, InkGroup from, InkGroup to) {
  if (_sameEncoded(current, from, (value) => value.toJson())) return to;
  return InkGroup.fromJson(
    _mergeJsonObject(current.toJson(), from.toJson(), to.toJson()),
  );
}

ContentGroup _mergeContentGroup(
  ContentGroup current,
  ContentGroup from,
  ContentGroup to,
) {
  if (_sameEncoded(current, from, (value) => value.toJson())) return to;
  return ContentGroup.fromJson(
    _mergeJsonObject(current.toJson(), from.toJson(), to.toJson()),
  );
}

PenPreset _mergePreset(PenPreset current, PenPreset from, PenPreset to) {
  if (_sameEncoded(current, from, (value) => value.toJson())) return to;
  return PenPreset.fromJson(
    _mergeJsonObject(current.toJson(), from.toJson(), to.toJson()),
  );
}

DocumentAsset _mergeAsset(
  DocumentAsset current,
  DocumentAsset from,
  DocumentAsset to,
) {
  if (_sameEncoded(current, from, (value) => value.toJson())) return to;
  return DocumentAsset.fromJson(
    _mergeJsonObject(current.toJson(), from.toJson(), to.toJson()),
  );
}

SelectionState _mergeSelection(
  SelectionState current,
  SelectionState from,
  SelectionState to,
) {
  if (_sameEncoded(current, from, (value) => value.toJson())) return to;
  return SelectionState.fromJson(
    _mergeJsonObject(current.toJson(), from.toJson(), to.toJson()),
  );
}

/// Applies a three-way JSON transition without overwriting fields that no
/// longer equal [from]. Such fields were changed by a later participant and
/// therefore win over the older selective undo/redo operation.
Map<String, Object?> _mergeJsonObject(
  Map<String, Object?> current,
  Map<String, Object?> from,
  Map<String, Object?> to,
) {
  final result = Map<String, Object?>.from(current);
  final keys = <String>{...from.keys, ...to.keys};
  for (final key in keys) {
    final fromContains = from.containsKey(key);
    final toContains = to.containsKey(key);
    final currentContains = current.containsKey(key);
    final sourceValue = from[key];
    final targetValue = to[key];
    final currentValue = current[key];
    if (fromContains == toContains && _sameJson(sourceValue, targetValue)) {
      continue;
    }
    if (!toContains) {
      if (currentContains && _sameJson(currentValue, sourceValue)) {
        result.remove(key);
      }
      continue;
    }
    if (!fromContains) {
      if (!currentContains) result[key] = targetValue;
      continue;
    }
    if (_sameJson(currentValue, sourceValue)) {
      result[key] = targetValue;
      continue;
    }
    result[key] = _mergeConflictingJsonValue(
      key,
      currentValue,
      sourceValue,
      targetValue,
    );
  }
  return result;
}

Object? _mergeConflictingJsonValue(
  String key,
  Object? current,
  Object? from,
  Object? to,
) {
  if (current is Map && from is Map && to is Map) {
    return _mergeJsonObject(
      Map<String, Object?>.from(current),
      Map<String, Object?>.from(from),
      Map<String, Object?>.from(to),
    );
  }
  if (current is List &&
      from is List &&
      to is List &&
      current.length == from.length &&
      from.length == to.length) {
    return List<Object?>.generate(
      current.length,
      (index) => _mergeConflictingJsonValue(
        key,
        current[index],
        from[index],
        to[index],
      ),
      growable: false,
    );
  }
  if (current is num && from is num && to is num) {
    if (_multiplicativeNumericKeys.contains(key) && from != 0) {
      final value = current * (to / from);
      if (value.isFinite) return value;
    }
    if (_additiveNumericKeys.contains(key)) {
      final value = current + (to - from);
      if (!value.isFinite) return current;
      return current is int && from is int && to is int ? value.round() : value;
    }
  }
  // Strings, colors, enum indices and structurally incompatible lists are not
  // safely composable. The later participant's current value wins.
  return current;
}

const Set<String> _multiplicativeNumericKeys = <String>{
  'width',
  'height',
  'fontSize',
};

const Set<String> _additiveNumericKeys = <String>{
  'x',
  'y',
  'rotationRadians',
  'zIndex',
  'reveal',
  'opacity',
};

typedef _ItemMerger<T> = T Function(T current, T from, T to);
typedef _ItemRemovalGuard<T> = bool Function(T current, T from);

List<T> _mergeItems<T>({
  required List<T> current,
  required List<T> from,
  required List<T> to,
  required String Function(T item) idOf,
  required bool Function(T left, T right) same,
  _ItemMerger<T>? mergeModified,
  _ItemRemovalGuard<T>? canRemove,
}) {
  final fromById = <String, T>{for (final item in from) idOf(item): item};
  final toById = <String, T>{for (final item in to) idOf(item): item};
  final currentById = <String, T>{for (final item in current) idOf(item): item};
  final resolvedById = <String, T>{};
  final removedIds = <String>{};
  final additions = <String, T>{};
  final ids = <String>{...currentById.keys, ...fromById.keys, ...toById.keys};
  for (final id in ids) {
    final source = fromById[id];
    final target = toById[id];
    final currentItem = currentById[id];
    if (source != null && target != null && same(source, target)) continue;
    if (target == null) {
      if (currentItem != null &&
          source != null &&
          same(currentItem, source) &&
          (canRemove == null || canRemove(currentItem, source))) {
        removedIds.add(id);
      }
      continue;
    }
    if (currentItem != null) {
      if (source == null) {
        // An unrelated action has already claimed this supposedly new id.
        // Never overwrite it while replaying a participant redo.
        continue;
      }
      resolvedById[id] = mergeModified != null
          ? mergeModified(currentItem, source, target)
          : same(currentItem, source)
          ? target
          : currentItem;
      continue;
    }
    if (source != null) {
      // The item was modified by this entry but removed by a later foreign
      // action. Selective undo must not resurrect it.
      continue;
    }
    additions[id] = target;
  }

  final base = <T>[
    for (final item in current)
      if (!removedIds.contains(idOf(item))) resolvedById[idOf(item)] ?? item,
  ];
  if (additions.isEmpty) return List<T>.unmodifiable(base);

  final baseIds = base.map(idOf).toSet();
  final beforeAnchor = <String, List<T>>{};
  final afterAnchor = <String, List<T>>{};
  final unanchored = <T>[];
  var unanchoredInsertionIndex = 0;
  final pending = <T>[];
  String? previousAnchor;
  for (final targetItem in to) {
    final id = idOf(targetItem);
    final addition = additions[id];
    if (addition != null) {
      pending.add(addition);
      continue;
    }
    if (!baseIds.contains(id)) continue;
    if (pending.isNotEmpty) {
      beforeAnchor.putIfAbsent(id, () => <T>[]).addAll(pending);
      pending.clear();
    }
    previousAnchor = id;
  }
  if (pending.isNotEmpty) {
    if (previousAnchor == null) {
      unanchored.addAll(pending);
      final firstId = idOf(pending.first);
      final targetIndex = to.indexWhere((item) => idOf(item) == firstId);
      unanchoredInsertionIndex = targetIndex.clamp(0, base.length);
    } else {
      afterAnchor.putIfAbsent(previousAnchor, () => <T>[]).addAll(pending);
    }
  }

  final result = <T>[];
  for (final item in base) {
    final id = idOf(item);
    result
      ..addAll(beforeAnchor[id] ?? const [])
      ..add(item)
      ..addAll(afterAnchor[id] ?? const []);
  }
  if (unanchored.isNotEmpty) {
    result.insertAll(unanchoredInsertionIndex, unanchored);
  }
  return List<T>.unmodifiable(result);
}

bool _samePage(BoardPage left, BoardPage right) =>
    _sameEncoded(left, right, (value) => value.toJson());

bool _sameEncoded<T>(T left, T right, Object? Function(T value) encode) =>
    identical(left, right) || _sameJson(encode(left), encode(right));

bool _sameNullableJson(
  Map<String, Object?>? left,
  Map<String, Object?>? right,
) {
  if (left == null || right == null) return left == right;
  return _sameJson(left, right);
}

bool _sameJson(Object? left, Object? right) =>
    identical(left, right) || jsonEncode(left) == jsonEncode(right);
