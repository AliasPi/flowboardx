import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../data/document_repository.dart';
import '../../domain/model/board_object.dart';
import '../../domain/model/document.dart';
import '../../domain/model/ink.dart';

/// Result of extracting selected pages into an independently persisted board.
final class CreatedPagesDocument {
  const CreatedPagesDocument({
    required this.document,
    required this.assetDirectory,
  });

  final WhiteboardDocument document;
  final Directory assetDirectory;
}

/// Creates a new whiteboard from an ordered page selection.
///
/// Every mutable identity is rebound, and only files referenced by the chosen
/// pages are copied. The destination document is saved only after all required
/// files have been copied and verified. A failed operation removes the complete
/// destination directory, so the library can never retain a half-created board.
final class SelectedPagesDocumentCreator {
  SelectedPagesDocumentCreator({Uuid? uuid, DateTime Function()? clock})
    : _uuid = uuid ?? const Uuid(),
      _clock = clock ?? DateTime.now;

  final Uuid _uuid;
  final DateTime Function() _clock;

  Future<CreatedPagesDocument> create({
    required WhiteboardDocument sourceDocument,
    required Directory sourceAssetDirectory,
    required List<String> selectedPageIds,
    required String title,
    required DocumentRepository repository,
  }) async {
    if (selectedPageIds.isEmpty) {
      throw const FormatException('Wähle mindestens eine Seite aus.');
    }
    if (selectedPageIds.length > WhiteboardDocument.maxPageCount) {
      throw FormatException(
        'Maximal ${WhiteboardDocument.maxPageCount} Seiten sind möglich.',
      );
    }
    if (selectedPageIds.toSet().length != selectedPageIds.length) {
      throw const FormatException(
        'Eine Seite darf nur einmal ausgewählt werden.',
      );
    }

    final selectedPages = <BoardPage>[];
    for (final pageId in selectedPageIds) {
      final page = sourceDocument.pageById(pageId);
      if (page == null) {
        throw FormatException(
          'Die ausgewählte Seite ist nicht mehr vorhanden.',
        );
      }
      selectedPages.add(page);
    }

    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw const FormatException('Der Dokumentname darf nicht leer sein.');
    }

    final usedIds = _allSourceIds(sourceDocument);
    usedIds.addAll((await repository.list()).map((summary) => summary.id));
    final destinationDocumentId = _freshId(usedIds, 'Dokument');
    Directory? destinationAssets;
    final materializedFiles = <File>[];
    try {
      destinationAssets = await repository.assetDirectory(
        destinationDocumentId,
      );
      final references = _collectAssetReferences(selectedPages);
      final reboundAssets = await _copyReferencedAssets(
        sourceDocument: sourceDocument,
        sourceDirectory: sourceAssetDirectory,
        destinationDirectory: destinationAssets,
        references: references,
        usedIds: usedIds,
        materializedFiles: materializedFiles,
      );

      final pages = <BoardPage>[
        for (final page in selectedPages)
          _clonePage(page, assetIds: reboundAssets.assetIds, usedIds: usedIds),
      ];
      final timestamp = _clock().toUtc();
      final document = WhiteboardDocument(
        id: destinationDocumentId,
        title: normalizedTitle,
        createdAt: timestamp,
        updatedAt: timestamp,
        pages: pages,
        presets: sourceDocument.presets,
        activePresetId: sourceDocument.activePresetId,
        assets: reboundAssets.assets,
        metadata: DocumentMetadata(
          author: sourceDocument.metadata.author,
          deviceId: sourceDocument.metadata.deviceId,
        ),
      );
      await repository.save(document);
      return CreatedPagesDocument(
        document: document,
        assetDirectory: destinationAssets,
      );
    } catch (error, stack) {
      for (final file in materializedFiles.reversed) {
        try {
          if (await file.exists()) await file.delete();
        } on Object {
          // The repository-level rollback below remains the final authority.
        }
      }
      try {
        await repository.delete(destinationDocumentId);
      } on Object {
        // Preserve the actionable source/copy/save failure.
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Set<String> _allSourceIds(WhiteboardDocument document) => <String>{
    document.id,
    for (final asset in document.assets) asset.id,
    for (final preset in document.presets) preset.id,
    for (final page in document.pages) ...<String>{
      page.id,
      if (page.template != null) page.template!.id,
      for (final stroke in page.strokes) stroke.id,
      for (final object in page.objects) object.id,
      for (final layer in page.annotationLayers) ...<String>{
        layer.id,
        for (final stroke in layer.strokes) stroke.id,
      },
      for (final group in page.groups) group.id,
      for (final group in page.contentGroups) group.id,
    },
  };

  _AssetReferences _collectAssetReferences(List<BoardPage> pages) {
    final required = <String>{};
    final thumbnails = <String>{};
    for (final page in pages) {
      final thumbnailId = page.thumbnailAssetId;
      if (thumbnailId != null && thumbnailId.isNotEmpty) {
        thumbnails.add(thumbnailId);
      }
      for (final object in page.objects) {
        switch (object) {
          case final ImageObject image:
            required.add(image.assetId);
          case final PdfObject pdf:
            required.add(pdf.assetId);
          default:
            break;
        }
      }
    }
    return _AssetReferences(required: required, thumbnails: thumbnails);
  }

  Future<_ReboundAssets> _copyReferencedAssets({
    required WhiteboardDocument sourceDocument,
    required Directory sourceDirectory,
    required Directory destinationDirectory,
    required _AssetReferences references,
    required Set<String> usedIds,
    required List<File> materializedFiles,
  }) async {
    final sourceById = <String, DocumentAsset>{
      for (final asset in sourceDocument.assets) asset.id: asset,
    };
    final missingRequired = references.required.where(
      (id) => !sourceById.containsKey(id),
    );
    if (missingRequired.isNotEmpty) {
      throw FormatException(
        'Eine benötigte Datei fehlt: ${missingRequired.join(', ')}',
      );
    }

    final allReferences = <String>{}
      ..addAll(references.required)
      ..addAll(references.thumbnails);
    final copiedAssets = <DocumentAsset>[];
    final assetIds = <String, String>{};
    for (final sourceId in allReferences) {
      final sourceAsset = sourceById[sourceId];
      if (sourceAsset == null) continue; // A stale thumbnail is disposable.
      try {
        final copied = await _copyAsset(
          sourceAsset: sourceAsset,
          sourceDirectory: sourceDirectory,
          destinationDirectory: destinationDirectory,
          usedIds: usedIds,
          materializedFiles: materializedFiles,
        );
        copiedAssets.add(copied);
        assetIds[sourceId] = copied.id;
      } catch (_) {
        if (references.required.contains(sourceId)) rethrow;
        // A thumbnail is only a cache. Clearing an unreadable one is safer
        // than rejecting otherwise intact selected content.
      }
    }
    return _ReboundAssets(assets: copiedAssets, assetIds: assetIds);
  }

  Future<DocumentAsset> _copyAsset({
    required DocumentAsset sourceAsset,
    required Directory sourceDirectory,
    required Directory destinationDirectory,
    required Set<String> usedIds,
    required List<File> materializedFiles,
  }) async {
    final source = await _resolveContainedSource(sourceDirectory, sourceAsset);
    final sourceLength = await source.length();
    if (sourceLength <= 0) {
      throw FileSystemException('Die Quelldatei ist leer.', source.path);
    }
    if (sourceAsset.byteLength != null &&
        sourceAsset.byteLength != sourceLength) {
      throw FormatException(
        'Die Größe der Quelldatei „${sourceAsset.originalFileName ?? sourceAsset.id}“ stimmt nicht.',
      );
    }

    final assetId = _freshId(usedIds, 'Asset');
    final extension = _safeExtension(
      sourceAsset.relativePath.isEmpty
          ? sourceAsset.originalFileName ?? ''
          : sourceAsset.relativePath,
    );
    final storedName = extension.isEmpty ? assetId : '$assetId$extension';
    final target = File(p.join(destinationDirectory.path, storedName));
    final temporary = File('${target.path}.importing');
    if (await target.exists() || await temporary.exists()) {
      throw FileSystemException(
        'Der Zielname für ein Asset ist bereits belegt.',
        target.path,
      );
    }

    try {
      await source.openRead().pipe(temporary.openWrite());
      final copiedLength = await temporary.length();
      final digest = (await sha256.bind(temporary.openRead()).first).toString();
      if (copiedLength != sourceLength ||
          (sourceAsset.sha256 != null &&
              sourceAsset.sha256!.toLowerCase() != digest)) {
        throw const FormatException(
          'Eine kopierte Datei stimmt nicht mit dem Original überein.',
        );
      }
      await temporary.rename(target.path);
      materializedFiles.add(target);
      return DocumentAsset(
        id: assetId,
        type: sourceAsset.type,
        relativePath: storedName,
        mimeType: sourceAsset.mimeType,
        originalFileName: sourceAsset.originalFileName,
        byteLength: copiedLength,
        sha256: digest,
        createdAt: _clock(),
      );
    } catch (_) {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on Object {
        // Repository rollback will remove any remaining temporary file.
      }
      try {
        if (await target.exists()) await target.delete();
        materializedFiles.remove(target);
      } on Object {
        // Repository rollback will remove any remaining final file.
      }
      rethrow;
    }
  }

  Future<File> _resolveContainedSource(
    Directory sourceDirectory,
    DocumentAsset asset,
  ) async {
    if (asset.relativePath.isEmpty || p.isAbsolute(asset.relativePath)) {
      throw const FormatException('Ungültiger Assetpfad im Quelldokument.');
    }
    final root = p.normalize(p.absolute(sourceDirectory.path));
    final candidate = p.normalize(p.absolute(root, asset.relativePath));
    if (!p.isWithin(root, candidate)) {
      throw const FormatException('Assetpfad verlässt das Quelldokument.');
    }
    final file = File(candidate);
    if (!await file.exists()) {
      throw FileSystemException('Quelldatei fehlt.', candidate);
    }

    // Lexical containment is not enough when a document directory contains a
    // symbolic link. Resolve both sides and reject links escaping the source.
    final resolvedRoot = p.normalize(
      await sourceDirectory.resolveSymbolicLinks(),
    );
    final resolvedFile = p.normalize(await file.resolveSymbolicLinks());
    if (!p.isWithin(resolvedRoot, resolvedFile)) {
      throw const FormatException(
        'Asset-Verknüpfung verlässt das Quelldokument.',
      );
    }
    return File(resolvedFile);
  }

  BoardPage _clonePage(
    BoardPage source, {
    required Map<String, String> assetIds,
    required Set<String> usedIds,
  }) {
    final itemIds = <String, String>{};
    final strokes = <InkStroke>[];
    for (final stroke in source.strokes) {
      final id = _freshId(usedIds, 'Strich');
      itemIds[stroke.id] = id;
      strokes.add(stroke.copyWith(id: id, clearPointerId: true));
    }

    final objects = <BoardObject>[];
    for (final object in source.objects) {
      final id = _freshId(usedIds, 'Objekt');
      itemIds[object.id] = id;
      final json = Map<String, Object?>.from(object.toJson())..['id'] = id;
      switch (object) {
        case final ImageObject image:
          json['assetId'] = _requiredReboundAsset(image.assetId, assetIds);
        case final PdfObject pdf:
          json['assetId'] = _requiredReboundAsset(pdf.assetId, assetIds);
        case final TextObject text:
          json['sourceStrokeIds'] = text.sourceStrokeIds
              .map((id) => itemIds[id])
              .whereType<String>()
              .toList(growable: false);
        default:
          break;
      }
      objects.add(BoardObject.fromJson(json));
    }

    final annotations = <ObjectInkLayer>[];
    for (final layer in source.annotationLayers) {
      final objectId = itemIds[layer.objectId];
      if (objectId == null) continue;
      annotations.add(
        ObjectInkLayer(
          id: _freshId(usedIds, 'Anmerkung'),
          objectId: objectId,
          strokes: [
            for (final stroke in layer.strokes)
              stroke.copyWith(
                id: _freshId(usedIds, 'Anmerkungsstrich'),
                clearPointerId: true,
              ),
          ],
          pdfPageIndex: layer.pdfPageIndex,
          visible: layer.visible,
        ),
      );
    }

    final groups = <InkGroup>[];
    for (final group in source.groups) {
      final members = group.strokeIds
          .map((id) => itemIds[id])
          .whereType<String>()
          .toList(growable: false);
      if (members.isEmpty) continue;
      groups.add(
        InkGroup(
          id: _freshId(usedIds, 'Strichgruppe'),
          kind: group.kind,
          strokeIds: members,
          bounds: group.bounds,
          createdAt: group.createdAt,
        ),
      );
    }

    final contentGroups = <ContentGroup>[];
    for (final group in source.contentGroups) {
      final members = group.memberIds
          .map((id) => itemIds[id])
          .whereType<String>()
          .toList(growable: false);
      if (members.length < 2) continue;
      contentGroups.add(
        ContentGroup(
          id: _freshId(usedIds, 'Inhaltsgruppe'),
          memberIds: members,
          bounds: group.bounds,
          locked: group.locked,
          createdAt: group.createdAt,
        ),
      );
    }

    final template = source.template;
    return BoardPage(
      id: _freshId(usedIds, 'Seite'),
      name: source.name,
      viewport: source.viewport,
      strokes: strokes,
      objects: objects,
      annotationLayers: annotations,
      groups: groups,
      contentGroups: contentGroups,
      selection: SelectionState.empty,
      template: template == null
          ? null
          : TemplateInstance(
              id: _freshId(usedIds, 'Vorlage'),
              kind: template.kind,
              version: template.version,
              properties: template.properties,
            ),
      thumbnailAssetId: source.thumbnailAssetId == null
          ? null
          : assetIds[source.thumbnailAssetId!],
    );
  }

  String _requiredReboundAsset(
    String sourceAssetId,
    Map<String, String> assetIds,
  ) {
    final rebound = assetIds[sourceAssetId];
    if (rebound == null) {
      throw FormatException('Eine benötigte Assetkopie fehlt: $sourceAssetId');
    }
    return rebound;
  }

  String _freshId(Set<String> used, String label) {
    for (var attempt = 0; attempt < 64; attempt++) {
      final candidate = _uuid.v4().trim();
      if (candidate.isNotEmpty && used.add(candidate)) return candidate;
    }
    throw StateError('Für $label konnte keine eindeutige ID erzeugt werden.');
  }

  String _safeExtension(String fileName) {
    final extension = p.extension(fileName).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension) ? extension : '';
  }
}

final class _AssetReferences {
  const _AssetReferences({required this.required, required this.thumbnails});

  final Set<String> required;
  final Set<String> thumbnails;
}

final class _ReboundAssets {
  const _ReboundAssets({required this.assets, required this.assetIds});

  final List<DocumentAsset> assets;
  final Map<String, String> assetIds;
}
