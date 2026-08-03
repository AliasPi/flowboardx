import 'dart:collection';
import 'dart:math' as math;

import 'geometry.dart';
import 'ink.dart';

enum BoardObjectType { shape, image, pdf, table, cover, text }

enum ShapeKind { rectangle, circle, ellipse, triangle }

enum ImageFitMode { contain, cover, fill }

enum PdfImportMode { singlePage, pageRange, wholeDocument }

/// Describes how selected source pages are materialized on the whiteboard.
///
/// This is deliberately independent from [PdfImportMode], which only records
/// how the source-page selection was made.
enum PdfPlacementMode { bundledObject, separateObjects, newWhiteboardPages }

enum RevealDirection { leftToRight, rightToLeft, topToBottom, bottomToTop }

enum BoardTextAlign { left, center, right }

sealed class BoardObject {
  BoardObject({
    required this.id,
    required this.transform,
    required this.zIndex,
    required this.opacity,
    required this.locked,
    required DateTime createdAt,
  }) : createdAt = createdAt.toUtc();

  final String id;
  final ObjectTransform transform;
  final int zIndex;
  final double opacity;
  final bool locked;
  final DateTime createdAt;

  BoardObjectType get type;

  BoardObject copyWithTransform(ObjectTransform transform);

  Map<String, Object?> toJson();

  Map<String, Object?> baseJson() => {
    'type': type.name,
    'id': id,
    'transform': transform.toJson(),
    'zIndex': zIndex,
    'opacity': opacity,
    'locked': locked,
    'createdAt': createdAt.toIso8601String(),
  };

  factory BoardObject.fromJson(Map<String, Object?> json) {
    final type = _enumByName(BoardObjectType.values, json['type'], null);
    return switch (type) {
      BoardObjectType.shape => ShapeObject.fromJson(json),
      BoardObjectType.image => ImageObject.fromJson(json),
      BoardObjectType.pdf => PdfObject.fromJson(json),
      BoardObjectType.table => TableObject.fromJson(json),
      BoardObjectType.cover => CoverObject.fromJson(json),
      BoardObjectType.text => TextObject.fromJson(json),
      null => throw FormatException('Unbekannter Objekttyp: ${json['type']}'),
    };
  }
}

final class ShapeObject extends BoardObject {
  ShapeObject({
    required super.id,
    required super.transform,
    this.shape = ShapeKind.rectangle,
    this.fillArgb = 0x00000000,
    this.strokeArgb = 0xFFEEEEEE,
    this.strokeWidth = 3,
    super.zIndex = 0,
    super.opacity = 1,
    super.locked = false,
    DateTime? createdAt,
  }) : super(createdAt: createdAt ?? DateTime.now().toUtc());

  final ShapeKind shape;
  final int fillArgb;
  final int strokeArgb;
  final double strokeWidth;

  @override
  BoardObjectType get type => BoardObjectType.shape;

  @override
  ShapeObject copyWithTransform(ObjectTransform transform) => ShapeObject(
    id: id,
    transform: transform,
    shape: shape,
    fillArgb: fillArgb,
    strokeArgb: strokeArgb,
    strokeWidth: strokeWidth,
    zIndex: zIndex,
    opacity: opacity,
    locked: locked,
    createdAt: createdAt,
  );

  @override
  Map<String, Object?> toJson() => {
    ...baseJson(),
    'shape': shape.name,
    'fillArgb': fillArgb,
    'strokeArgb': strokeArgb,
    'strokeWidth': strokeWidth,
  };

  factory ShapeObject.fromJson(Map<String, Object?> json) => ShapeObject(
    id: _string(json['id'], 'shape'),
    transform: _transform(json),
    shape: _enumByName(ShapeKind.values, json['shape'], ShapeKind.rectangle)!,
    fillArgb: _integer(json['fillArgb'], 0x00000000),
    strokeArgb: _integer(json['strokeArgb'], 0xFFEEEEEE),
    strokeWidth: math.max(0.1, _double(json['strokeWidth'], 3)),
    zIndex: _integer(json['zIndex'], 0),
    opacity: _double(json['opacity'], 1).clamp(0, 1),
    locked: _boolean(json['locked']),
    createdAt: _date(json['createdAt']),
  );
}

final class ImageObject extends BoardObject {
  ImageObject({
    required super.id,
    required super.transform,
    required this.assetId,
    this.originalFileName,
    this.fit = ImageFitMode.contain,
    this.altText,
    super.zIndex = 0,
    super.opacity = 1,
    super.locked = false,
    DateTime? createdAt,
  }) : super(createdAt: createdAt ?? DateTime.now().toUtc());

  final String assetId;
  final String? originalFileName;
  final ImageFitMode fit;
  final String? altText;

  @override
  BoardObjectType get type => BoardObjectType.image;

  @override
  ImageObject copyWithTransform(ObjectTransform transform) => ImageObject(
    id: id,
    transform: transform,
    assetId: assetId,
    originalFileName: originalFileName,
    fit: fit,
    altText: altText,
    zIndex: zIndex,
    opacity: opacity,
    locked: locked,
    createdAt: createdAt,
  );

  @override
  Map<String, Object?> toJson() => {
    ...baseJson(),
    'assetId': assetId,
    if (originalFileName != null) 'originalFileName': originalFileName,
    'fit': fit.name,
    if (altText != null) 'altText': altText,
  };

  factory ImageObject.fromJson(Map<String, Object?> json) => ImageObject(
    id: _string(json['id'], 'image'),
    transform: _transform(json),
    assetId: _string(json['assetId'], ''),
    originalFileName: _nullableString(json['originalFileName']),
    fit: _enumByName(ImageFitMode.values, json['fit'], ImageFitMode.contain)!,
    altText: _nullableString(json['altText']),
    zIndex: _integer(json['zIndex'], 0),
    opacity: _double(json['opacity'], 1).clamp(0, 1),
    locked: _boolean(json['locked']),
    createdAt: _date(json['createdAt']),
  );
}

final class PdfObject extends BoardObject {
  PdfObject({
    required super.id,
    required super.transform,
    required this.assetId,
    required Iterable<int> pageIndices,
    this.importMode = PdfImportMode.singlePage,
    this.placementMode = PdfPlacementMode.bundledObject,
    this.activePageIndex = 0,
    super.zIndex = 0,
    super.opacity = 1,
    super.locked = false,
    DateTime? createdAt,
  }) : pageIndices = List.unmodifiable(pageIndices),
       super(createdAt: createdAt ?? DateTime.now().toUtc());

  final String assetId;
  final List<int> pageIndices;
  final PdfImportMode importMode;
  final PdfPlacementMode placementMode;
  final int activePageIndex;

  int get activeSourcePageIndex => pageIndices.isEmpty
      ? math.max(0, activePageIndex)
      : pageIndices[activePageIndex.clamp(0, pageIndices.length - 1)];

  PdfObject copyWithActivePage(int index) => PdfObject(
    id: id,
    transform: transform,
    assetId: assetId,
    pageIndices: pageIndices,
    importMode: importMode,
    placementMode: placementMode,
    activePageIndex: index.clamp(0, math.max(0, pageIndices.length - 1)),
    zIndex: zIndex,
    opacity: opacity,
    locked: locked,
    createdAt: createdAt,
  );

  @override
  BoardObjectType get type => BoardObjectType.pdf;

  @override
  PdfObject copyWithTransform(ObjectTransform transform) => PdfObject(
    id: id,
    transform: transform,
    assetId: assetId,
    pageIndices: pageIndices,
    importMode: importMode,
    placementMode: placementMode,
    activePageIndex: activePageIndex,
    zIndex: zIndex,
    opacity: opacity,
    locked: locked,
    createdAt: createdAt,
  );

  @override
  Map<String, Object?> toJson() => {
    ...baseJson(),
    'assetId': assetId,
    'pageIndices': pageIndices,
    'importMode': importMode.name,
    'placementMode': placementMode.name,
    'activePageIndex': activePageIndex,
  };

  factory PdfObject.fromJson(Map<String, Object?> json) => PdfObject(
    id: _string(json['id'], 'pdf'),
    transform: _transform(json),
    assetId: _string(json['assetId'], ''),
    pageIndices: _intList(json['pageIndices']),
    importMode: _enumByName(
      PdfImportMode.values,
      json['importMode'],
      PdfImportMode.singlePage,
    )!,
    placementMode: _enumByName(
      PdfPlacementMode.values,
      json['placementMode'],
      PdfPlacementMode.bundledObject,
    )!,
    activePageIndex: math.max(0, _integer(json['activePageIndex'], 0)),
    zIndex: _integer(json['zIndex'], 0),
    opacity: _double(json['opacity'], 1).clamp(0, 1),
    locked: _boolean(json['locked']),
    createdAt: _date(json['createdAt']),
  );
}

final class TableCellData {
  const TableCellData({
    this.text = '',
    this.backgroundArgb = 0x00000000,
    this.textArgb = 0xFFEEEEEE,
    this.bold = false,
  });

  final String text;
  final int backgroundArgb;
  final int textArgb;
  final bool bold;

  Map<String, Object> toJson() => {
    'text': text,
    'backgroundArgb': backgroundArgb,
    'textArgb': textArgb,
    'bold': bold,
  };

  factory TableCellData.fromJson(Map<String, Object?> json) => TableCellData(
    text: json['text']?.toString() ?? '',
    backgroundArgb: _integer(json['backgroundArgb'], 0x00000000),
    textArgb: _integer(json['textArgb'], 0xFFEEEEEE),
    bold: _boolean(json['bold']),
  );
}

final class TableObject extends BoardObject {
  TableObject({
    required super.id,
    required super.transform,
    required this.rows,
    required this.columns,
    Map<String, TableCellData> cells = const {},
    this.gridColorArgb = 0xFFBDBDBD,
    this.gridWidth = 2,
    super.zIndex = 0,
    super.opacity = 1,
    super.locked = false,
    DateTime? createdAt,
  }) : assert(rows > 0 && columns > 0),
       cells = Map.unmodifiable(cells),
       super(createdAt: createdAt ?? DateTime.now().toUtc());

  final int rows;
  final int columns;

  /// Keys use the stable `row:column` form.
  final Map<String, TableCellData> cells;
  final int gridColorArgb;
  final double gridWidth;

  TableCellData cellAt(int row, int column) =>
      cells['$row:$column'] ?? const TableCellData();

  @override
  BoardObjectType get type => BoardObjectType.table;

  @override
  TableObject copyWithTransform(ObjectTransform transform) => TableObject(
    id: id,
    transform: transform,
    rows: rows,
    columns: columns,
    cells: cells,
    gridColorArgb: gridColorArgb,
    gridWidth: gridWidth,
    zIndex: zIndex,
    opacity: opacity,
    locked: locked,
    createdAt: createdAt,
  );

  @override
  Map<String, Object?> toJson() => {
    ...baseJson(),
    'rows': rows,
    'columns': columns,
    'cells': cells.map((key, value) => MapEntry(key, value.toJson())),
    'gridColorArgb': gridColorArgb,
    'gridWidth': gridWidth,
  };

  factory TableObject.fromJson(Map<String, Object?> json) => TableObject(
    id: _string(json['id'], 'table'),
    transform: _transform(json),
    rows: math.max(1, _integer(json['rows'], 1)),
    columns: math.max(1, _integer(json['columns'], 1)),
    cells: _cellMap(json['cells']),
    gridColorArgb: _integer(json['gridColorArgb'], 0xFFBDBDBD),
    gridWidth: math.max(0.1, _double(json['gridWidth'], 2)),
    zIndex: _integer(json['zIndex'], 0),
    opacity: _double(json['opacity'], 1).clamp(0, 1),
    locked: _boolean(json['locked']),
    createdAt: _date(json['createdAt']),
  );
}

final class CoverObject extends BoardObject {
  CoverObject({
    required super.id,
    required super.transform,
    this.direction = RevealDirection.leftToRight,
    this.reveal = 0,
    this.colorArgb = 0xFF424242,
    super.zIndex = 0,
    super.opacity = 1,
    super.locked = false,
    DateTime? createdAt,
  }) : super(createdAt: createdAt ?? DateTime.now().toUtc());

  final RevealDirection direction;
  final double reveal;
  final int colorArgb;

  @override
  BoardObjectType get type => BoardObjectType.cover;

  CoverObject copyWithReveal(double reveal) => CoverObject(
    id: id,
    transform: transform,
    direction: direction,
    reveal: reveal.clamp(0, 1),
    colorArgb: colorArgb,
    zIndex: zIndex,
    opacity: opacity,
    locked: locked,
    createdAt: createdAt,
  );

  @override
  CoverObject copyWithTransform(ObjectTransform transform) => CoverObject(
    id: id,
    transform: transform,
    direction: direction,
    reveal: reveal,
    colorArgb: colorArgb,
    zIndex: zIndex,
    opacity: opacity,
    locked: locked,
    createdAt: createdAt,
  );

  @override
  Map<String, Object?> toJson() => {
    ...baseJson(),
    'direction': direction.name,
    'reveal': reveal,
    'colorArgb': colorArgb,
  };

  factory CoverObject.fromJson(Map<String, Object?> json) => CoverObject(
    id: _string(json['id'], 'cover'),
    transform: _transform(json),
    direction: _enumByName(
      RevealDirection.values,
      json['direction'],
      RevealDirection.leftToRight,
    )!,
    reveal: _double(json['reveal'], 0).clamp(0, 1),
    colorArgb: _integer(json['colorArgb'], 0xFF424242),
    zIndex: _integer(json['zIndex'], 0),
    opacity: _double(json['opacity'], 1).clamp(0, 1),
    locked: _boolean(json['locked']),
    createdAt: _date(json['createdAt']),
  );
}

final class TextObject extends BoardObject {
  static const int currentLayoutVersion = 2;

  TextObject({
    required super.id,
    required super.transform,
    required this.text,
    this.fontSize = 28,
    this.colorArgb = 0xFFEEEEEE,
    this.bold = false,
    this.italic = false,
    this.alignment = BoardTextAlign.left,
    this.textLayoutVersion = currentLayoutVersion,
    Iterable<String> sourceStrokeIds = const [],
    super.zIndex = 0,
    super.opacity = 1,
    super.locked = false,
    DateTime? createdAt,
  }) : sourceStrokeIds = List.unmodifiable(sourceStrokeIds),
       super(createdAt: createdAt ?? DateTime.now().toUtc());

  final String text;
  final double fontSize;
  final int colorArgb;
  final bool bold;
  final bool italic;
  final BoardTextAlign alignment;
  final int textLayoutVersion;
  final List<String> sourceStrokeIds;

  TextObject copyWith({
    ObjectTransform? transform,
    String? text,
    double? fontSize,
    int? colorArgb,
    bool? bold,
    bool? italic,
    BoardTextAlign? alignment,
    int? textLayoutVersion,
    Iterable<String>? sourceStrokeIds,
    int? zIndex,
    double? opacity,
    bool? locked,
  }) => TextObject(
    id: id,
    transform: transform ?? this.transform,
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
    colorArgb: colorArgb ?? this.colorArgb,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    alignment: alignment ?? this.alignment,
    textLayoutVersion: textLayoutVersion ?? this.textLayoutVersion,
    sourceStrokeIds: sourceStrokeIds ?? this.sourceStrokeIds,
    zIndex: zIndex ?? this.zIndex,
    opacity: opacity ?? this.opacity,
    locked: locked ?? this.locked,
    createdAt: createdAt,
  );

  @override
  BoardObjectType get type => BoardObjectType.text;

  @override
  TextObject copyWithTransform(ObjectTransform transform) =>
      copyWith(transform: transform);

  @override
  Map<String, Object?> toJson() => {
    ...baseJson(),
    'text': text,
    'fontSize': fontSize,
    'colorArgb': colorArgb,
    'bold': bold,
    'italic': italic,
    'alignment': alignment.name,
    'textLayoutVersion': textLayoutVersion,
    'sourceStrokeIds': sourceStrokeIds,
  };

  factory TextObject.fromJson(Map<String, Object?> json) => TextObject(
    id: _string(json['id'], 'text'),
    transform: _transform(json),
    text: json['text']?.toString() ?? '',
    fontSize: math.max(1, _double(json['fontSize'], 28)),
    colorArgb: _integer(json['colorArgb'], 0xFFEEEEEE),
    bold: _boolean(json['bold']),
    italic: _boolean(json['italic']),
    alignment: _enumByName(
      BoardTextAlign.values,
      json['alignment'],
      BoardTextAlign.left,
    )!,
    textLayoutVersion: math.max(1, _integer(json['textLayoutVersion'], 1)),
    sourceStrokeIds: _stringList(json['sourceStrokeIds']),
    zIndex: _integer(json['zIndex'], 0),
    opacity: _double(json['opacity'], 1).clamp(0, 1),
    locked: _boolean(json['locked']),
    createdAt: _date(json['createdAt']),
  );
}

/// Ink stored in object-local coordinates; object transforms therefore also move
/// and scale all of its annotations without rewriting every point.
final class ObjectInkLayer {
  ObjectInkLayer({
    required this.id,
    required this.objectId,
    Iterable<InkStroke> strokes = const [],
    this.pdfPageIndex,
    this.visible = true,
  }) : strokes = _ChunkedAnnotationStrokeList<InkStroke>.from(strokes),
       _maximumZIndexCache = null;

  ObjectInkLayer._trusted({
    required this.id,
    required this.objectId,
    required this.strokes,
    required this.pdfPageIndex,
    required this.visible,
    required int? maximumZIndex,
  }) : _maximumZIndexCache = maximumZIndex;

  final String id;
  final String objectId;
  final List<InkStroke> strokes;

  /// Zero-based source page for PDF annotations. `null` means the object's
  /// single/general annotation layer (images, tables and legacy documents).
  final int? pdfPageIndex;
  final bool visible;
  int? _maximumZIndexCache;

  int get _maximumZIndex => _maximumZIndexCache ??= strokes.fold<int>(
    -1,
    (maximum, stroke) => stroke.zIndex > maximum ? stroke.zIndex : maximum,
  );

  /// Adds object-local ink without copying all preceding annotations retained
  /// by Undo/Redo. This is the annotation equivalent of the board's
  /// append-heavy stroke storage and is especially relevant for bundled PDFs,
  /// tables and images that receive many handwritten notes.
  ObjectInkLayer appendStroke(InkStroke stroke, {int? pdfPageIndex}) {
    final topmost = stroke.copyWith(zIndex: _maximumZIndex + 1);
    return ObjectInkLayer._trusted(
      id: id,
      objectId: objectId,
      strokes: _ChunkedAnnotationStrokeList<InkStroke>.from(
        strokes,
      ).appended(topmost),
      pdfPageIndex: pdfPageIndex ?? this.pdfPageIndex,
      visible: visible,
      maximumZIndex: topmost.zIndex,
    );
  }

  ObjectInkLayer copyWith({
    Iterable<InkStroke>? strokes,
    int? pdfPageIndex,
    bool clearPdfPageIndex = false,
    bool? visible,
  }) {
    final nextStrokes = strokes == null || identical(strokes, this.strokes)
        ? this.strokes
        : _ChunkedAnnotationStrokeList<InkStroke>.from(strokes);
    return ObjectInkLayer._trusted(
      id: id,
      objectId: objectId,
      strokes: nextStrokes,
      pdfPageIndex: clearPdfPageIndex
          ? null
          : pdfPageIndex ?? this.pdfPageIndex,
      visible: visible ?? this.visible,
      maximumZIndex: identical(nextStrokes, this.strokes)
          ? _maximumZIndexCache
          : null,
    );
  }

  /// Returns whether this layer was produced by appending exactly one stroke
  /// to [previous].
  ///
  /// Presentation caches use this strict ancestry check to update only their
  /// bounded tail picture. Length and value comparisons are deliberately not
  /// sufficient: erasing one stroke and adding another can otherwise look
  /// like an append and leave stale ink on screen.
  bool isSingleStrokeAppendOf(ObjectInkLayer previous) {
    if (id != previous.id ||
        objectId != previous.objectId ||
        pdfPageIndex != previous.pdfPageIndex ||
        visible != previous.visible ||
        strokes.length != previous.strokes.length + 1) {
      return false;
    }
    return strokes is _ChunkedAnnotationStrokeList<InkStroke> &&
        (strokes as _ChunkedAnnotationStrokeList<InkStroke>).isSingleAppendOf(
          previous.strokes,
        );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'objectId': objectId,
    if (pdfPageIndex != null) 'pdfPageIndex': pdfPageIndex,
    'strokes': strokes.map((stroke) => stroke.toJson()).toList(growable: false),
    'visible': visible,
  };

  factory ObjectInkLayer.fromJson(Map<String, Object?> json) => ObjectInkLayer(
    id: _string(json['id'], 'annotation'),
    objectId: _string(json['objectId'], ''),
    pdfPageIndex: json['pdfPageIndex'] is num
        ? math.max(0, (json['pdfPageIndex']! as num).toInt())
        : null,
    strokes: _mapList(json['strokes']).map(InkStroke.fromJson),
    visible: json['visible'] is bool ? json['visible']! as bool : true,
  );
}

/// Flat append-only immutable storage for annotation strokes.
///
/// It intentionally lives next to [ObjectInkLayer] so the model does not
/// depend on editor or persistence code. Random access and chronological
/// iteration stay constant-depth; an ordinary append copies at most 63
/// references instead of the complete annotation history.
final class _ChunkedAnnotationStrokeList<E> extends ListBase<E> {
  factory _ChunkedAnnotationStrokeList.from(Iterable<E> values) {
    if (values is _ChunkedAnnotationStrokeList<E>) return values;
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
    return _ChunkedAnnotationStrokeList<E>._(
      List<List<E>>.unmodifiable(chunks),
      List<E>.unmodifiable(tail),
      length,
      Object(),
      null,
    );
  }

  const _ChunkedAnnotationStrokeList._(
    this._chunks,
    this._tail,
    this._length,
    this._revision,
    this._parentRevision,
  );

  static const int _chunkSize = 64;
  final List<List<E>> _chunks;
  final List<E> _tail;
  final int _length;
  final Object _revision;
  final Object? _parentRevision;

  _ChunkedAnnotationStrokeList<E> appended(E value) {
    if (_tail.length < _chunkSize - 1) {
      return _ChunkedAnnotationStrokeList<E>._(
        _chunks,
        List<E>.unmodifiable(_tail.followedBy(<E>[value])),
        _length + 1,
        Object(),
        _revision,
      );
    }
    final completedTail = List<E>.unmodifiable(_tail.followedBy(<E>[value]));
    return _ChunkedAnnotationStrokeList<E>._(
      List<List<E>>.unmodifiable(_chunks.followedBy(<List<E>>[completedTail])),
      List<E>.empty(growable: false),
      _length + 1,
      Object(),
      _revision,
    );
  }

  bool isSingleAppendOf(List<E> previous) =>
      _length == previous.length + 1 &&
      previous is _ChunkedAnnotationStrokeList<E> &&
      identical(_parentRevision, previous._revision);

  @override
  int get length => _length;

  @override
  set length(int value) {
    throw UnsupportedError('Annotationen sind unveränderlich.');
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
    throw UnsupportedError('Annotationen sind unveränderlich.');
  }
}

/// Selects the annotation layer that belongs to the object's currently visible
/// content. For a bundled PDF this is the active source page; other objects use
/// their general layer. A legacy unscoped PDF layer remains a safe fallback.
ObjectInkLayer? activeObjectInkLayer(
  BoardObject object,
  Iterable<ObjectInkLayer> layers, {
  bool visibleOnly = true,
}) {
  ObjectInkLayer? legacy;
  final activePdfPage = object is PdfObject
      ? object.activeSourcePageIndex
      : null;
  for (final layer in layers) {
    if (layer.objectId != object.id || (visibleOnly && !layer.visible)) {
      continue;
    }
    if (layer.pdfPageIndex == activePdfPage) return layer;
    if (layer.pdfPageIndex == null) legacy ??= layer;
  }
  return legacy;
}

ObjectTransform _transform(Map<String, Object?> json) {
  final value = json['transform'];
  return value is Map
      ? ObjectTransform.fromJson(Map<String, Object?>.from(value))
      : ObjectTransform(
          x: _double(json['x'], 0),
          y: _double(json['y'], 0),
          width: math.max(0.001, _double(json['width'], 100)),
          height: math.max(0.001, _double(json['height'], 100)),
        );
}

T? _enumByName<T extends Enum>(List<T> values, Object? value, T? fallback) {
  final name = value?.toString();
  return values.where((candidate) => candidate.name == name).firstOrNull ??
      fallback;
}

double _double(Object? value, double fallback) {
  final result = value is num ? value.toDouble() : fallback;
  return result.isFinite ? result : fallback;
}

int _integer(Object? value, int fallback) =>
    value is num ? value.toInt() : fallback;
bool _boolean(Object? value) => value is bool && value;
String _string(Object? value, String fallback) =>
    value is String && value.isNotEmpty ? value : fallback;
String? _nullableString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;
DateTime _date(Object? value) =>
    DateTime.tryParse(value?.toString() ?? '')?.toUtc() ??
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

List<int> _intList(Object? value) => value is List
    ? List.unmodifiable(
        value.whereType<num>().map((item) => math.max(0, item.toInt())),
      )
    : const [];

List<String> _stringList(Object? value) =>
    value is List ? List.unmodifiable(value.whereType<String>()) : const [];

Iterable<Map<String, Object?>> _mapList(Object? value) sync* {
  if (value is! List) return;
  for (final item in value) {
    if (item is Map) yield Map<String, Object?>.from(item);
  }
}

Map<String, TableCellData> _cellMap(Object? value) {
  if (value is! Map) return const {};
  final result = <String, TableCellData>{};
  for (final entry in value.entries) {
    if (entry.value is Map) {
      result[entry.key.toString()] = TableCellData.fromJson(
        Map<String, Object?>.from(entry.value! as Map),
      );
    }
  }
  return result;
}
