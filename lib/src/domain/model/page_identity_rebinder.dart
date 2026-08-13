import 'board_object.dart';
import 'document.dart';
import 'ink.dart';

/// Clones one page while replacing every identity owned by that page.
///
/// Asset identities are resolved by the caller: pages duplicated inside one
/// document deliberately keep immutable image/PDF assets, whereas pages copied
/// into another document provide freshly copied asset IDs.
final class PageIdentityRebinder {
  PageIdentityRebinder({
    required Iterable<String> reservedIds,
    required String Function() newId,
  }) : _reservedIds = Set<String>.of(reservedIds),
       _newId = newId;

  final Set<String> _reservedIds;
  final String Function() _newId;

  BoardPage clone(
    BoardPage source, {
    String? name,
    required String Function(String sourceAssetId) resolveAssetId,
    String? Function(String sourceThumbnailAssetId)? resolveThumbnailAssetId,
  }) {
    final itemIds = <String, String>{};
    final strokes = <InkStroke>[];
    for (final stroke in source.strokes) {
      final id = _freshId('Strich');
      itemIds[stroke.id] = id;
      strokes.add(stroke.copyWith(id: id, clearPointerId: true));
    }

    final objects = <BoardObject>[];
    for (final object in source.objects) {
      final id = _freshId('Objekt');
      itemIds[object.id] = id;
      final json = Map<String, Object?>.from(object.toJson())..['id'] = id;
      switch (object) {
        case final ImageObject image:
          json['assetId'] = resolveAssetId(image.assetId);
        case final PdfObject pdf:
          json['assetId'] = resolveAssetId(pdf.assetId);
        case final TextObject text:
          json['sourceStrokeIds'] = text.sourceStrokeIds
              .map((sourceId) => itemIds[sourceId])
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
          id: _freshId('Anmerkung'),
          objectId: objectId,
          strokes: <InkStroke>[
            for (final stroke in layer.strokes)
              stroke.copyWith(
                id: _freshId('Anmerkungsstrich'),
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
          .map((sourceId) => itemIds[sourceId])
          .whereType<String>()
          .toList(growable: false);
      if (members.isEmpty) continue;
      groups.add(
        InkGroup(
          id: _freshId('Strichgruppe'),
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
          .map((sourceId) => itemIds[sourceId])
          .whereType<String>()
          .toList(growable: false);
      if (members.length < 2) continue;
      contentGroups.add(
        ContentGroup(
          id: _freshId('Inhaltsgruppe'),
          memberIds: members,
          bounds: group.bounds,
          locked: group.locked,
          createdAt: group.createdAt,
        ),
      );
    }

    final template = source.template;
    final thumbnailAssetId = source.thumbnailAssetId;
    return BoardPage(
      id: _freshId('Seite'),
      name: name ?? source.name,
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
              id: _freshId('Vorlage'),
              kind: template.kind,
              version: template.version,
              properties: template.properties,
            ),
      thumbnailAssetId:
          thumbnailAssetId == null || resolveThumbnailAssetId == null
          ? null
          : resolveThumbnailAssetId(thumbnailAssetId),
    );
  }

  String _freshId(String label) {
    for (var attempt = 0; attempt < 64; attempt++) {
      final candidate = _newId().trim();
      if (candidate.isNotEmpty && _reservedIds.add(candidate)) {
        return candidate;
      }
    }
    throw StateError('Für $label konnte keine eindeutige ID erzeugt werden.');
  }
}

/// All document-level identities which a page duplicate must not reuse.
Set<String> collectDocumentIdentityValues(WhiteboardDocument document) =>
    <String>{
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
