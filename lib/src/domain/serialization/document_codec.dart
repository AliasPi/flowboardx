import 'dart:convert';

import '../model/document.dart';

final class DocumentCodec {
  const DocumentCodec({this.prettyPrint = false});

  final bool prettyPrint;

  String encode(WhiteboardDocument document) {
    final encoder = prettyPrint
        ? const JsonEncoder.withIndent('  ')
        : const JsonEncoder();
    return encoder.convert(
      document.toJson(schemaVersion: DocumentMigrator.currentVersion),
    );
  }

  WhiteboardDocument decode(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException('Ungültiges Whiteboard-JSON: ${error.message}');
    }
    if (decoded is! Map) {
      throw const FormatException(
        'Die Dokumentwurzel muss ein JSON-Objekt sein.',
      );
    }
    return decodeMap(Map<String, Object?>.from(decoded));
  }

  WhiteboardDocument decodeMap(Map<String, Object?> source) {
    final migrated = const DocumentMigrator().migrate(source);
    try {
      return WhiteboardDocument.fromJson(migrated);
    } on FormatException {
      rethrow;
    } catch (error) {
      throw FormatException('Dokumentdaten sind inkonsistent: $error');
    }
  }
}

final class DocumentMigrator {
  const DocumentMigrator();

  static const currentVersion = 4;

  Map<String, Object?> migrate(Map<String, Object?> source) {
    var document = _deepMap(source);
    var version = _version(document['schemaVersion']);
    if (version > currentVersion) {
      throw FormatException(
        'Dokumentversion $version ist neuer als die unterstützte Version $currentVersion.',
      );
    }
    if (version < 1) version = 1;
    while (version < currentVersion) {
      document = switch (version) {
        1 => _fromV1ToV2(document),
        2 => _fromV2ToV3(document),
        3 => _fromV3ToV4(document),
        _ => throw FormatException(
          'Keine Migration für Dokumentversion $version.',
        ),
      };
      version = _version(document['schemaVersion']);
    }
    document['schemaVersion'] = currentVersion;
    return document;
  }

  Map<String, Object?> _fromV1ToV2(Map<String, Object?> source) {
    final result = _deepMap(source);
    result['currentPageIndex'] ??= result.remove('currentPage') ?? 0;
    result['revision'] ??= 0;
    result['assets'] ??= <Object?>[];
    result['metadata'] ??= <String, Object?>{};
    result['presets'] ??= <Object?>[];
    result['activePresetId'] ??= 'black';

    final pages = _mutableList(result['pages']);
    for (var index = 0; index < pages.length; index++) {
      final page = _asMutableMap(pages[index]);
      page['id'] ??= '${result['id'] ?? 'document'}_page_${index + 1}';
      page['name'] ??= 'Seite ${index + 1}';
      page['strokes'] ??= page.remove('ink') ?? <Object?>[];
      page['objects'] ??= page.remove('items') ?? <Object?>[];
      page['annotationLayers'] ??=
          page.remove('objectInkLayers') ?? <Object?>[];
      page['groups'] ??= <Object?>[];
      page['contentGroups'] ??= <Object?>[];
      page['selection'] ??= <String, Object?>{
        'selectedItemIds': <Object?>[],
        'mode': 'direct',
      };
      page['viewport'] = _migrateViewport(page['viewport']);
      pages[index] = page;
    }
    result['pages'] = pages;
    result['schemaVersion'] = 2;
    return result;
  }

  Map<String, Object?> _fromV2ToV3(Map<String, Object?> source) {
    final result = _deepMap(source);
    result['thumbnailAssetId'] ??= result.remove('documentThumbnail');

    final rawPresets = _mutableList(result['presets']);
    for (var index = 0; index < rawPresets.length; index++) {
      final preset = _asMutableMap(rawPresets[index]);
      preset['colorArgb'] = _color(
        preset['colorArgb'] ?? preset.remove('color'),
        0xFF000000,
      );
      preset['width'] ??= preset.remove('thickness') ?? 4;
      preset['type'] = _toolName(preset['type'] ?? preset.remove('tool'));
      rawPresets[index] = preset;
    }
    result['presets'] = rawPresets;

    final pages = _mutableList(result['pages']);
    for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final page = _asMutableMap(pages[pageIndex]);
      page['template'] ??= page.remove('templateInstance');
      page['annotationLayers'] ??=
          page.remove('objectInkLayers') ?? <Object?>[];
      page['contentGroups'] ??= <Object?>[];
      page['viewport'] = _migrateViewport(page['viewport']);

      final strokes = _mutableList(page['strokes']);
      for (var strokeIndex = 0; strokeIndex < strokes.length; strokeIndex++) {
        strokes[strokeIndex] = _migrateStroke(
          _asMutableMap(strokes[strokeIndex]),
        );
      }
      page['strokes'] = strokes;

      final objects = _mutableList(page['objects']);
      for (var objectIndex = 0; objectIndex < objects.length; objectIndex++) {
        objects[objectIndex] = _migrateObject(
          _asMutableMap(objects[objectIndex]),
        );
      }
      page['objects'] = objects;

      final annotations = _mutableList(page['annotationLayers']);
      for (var layerIndex = 0; layerIndex < annotations.length; layerIndex++) {
        final layer = _asMutableMap(annotations[layerIndex]);
        final layerStrokes = _mutableList(layer['strokes']);
        for (
          var strokeIndex = 0;
          strokeIndex < layerStrokes.length;
          strokeIndex++
        ) {
          layerStrokes[strokeIndex] = _migrateStroke(
            _asMutableMap(layerStrokes[strokeIndex]),
          );
        }
        layer['strokes'] = layerStrokes;
        annotations[layerIndex] = layer;
      }
      page['annotationLayers'] = annotations;
      pages[pageIndex] = page;
    }
    result['pages'] = pages;
    result['schemaVersion'] = 3;
    return result;
  }

  Map<String, Object?> _fromV3ToV4(Map<String, Object?> source) {
    final result = _deepMap(source);
    final pages = _mutableList(result['pages']);
    for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final page = _asMutableMap(pages[pageIndex]);
      final objects = _mutableList(page['objects']);
      final pdfs = <String, Map<String, Object?>>{};
      for (var objectIndex = 0; objectIndex < objects.length; objectIndex++) {
        final object = _asMutableMap(objects[objectIndex]);
        if (object['type']?.toString() == 'pdf') {
          object['placementMode'] ??= 'bundledObject';
          final id = object['id']?.toString();
          if (id != null && id.isNotEmpty) pdfs[id] = object;
        }
        objects[objectIndex] = object;
      }
      page['objects'] = objects;

      // Before schema 4 an object had at most one unspecific annotation layer.
      // Bind legacy PDF ink to the page that was visible when it was saved so
      // it does not suddenly appear on every page of a bundled PDF.
      final annotations = _mutableList(page['annotationLayers']);
      for (var layerIndex = 0; layerIndex < annotations.length; layerIndex++) {
        final layer = _asMutableMap(annotations[layerIndex]);
        if (layer['pdfPageIndex'] == null) {
          final pdf = pdfs[layer['objectId']?.toString()];
          if (pdf != null) {
            final indices = _mutableList(pdf['pageIndices']);
            final rawActive = pdf['activePageIndex'];
            final active =
                (rawActive is num
                        ? rawActive.toInt()
                        : int.tryParse(rawActive?.toString() ?? '') ?? 0)
                    .clamp(0, indices.isEmpty ? 0 : indices.length - 1);
            final sourceIndex = indices.isEmpty
                ? active
                : switch (indices[active]) {
                    final num value => value.toInt(),
                    final Object value =>
                      int.tryParse(value.toString()) ?? active,
                    null => active,
                  };
            layer['pdfPageIndex'] = sourceIndex;
          }
        }
        annotations[layerIndex] = layer;
      }
      page['annotationLayers'] = annotations;
      pages[pageIndex] = page;
    }
    result['pages'] = pages;
    result['schemaVersion'] = 4;
    return result;
  }

  Map<String, Object?> _migrateStroke(Map<String, Object?> stroke) {
    stroke['colorArgb'] = _color(
      stroke['colorArgb'] ?? stroke.remove('color'),
      0xFF000000,
    );
    stroke['width'] ??= stroke.remove('thickness') ?? 4;
    stroke['type'] = _toolName(stroke['type'] ?? stroke.remove('tool'));
    stroke['createdAt'] ??= DateTime.fromMillisecondsSinceEpoch(
      0,
      isUtc: true,
    ).toIso8601String();
    stroke['authorId'] ??= 'local';
    stroke['zIndex'] ??= 0;
    final points = _mutableList(stroke['points']);
    for (var index = 0; index < points.length; index++) {
      final point = _asMutableMap(points[index]);
      point['pressure'] ??= point.remove('p') ?? 1;
      point['timestampMicros'] ??= point.remove('t') ?? 0;
      point['tiltX'] ??= 0;
      point['tiltY'] ??= 0;
      points[index] = point;
    }
    stroke['points'] = points;
    return stroke;
  }

  Map<String, Object?> _migrateObject(Map<String, Object?> object) {
    var type = object['type']?.toString();
    if (type == null && object['kind'] != null) {
      type = 'shape';
      object['shape'] = object.remove('kind');
    }
    if ((type == 'shape' || type == 'geometry') &&
        object['shape'] == null &&
        object['kind'] != null) {
      object['shape'] = object.remove('kind');
    }
    object['type'] = switch (type) {
      'bitmap' => 'image',
      'document' => 'pdf',
      'geometry' => 'shape',
      _ => type,
    };
    if (object['transform'] is! Map) {
      object['transform'] = <String, Object?>{
        'x': object.remove('x') ?? 0,
        'y': object.remove('y') ?? 0,
        'width': object.remove('width') ?? 100,
        'height': object.remove('height') ?? 100,
      };
    }
    object['createdAt'] ??= DateTime.fromMillisecondsSinceEpoch(
      0,
      isUtc: true,
    ).toIso8601String();
    object['opacity'] ??= 1;
    object['locked'] ??= false;
    object['zIndex'] ??= 0;
    return object;
  }

  Map<String, Object?> _migrateViewport(Object? value) {
    final viewport = _asMutableMap(value);
    final position = viewport['position'];
    if (position is Map) {
      viewport['offsetX'] ??= position['x'];
      viewport['offsetY'] ??= position['y'];
    }
    viewport['offsetX'] ??= viewport.remove('x') ?? 0;
    viewport['offsetY'] ??= viewport.remove('y') ?? 0;
    viewport['zoom'] ??= viewport.remove('scale') ?? 1;
    viewport.remove('position');
    return viewport;
  }

  int _version(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 1;
  }

  int _color(Object? value, int fallback) {
    if (value is num) return value.toInt();
    if (value is! String) return fallback;
    var normalized = value.trim().replaceFirst('#', '');
    if (normalized.length == 6) normalized = 'FF$normalized';
    return int.tryParse(normalized, radix: 16) ?? fallback;
  }

  String _toolName(Object? value) => switch (value?.toString().toLowerCase()) {
    'pen' || 'normal' => 'normal',
    'highlighter' || 'marker' => 'marker',
    'dash' || 'dashed' => 'dashed',
    'line' || 'straightline' || 'straight_line' => 'straightLine',
    _ => 'normal',
  };
}

Map<String, Object?> _deepMap(Map source) =>
    source.map((key, value) => MapEntry(key.toString(), _deepValue(value)));

Object? _deepValue(Object? value) => switch (value) {
  Map() => _deepMap(value),
  List() => value.map(_deepValue).toList(),
  _ => value,
};

Map<String, Object?> _asMutableMap(Object? value) =>
    value is Map ? _deepMap(value) : <String, Object?>{};

List<Object?> _mutableList(Object? value) =>
    value is List ? value.map(_deepValue).toList() : <Object?>[];
