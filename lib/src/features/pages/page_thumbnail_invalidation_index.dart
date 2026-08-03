import 'package:flutter/foundation.dart';

import '../../domain/model/board_object.dart';
import '../../domain/model/document.dart';

@immutable
final class PageThumbnailInvalidation {
  PageThumbnailInvalidation({
    required Iterable<String> dirtyPageIds,
    required Iterable<String> removedPageIds,
  }) : dirtyPageIds = Set<String>.unmodifiable(dirtyPageIds),
       removedPageIds = Set<String>.unmodifiable(removedPageIds);

  final Set<String> dirtyPageIds;
  final Set<String> removedPageIds;

  bool get isEmpty => dirtyPageIds.isEmpty && removedPageIds.isEmpty;
}

/// Tracks exactly which immutable page inputs can change a thumbnail.
///
/// Ordinary document revisions (viewport, selection, metadata, another page's
/// ink) compare only stable list identities. Object/asset walks are limited to
/// structurally changed pages, except for the rare case where the asset list
/// itself changed.
final class PageThumbnailInvalidationIndex {
  final Map<String, _PageThumbnailInput> _inputs =
      <String, _PageThumbnailInput>{};
  final Map<String, int> _revisions = <String, int>{};
  List<BoardPage>? _observedPages;
  List<DocumentAsset>? _observedAssets;
  Map<String, _AssetStamp> _assetStamps = const <String, _AssetStamp>{};
  int _nextRevision = 0;
  int _debugPageInspectionCount = 0;

  int? revisionFor(String pageId) => _revisions[pageId];
  @visibleForTesting
  int get debugPageInspectionCount => _debugPageInspectionCount;

  PageThumbnailInvalidation synchronize(WhiteboardDocument document) {
    final assetsChanged = !identical(_observedAssets, document.assets);
    if (assetsChanged) {
      _observedAssets = document.assets;
      _assetStamps = <String, _AssetStamp>{
        for (final asset in document.assets)
          asset.id: _AssetStamp.fromAsset(asset),
      };
    }

    final pages = document.pages;
    final previousPages = _observedPages;
    _observedPages = pages;
    if (!assetsChanged && identical(previousPages, pages)) {
      return PageThumbnailInvalidation(
        dirtyPageIds: const <String>{},
        removedPageIds: const <String>{},
      );
    }
    if (!assetsChanged &&
        previousPages != null &&
        pages is SingleReplacementModelList<BoardPage>) {
      final replacement = pages;
      final changedIndex = replacement.singleReplacementIndexFrom(
        previousPages,
      );
      if (changedIndex != null &&
          changedIndex >= 0 &&
          changedIndex < pages.length &&
          pages[changedIndex].id == previousPages[changedIndex].id) {
        final page = pages[changedIndex];
        _debugPageInspectionCount++;
        final previous = _inputs[page.id];
        final next = previous == null || !previous.matchesStructure(page)
            ? previous?.refreshStructure(page, _assetStamps) ??
                  _PageThumbnailInput.capture(page, _assetStamps)
            : previous;
        if (previous == next) {
          return PageThumbnailInvalidation(
            dirtyPageIds: const <String>{},
            removedPageIds: const <String>{},
          );
        }
        _inputs[page.id] = next;
        _revisions[page.id] = ++_nextRevision;
        return PageThumbnailInvalidation(
          dirtyPageIds: <String>{page.id},
          removedPageIds: const <String>{},
        );
      }
    }

    final liveIds = <String>{};
    final dirty = <String>{};
    for (final page in pages) {
      _debugPageInspectionCount++;
      liveIds.add(page.id);
      final previous = _inputs[page.id];
      final next = previous == null || !previous.matchesStructure(page)
          ? previous?.refreshStructure(
                  page,
                  _assetStamps,
                  refreshAssetStamps: assetsChanged,
                ) ??
                _PageThumbnailInput.capture(page, _assetStamps)
          : assetsChanged
          ? previous.refreshAssets(_assetStamps)
          : previous;
      if (previous == next) continue;
      _inputs[page.id] = next;
      _revisions[page.id] = ++_nextRevision;
      dirty.add(page.id);
    }

    final removed = <String>{};
    for (final pageId in _inputs.keys.toList(growable: false)) {
      if (liveIds.contains(pageId)) continue;
      _inputs.remove(pageId);
      _revisions.remove(pageId);
      removed.add(pageId);
    }
    return PageThumbnailInvalidation(
      dirtyPageIds: dirty,
      removedPageIds: removed,
    );
  }
}

final class _PageThumbnailInput {
  _PageThumbnailInput({
    required this.name,
    required this.strokes,
    required this.objects,
    required this.annotationLayers,
    required this.template,
    required this.assetIds,
    required this.assetStamps,
  });

  factory _PageThumbnailInput.capture(
    BoardPage page,
    Map<String, _AssetStamp> availableAssets,
  ) {
    final assetIds = _assetIdsFor(page.objects);
    return _PageThumbnailInput(
      name: page.name,
      strokes: page.strokes,
      objects: page.objects,
      annotationLayers: page.annotationLayers,
      template: page.template,
      assetIds: Set<String>.unmodifiable(assetIds),
      assetStamps: _stampsFor(assetIds, availableAssets),
    );
  }

  final String name;
  final Object strokes;
  final Object objects;
  final Object annotationLayers;
  final Object? template;
  final Set<String> assetIds;
  final Map<String, _AssetStamp?> assetStamps;

  bool matchesStructure(BoardPage page) =>
      name == page.name &&
      identical(strokes, page.strokes) &&
      identical(objects, page.objects) &&
      identical(annotationLayers, page.annotationLayers) &&
      identical(template, page.template);

  _PageThumbnailInput refreshAssets(Map<String, _AssetStamp> availableAssets) {
    final nextStamps = _stampsFor(assetIds, availableAssets);
    if (mapEquals(assetStamps, nextStamps)) return this;
    return _PageThumbnailInput(
      name: name,
      strokes: strokes,
      objects: objects,
      annotationLayers: annotationLayers,
      template: template,
      assetIds: assetIds,
      assetStamps: nextStamps,
    );
  }

  _PageThumbnailInput refreshStructure(
    BoardPage page,
    Map<String, _AssetStamp> availableAssets, {
    bool refreshAssetStamps = false,
  }) {
    final objectsUnchanged = identical(objects, page.objects);
    final nextAssetIds = objectsUnchanged
        ? assetIds
        : _assetIdsFor(page.objects);
    return _PageThumbnailInput(
      name: page.name,
      strokes: page.strokes,
      objects: page.objects,
      annotationLayers: page.annotationLayers,
      template: page.template,
      assetIds: nextAssetIds,
      assetStamps: objectsUnchanged && !refreshAssetStamps
          ? assetStamps
          : _stampsFor(nextAssetIds, availableAssets),
    );
  }
}

Set<String> _assetIdsFor(Iterable<BoardObject> objects) =>
    Set<String>.unmodifiable(<String>{
      for (final object in objects)
        if (object is ImageObject)
          object.assetId
        else if (object is PdfObject)
          object.assetId,
    });

Map<String, _AssetStamp?> _stampsFor(
  Iterable<String> assetIds,
  Map<String, _AssetStamp> availableAssets,
) => Map<String, _AssetStamp?>.unmodifiable(<String, _AssetStamp?>{
  for (final assetId in assetIds) assetId: availableAssets[assetId],
});

@immutable
final class _AssetStamp {
  const _AssetStamp({
    required this.relativePath,
    required this.byteLength,
    required this.sha256,
  });

  factory _AssetStamp.fromAsset(DocumentAsset asset) => _AssetStamp(
    relativePath: asset.relativePath,
    byteLength: asset.byteLength,
    sha256: asset.sha256,
  );

  final String relativePath;
  final int? byteLength;
  final String? sha256;

  @override
  bool operator ==(Object other) =>
      other is _AssetStamp &&
      other.relativePath == relativePath &&
      other.byteLength == byteLength &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(relativePath, byteLength, sha256);
}
