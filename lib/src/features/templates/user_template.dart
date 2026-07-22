import '../../domain/model/board_object.dart';
import '../../domain/model/document.dart';

/// Metadata for one file owned by an application-global user template.
///
/// [relativePath] is always a single, generated file name inside the
/// template's private asset directory. It never points back into the source
/// document.
final class UserTemplateAsset {
  UserTemplateAsset({
    required String id,
    required this.type,
    required String relativePath,
    required String mimeType,
    this.originalFileName,
    required this.byteLength,
    required String sha256,
    DateTime? createdAt,
  }) : id = _requiredText(id, field: 'asset.id'),
       relativePath = _validatedFileName(relativePath),
       mimeType = _requiredText(mimeType, field: 'asset.mimeType'),
       sha256 = _validatedSha256(sha256),
       createdAt = (createdAt ?? DateTime.now().toUtc()).toUtc() {
    if (byteLength <= 0) {
      throw ArgumentError.value(
        byteLength,
        'asset.byteLength',
        'muss größer als null sein',
      );
    }
  }

  final String id;
  final DocumentAssetType type;
  final String relativePath;
  final String mimeType;
  final String? originalFileName;
  final int byteLength;
  final String sha256;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type.name,
    'relativePath': relativePath,
    'mimeType': mimeType,
    if (originalFileName != null) 'originalFileName': originalFileName,
    'byteLength': byteLength,
    'sha256': sha256,
    'createdAt': createdAt.toIso8601String(),
  };

  factory UserTemplateAsset.fromJson(Map<String, Object?> json) {
    final documentAsset = DocumentAsset.fromJson(json);
    final length = documentAsset.byteLength;
    final digest = documentAsset.sha256;
    if (length == null || digest == null) {
      throw const FormatException(
        'Länge oder Prüfsumme eines Vorlagen-Assets fehlt.',
      );
    }
    return UserTemplateAsset(
      id: documentAsset.id,
      type: documentAsset.type,
      relativePath: documentAsset.relativePath,
      mimeType: documentAsset.mimeType,
      originalFileName: documentAsset.originalFileName,
      byteLength: length,
      sha256: digest,
      createdAt: documentAsset.createdAt,
    );
  }
}

/// A page snapshot that is available to every document on this device.
final class UserTemplate {
  factory UserTemplate({
    required String id,
    required String name,
    required DateTime createdAt,
    required BoardPage page,
    Iterable<UserTemplateAsset> assets = const [],
  }) {
    final validatedAssets = _validatedAssets(assets);
    final availableAssetIds = validatedAssets.map((asset) => asset.id).toSet();
    for (final object in page.objects) {
      final assetId = switch (object) {
        final ImageObject image => image.assetId,
        final PdfObject pdf => pdf.assetId,
        _ => null,
      };
      if (assetId != null && !availableAssetIds.contains(assetId)) {
        throw ArgumentError.value(
          assetId,
          'page.objects',
          'verweist auf kein gespeichertes Vorlagen-Asset',
        );
      }
    }
    return UserTemplate._(
      id: _requiredText(id, field: 'id'),
      name: normalizeUserTemplateName(name),
      createdAt: createdAt.toUtc(),
      page: sanitizeUserTemplatePage(
        page,
        retainedAssetIds: validatedAssets.map((asset) => asset.id),
      ),
      assets: validatedAssets,
    );
  }

  const UserTemplate._({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.page,
    required this.assets,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final BoardPage page;
  final List<UserTemplateAsset> assets;

  /// Creates a fresh document page from this template.
  ///
  /// [assetIdMap] is supplied by [UserTemplateStore] after it has copied and
  /// verified every template file into the destination document.
  BoardPage createPage({
    required String pageId,
    String? pageName,
    Map<String, String> assetIdMap = const {},
  }) {
    final rebound = rebindUserTemplateAssetIds(page, assetIdMap);
    return sanitizeUserTemplatePage(
      rebound,
      pageId: _requiredText(pageId, field: 'pageId'),
      pageName: pageName == null
          ? name
          : _requiredText(pageName, field: 'pageName'),
      retainedAssetIds: assetIdMap.values,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'page': page.toJson(),
    'assets': assets.map((asset) => asset.toJson()).toList(growable: false),
  };

  factory UserTemplate.fromJson(Map<String, Object?> json) {
    final createdAtValue = json['createdAt'];
    if (createdAtValue is! String) {
      throw const FormatException('createdAt der Nutzervorlage fehlt.');
    }
    final createdAt = DateTime.tryParse(createdAtValue);
    if (createdAt == null) {
      throw const FormatException('createdAt der Nutzervorlage ist ungültig.');
    }

    final rawPage = json['page'];
    if (rawPage is! Map) {
      throw const FormatException('Die Seite der Nutzervorlage fehlt.');
    }
    final pageJson = Map<String, Object?>.from(rawPage);
    _requiredJsonText(pageJson, 'id', owner: 'Vorlagenseite');
    _requiredJsonText(pageJson, 'name', owner: 'Vorlagenseite');

    final rawAssets = json['assets'];
    final assets = rawAssets == null
        ? const <UserTemplateAsset>[]
        : rawAssets is List
        ? rawAssets
              .map((raw) {
                if (raw is! Map) {
                  throw const FormatException(
                    'Ein Vorlagen-Asset ist ungültig.',
                  );
                }
                return UserTemplateAsset.fromJson(
                  Map<String, Object?>.from(raw),
                );
              })
              .toList(growable: false)
        : throw const FormatException('Die Vorlagen-Assetliste ist ungültig.');

    return UserTemplate(
      id: _requiredJsonText(json, 'id', owner: 'Nutzervorlage'),
      name: _requiredJsonText(json, 'name', owner: 'Nutzervorlage'),
      createdAt: createdAt,
      page: BoardPage.fromJson(pageJson),
      assets: assets,
    );
  }
}

/// Removes document-transient state while retaining media backed by
/// [retainedAssetIds]. Media without a complete snapshot is removed so a
/// damaged or legacy template can never create dangling object references.
BoardPage sanitizeUserTemplatePage(
  BoardPage source, {
  String? pageId,
  String? pageName,
  Iterable<String> retainedAssetIds = const [],
}) {
  final sanitizedSource = source.sanitized();
  final availableAssets = retainedAssetIds.toSet();
  final retainedObjects = sanitizedSource.objects
      .where((object) {
        return switch (object) {
          final ImageObject image => availableAssets.contains(image.assetId),
          final PdfObject pdf => availableAssets.contains(pdf.assetId),
          _ => true,
        };
      })
      .toList(growable: false);
  final retainedObjectIds = retainedObjects.map((object) => object.id).toSet();
  final retainedAnnotations = sanitizedSource.annotationLayers
      .where((layer) => retainedObjectIds.contains(layer.objectId))
      .map(
        (layer) => layer.copyWith(
          strokes: layer.strokes.map(
            (stroke) => stroke.copyWith(clearPointerId: true),
          ),
        ),
      )
      .toList(growable: false);

  return sanitizedSource
      .copyWith(
        id: _requiredText(pageId ?? sanitizedSource.id, field: 'page.id'),
        name: _requiredText(
          pageName ?? sanitizedSource.name,
          field: 'page.name',
        ),
        viewport: const ViewportState(),
        strokes: sanitizedSource.strokes.map(
          (stroke) => stroke.copyWith(clearPointerId: true),
        ),
        objects: retainedObjects,
        annotationLayers: retainedAnnotations,
        selection: SelectionState.empty,
        clearTemplate: true,
        clearThumbnail: true,
      )
      .sanitized();
}

/// Rewrites only image/PDF asset references; object ids and their annotation
/// layers intentionally remain unchanged.
BoardPage rebindUserTemplateAssetIds(
  BoardPage page,
  Map<String, String> assetIdMap,
) {
  final objects = page.objects
      .map((object) {
        final sourceAssetId = switch (object) {
          final ImageObject image => image.assetId,
          final PdfObject pdf => pdf.assetId,
          _ => null,
        };
        if (sourceAssetId == null) return object;
        final targetAssetId = assetIdMap[sourceAssetId];
        if (targetAssetId == null) return object;
        final json = object.toJson()..['assetId'] = targetAssetId;
        return BoardObject.fromJson(json);
      })
      .toList(growable: false);
  return page.copyWith(objects: objects);
}

String normalizeUserTemplateName(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, 'name', 'darf nicht leer sein');
  }
  if (normalized.length > 120) {
    throw ArgumentError.value(
      value,
      'name',
      'darf höchstens 120 Zeichen enthalten',
    );
  }
  return normalized;
}

List<UserTemplateAsset> _validatedAssets(Iterable<UserTemplateAsset> assets) {
  final result = <UserTemplateAsset>[];
  final ids = <String>{};
  for (final asset in assets) {
    if (!ids.add(asset.id)) {
      throw ArgumentError.value(asset.id, 'assets', 'enthält doppelte IDs');
    }
    result.add(asset);
  }
  return List<UserTemplateAsset>.unmodifiable(result);
}

String _validatedFileName(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized == '.' ||
      normalized == '..' ||
      normalized.contains('/') ||
      normalized.contains('\\')) {
    throw ArgumentError.value(
      value,
      'asset.relativePath',
      'muss ein sicherer Dateiname sein',
    );
  }
  return normalized;
}

String _validatedSha256(String value) {
  final normalized = value.trim().toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
    throw ArgumentError.value(
      value,
      'asset.sha256',
      'muss eine SHA-256-Prüfsumme sein',
    );
  }
  return normalized;
}

String _requiredText(String value, {required String field}) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, field, 'darf nicht leer sein');
  }
  return normalized;
}

String _requiredJsonText(
  Map<String, Object?> json,
  String key, {
  required String owner,
}) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$owner enthält kein gültiges $key.');
  }
  return value;
}
