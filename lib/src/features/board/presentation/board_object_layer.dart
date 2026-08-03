import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../domain/model/board_object.dart';
import '../../../domain/model/geometry.dart';
import '../../../domain/model/ink.dart';
import '../../../domain/model/scene_order.dart';
import '../../assets/imported_image_layout.dart';
import '../../editor/text_object_layout.dart';
import 'ink_painter.dart';

abstract interface class BoardAssetResolver {
  Future<Uint8List?> readBytes(String assetId);
  String? localPath(String assetId);
}

final Expando<Rect2> _boardObjectBounds = Expando<Rect2>();
final Expando<Map<String, String?>> _assetPathsByResolver =
    Expando<Map<String, String?>>();

Rect2 _cachedBounds(BoardObject object) =>
    _boardObjectBounds[object] ??= object.transform.bounds;

bool _hasRenderableTransform(BoardObject object) {
  final transform = object.transform;
  return transform.x.isFinite &&
      transform.y.isFinite &&
      transform.width.isFinite &&
      transform.height.isFinite &&
      transform.width > 0 &&
      transform.height > 0 &&
      transform.rotationRadians.isFinite;
}

String? _cachedAssetPath(BoardAssetResolver assets, String assetId) {
  final paths = _assetPathsByResolver[assets] ??= <String, String?>{};
  if (paths.containsKey(assetId)) return paths[assetId];
  return paths[assetId] = assets.localPath(assetId);
}

class BoardObjectLayer extends StatefulWidget {
  const BoardObjectLayer({
    required this.objects,
    required this.annotationLayers,
    required this.scale,
    required this.offset,
    required this.assets,
    this.annotationIndex,
    this.selectedIds = const <String>{},
    this.worldClip,
    this.objectsAreSceneOrdered = false,
    super.key,
  });

  final List<BoardObject> objects;
  final List<ObjectInkLayer> annotationLayers;
  final double scale;
  final Offset offset;
  final BoardAssetResolver assets;
  final VisibleObjectInkLayerIndex? annotationIndex;
  final Set<String> selectedIds;
  final Rect2? worldClip;

  /// Skips the local z-order sort when [objects] already comes from
  /// [orderedBoardSceneItems].
  ///
  /// Board scene runs preserve their source order, so sorting them a second
  /// time on every viewport frame only creates avoidable lists and comparisons.
  final bool objectsAreSceneOrdered;

  @override
  State<BoardObjectLayer> createState() => _BoardObjectLayerState();
}

class _BoardObjectLayerState extends State<BoardObjectLayer> {
  static const int _maximumRetainedOffscreenPdfDocuments = 2;

  VisibleObjectInkLayerIndex? _ownedAnnotationIndex;
  final Map<String, _RetainedPdfDocument> _retainedPdfDocuments =
      <String, _RetainedPdfDocument>{};
  Map<String, PdfDocumentRefFile> _pdfReferencesByAssetId =
      const <String, PdfDocumentRefFile>{};

  @override
  void initState() {
    super.initState();
    _updateOwnedAnnotationIndex();
  }

  @override
  void didUpdateWidget(covariant BoardObjectLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.annotationLayers, widget.annotationLayers) ||
        !identical(oldWidget.annotationIndex, widget.annotationIndex)) {
      _updateOwnedAnnotationIndex();
    }
  }

  void _updateOwnedAnnotationIndex() {
    _ownedAnnotationIndex = widget.annotationIndex == null
        ? VisibleObjectInkLayerIndex(widget.annotationLayers)
        : null;
  }

  /// Keeps one lightweight listener per visible PDF source and a tiny
  /// recently-visible set.
  ///
  /// [PdfDocumentViewBuilder] otherwise releases the shared PDFium document as
  /// soon as an object leaves the viewport. Panning it back into view then
  /// reparses the complete file. The retained listener keeps only the source
  /// document alive; the much larger rendered page image still belongs to the
  /// visible [PdfPageView] and is disposed as soon as it is culled. Merely
  /// adding this listener does not load a never-visible source.
  void _syncRetainedPdfDocuments({
    required Set<String> availablePaths,
    required Map<String, String> visiblePathByAssetId,
  }) {
    final nextReferences = <String, PdfDocumentRefFile>{};
    final visiblePaths = visiblePathByAssetId.values.toSet();
    for (final entry in visiblePathByAssetId.entries) {
      final path = entry.value;
      // A remove/reinsert updates the insertion-ordered map's LRU position.
      final retained =
          _retainedPdfDocuments.remove(path) ?? _RetainedPdfDocument(path);
      _retainedPdfDocuments[path] = retained;
      nextReferences[entry.key] = retained.reference;
    }

    final unavailablePaths = _retainedPdfDocuments.keys
        .where((path) => !availablePaths.contains(path))
        .toList(growable: false);
    for (final path in unavailablePaths) {
      _retainedPdfDocuments.remove(path)?.dispose();
    }

    var offscreenCount = _retainedPdfDocuments.keys
        .where((path) => !visiblePaths.contains(path))
        .length;
    if (offscreenCount > _maximumRetainedOffscreenPdfDocuments) {
      final oldestPaths = _retainedPdfDocuments.keys.toList(growable: false);
      for (final path in oldestPaths) {
        if (visiblePaths.contains(path)) continue;
        _retainedPdfDocuments.remove(path)?.dispose();
        offscreenCount--;
        if (offscreenCount <= _maximumRetainedOffscreenPdfDocuments) break;
      }
    }
    _pdfReferencesByAssetId = Map<String, PdfDocumentRefFile>.unmodifiable(
      nextReferences,
    );
  }

  @override
  void dispose() {
    for (final retained in _retainedPdfDocuments.values) {
      retained.dispose();
    }
    _retainedPdfDocuments.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final annotationIndex = widget.annotationIndex ?? _ownedAnnotationIndex!;
    final visibleObjects = <BoardObject>[];
    final availablePdfPaths = <String>{};
    final visiblePdfPathByAssetId = <String, String>{};
    for (final object in widget.objects) {
      if (!_hasRenderableTransform(object)) continue;
      String? pdfPath;
      if (object is PdfObject) {
        pdfPath = _cachedAssetPath(widget.assets, object.assetId);
        if (pdfPath != null && pdfPath.isNotEmpty) {
          availablePdfPaths.add(pdfPath);
        }
      }
      final isVisible =
          object.opacity > 0 &&
          (widget.worldClip == null ||
              _cachedBounds(object).intersects(widget.worldClip!));
      if (!isVisible) continue;
      visibleObjects.add(object);
      if (object is PdfObject && pdfPath != null && pdfPath.isNotEmpty) {
        visiblePdfPathByAssetId[object.assetId] = pdfPath;
      }
    }
    _syncRetainedPdfDocuments(
      availablePaths: availablePdfPaths,
      visiblePathByAssetId: visiblePdfPathByAssetId,
    );
    final sorted = widget.objectsAreSceneOrdered || visibleObjects.length < 2
        ? visibleObjects
        : orderedBoardSceneItems(
            objects: visibleObjects,
            strokes: const [],
          ).map((item) => item.object!).toList(growable: false);
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        for (final object in sorted)
          _buildPositionedObject(
            object,
            annotationIndex.layerFor(object),
            object is PdfObject
                ? _pdfReferencesByAssetId[object.assetId]
                : null,
          ),
      ],
    );
  }

  Widget _buildPositionedObject(
    BoardObject object,
    ObjectInkLayer? annotationLayer,
    PdfDocumentRefFile? pdfDocumentRef,
  ) {
    Widget content = _ObjectBody(
      object: object,
      assets: widget.assets,
      displayScale: widget.scale,
      pdfDocumentRef: pdfDocumentRef,
    );
    if (annotationLayer != null) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          content,
          _ObjectAnnotationBody(
            key: ValueKey<String>('board-annotation-${object.id}'),
            layer: annotationLayer,
            logicalSize: Size(object.transform.width, object.transform.height),
          ),
        ],
      );
    }
    if (object.opacity < 1) {
      content = Opacity(opacity: object.opacity, child: content);
    }
    content = IgnorePointer(child: content);
    final screenSize = Size(
      object.transform.width * widget.scale,
      object.transform.height * widget.scale,
    );
    if (boardObjectShouldIsolateRepaint(screenSize)) {
      content = RepaintBoundary(child: content);
    }
    if (object.transform.flipX || object.transform.flipY) {
      content = Transform.flip(
        flipX: object.transform.flipX,
        flipY: object.transform.flipY,
        child: content,
      );
    }
    if (object.transform.rotationRadians.abs() >= 0.0000001) {
      content = Transform.rotate(
        angle: object.transform.rotationRadians,
        alignment: Alignment.center,
        child: content,
      );
    }
    return Positioned(
      key: ValueKey('board-object-${object.id}'),
      left: widget.offset.dx + object.transform.x * widget.scale,
      top: widget.offset.dy + object.transform.y * widget.scale,
      width: object.transform.width * widget.scale,
      height: object.transform.height * widget.scale,
      child: content,
    );
  }
}

/// Large imported or aggressively zoomed objects must not own one enormous
/// retained raster layer.
///
/// They remain clipped by the board surface and keep their own vector/image
/// caches, but participate in the surrounding scene paint until their screen
/// footprint is small enough to isolate safely.
@visibleForTesting
bool boardObjectShouldIsolateRepaint(Size screenSize) =>
    screenSize.width.isFinite &&
    screenSize.height.isFinite &&
    screenSize.width > 0 &&
    screenSize.height > 0 &&
    screenSize.width <= _maximumIsolatedObjectExtent &&
    screenSize.height <= _maximumIsolatedObjectExtent &&
    screenSize.width * screenSize.height <= _maximumIsolatedObjectArea;

const double _maximumIsolatedObjectExtent = 2048;
const double _maximumIsolatedObjectArea = 2 * 1024 * 1024;

final class _RetainedPdfDocument {
  _RetainedPdfDocument(String path) : reference = PdfDocumentRefFile(path) {
    _release = reference.resolveListenable().addListener(_keepAlive);
  }

  final PdfDocumentRefFile reference;
  late final VoidCallback _release;

  void _keepAlive() {}

  void dispose() => _release();
}

/// Immutable O(1) lookup for the visible annotation attached to an object.
///
/// Input order is significant: duplicate legacy or page-specific layers retain
/// the first match, exactly like [activeObjectInkLayer]. A PDF first attempts
/// its active source page and then falls back to its first unscoped legacy
/// layer. Other object types use only that unscoped layer.
class VisibleObjectInkLayerIndex {
  VisibleObjectInkLayerIndex(Iterable<ObjectInkLayer> layers) {
    for (final layer in layers) {
      if (!layer.visible) continue;
      final pageIndex = layer.pdfPageIndex;
      if (pageIndex == null) {
        _legacyByObject.putIfAbsent(layer.objectId, () => layer);
        continue;
      }
      (_pageLayersByObject[layer.objectId] ??= <int, ObjectInkLayer>{})
          .putIfAbsent(pageIndex, () => layer);
    }
  }

  final Map<String, ObjectInkLayer> _legacyByObject =
      <String, ObjectInkLayer>{};
  final Map<String, Map<int, ObjectInkLayer>> _pageLayersByObject =
      <String, Map<int, ObjectInkLayer>>{};

  ObjectInkLayer? layerFor(BoardObject object) {
    if (object is PdfObject) {
      final exact =
          _pageLayersByObject[object.id]?[object.activeSourcePageIndex];
      if (exact != null) return exact;
    }
    return _legacyByObject[object.id];
  }
}

class _ObjectBody extends StatelessWidget {
  const _ObjectBody({
    required this.object,
    required this.assets,
    required this.displayScale,
    required this.pdfDocumentRef,
  });

  final BoardObject object;
  final BoardAssetResolver assets;
  final double displayScale;
  final PdfDocumentRefFile? pdfDocumentRef;

  @override
  Widget build(BuildContext context) => switch (object) {
    final ShapeObject shape => CustomPaint(painter: _ShapePainter(shape)),
    final ImageObject image => _ImageBody(
      image: image,
      assets: assets,
      displayScale: displayScale,
    ),
    final PdfObject pdf => _PdfBody(pdf: pdf, documentRef: pdfDocumentRef),
    final TableObject table => CustomPaint(painter: _TablePainter(table)),
    final CoverObject cover => CustomPaint(painter: _CoverPainter(cover)),
    final TextObject text => _TextBody(text, displayScale: displayScale),
  };
}

typedef _ValidatedBoardImageAsset = ({String? path, Uint8List? bytes});

/// Asset IDs are immutable inside one resolver. Sharing the validation future
/// prevents every viewport cull/re-entry (and every duplicate image object)
/// from reading and probing the same encoded file again. Expando ownership
/// means the complete cache becomes collectible with the document resolver.
final Expando<Map<String, Future<_ValidatedBoardImageAsset?>>>
_validatedImageAssetsByResolver =
    Expando<Map<String, Future<_ValidatedBoardImageAsset?>>>();

Future<_ValidatedBoardImageAsset?> _validatedImageAsset(
  BoardAssetResolver assets,
  String assetId,
) {
  final cache = _validatedImageAssetsByResolver[assets] ??=
      <String, Future<_ValidatedBoardImageAsset?>>{};
  return cache.putIfAbsent(
    assetId,
    () => _loadValidatedImageAsset(assets, assetId),
  );
}

Future<_ValidatedBoardImageAsset?> _loadValidatedImageAsset(
  BoardAssetResolver assets,
  String assetId,
) async {
  try {
    final path = _cachedAssetPath(assets, assetId);
    if (path != null) {
      await ImportedImageLayout.dimensionsFromFile(path);
      return (path: path, bytes: null);
    }
    final bytes = await assets.readBytes(assetId);
    if (bytes == null) return null;
    await ImportedImageLayout.dimensionsFromBytes(bytes);
    return (path: null, bytes: bytes);
  } on ImportedImageValidationException {
    return null;
  } on FileSystemException {
    return null;
  }
}

class _ImageBody extends StatefulWidget {
  const _ImageBody({
    required this.image,
    required this.assets,
    required this.displayScale,
  });

  final ImageObject image;
  final BoardAssetResolver assets;
  final double displayScale;

  @override
  State<_ImageBody> createState() => _ImageBodyState();
}

class _ImageBodyState extends State<_ImageBody> {
  late Future<_ValidatedBoardImageAsset?> _validatedAsset =
      _validatedImageAsset(widget.assets, widget.image.assetId);

  @override
  void didUpdateWidget(covariant _ImageBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.assetId != widget.image.assetId ||
        oldWidget.assets != widget.assets) {
      _validatedAsset = _validatedImageAsset(
        widget.assets,
        widget.image.assetId,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.image;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final requestedWidth =
        image.transform.width * widget.displayScale * pixelRatio;
    final requestedHeight =
        image.transform.height * widget.displayScale * pixelRatio;
    final decodeSize = Size(
      requestedWidth.isFinite ? requestedWidth : 512,
      requestedHeight.isFinite ? requestedHeight : 512,
    );
    return FutureBuilder<_ValidatedBoardImageAsset?>(
      future: _validatedAsset,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const _ImageFailurePlaceholder();
        if (snapshot.connectionState != ConnectionState.done) {
          return const _ImageLoadingPlaceholder();
        }
        final asset = snapshot.data;
        if (asset == null) return const _ImageFailurePlaceholder();
        final ImageProvider<Object> provider = asset.path != null
            ? FileImage(File(asset.path!))
            : MemoryImage(asset.bytes!);
        return Image(
          image: ImportedImageLayout.aspectPreservingProvider(
            provider,
            physicalSize: decodeSize,
          ),
          fit: _boxFit(image.fit),
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => const _ImageFailurePlaceholder(),
        );
      },
    );
  }
}

class _ImageLoadingPlaceholder extends StatelessWidget {
  const _ImageLoadingPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0x1A647078),
    child: Center(
      child: Icon(Icons.image_outlined, color: Color(0xFF647078), size: 42),
    ),
  );
}

class _ImageFailurePlaceholder extends StatelessWidget {
  const _ImageFailurePlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFFE7E9E8),
    child: Center(
      child: Icon(Icons.broken_image_outlined, color: Color(0xFF647078)),
    ),
  );
}

BoxFit _boxFit(ImageFitMode fit) => switch (fit) {
  ImageFitMode.contain => BoxFit.contain,
  ImageFitMode.cover => BoxFit.cover,
  ImageFitMode.fill => BoxFit.fill,
};

class _PdfBody extends StatelessWidget {
  const _PdfBody({required this.pdf, required this.documentRef});

  final PdfObject pdf;
  final PdfDocumentRefFile? documentRef;

  @override
  Widget build(BuildContext context) {
    if (documentRef == null) {
      return const ColoredBox(
        color: Color(0xFFF0F0EE),
        child: Center(
          child: Icon(Icons.picture_as_pdf, color: Color(0xFFD04444), size: 48),
        ),
      );
    }
    final requested = pdf.pageIndices.isEmpty
        ? pdf.activePageIndex + 1
        : pdf.pageIndices[pdf.activePageIndex.clamp(
                0,
                pdf.pageIndices.length - 1,
              )] +
              1;
    return _QuantizedPdfPage(
      pdf: pdf,
      documentRef: documentRef!,
      requestedPageNumber: requested,
    );
  }
}

/// Coarsens PDFium render targets while a viewport pinch is in progress.
///
/// PdfPageView keys its native raster by the exact layout size. Without a
/// stable tier, every sub-pixel zoom update cancels the in-flight PDFium job,
/// allocates another bitmap and starts again. Tiers always round upward, so
/// the page is never deliberately rendered below the requested resolution.
@visibleForTesting
double boardObjectRasterScaleTier(double scale) {
  if (!scale.isFinite || scale <= 0) return 1;
  for (final tier in const <double>[
    .25,
    .375,
    .5,
    .75,
    1,
    1.5,
    2,
    3,
    4,
    6,
    8,
    12,
    16,
  ]) {
    if (scale <= tier) return tier;
  }
  return 16;
}

class _QuantizedPdfPage extends StatelessWidget {
  const _QuantizedPdfPage({
    required this.pdf,
    required this.documentRef,
    required this.requestedPageNumber,
  });

  final PdfObject pdf;
  final PdfDocumentRefFile documentRef;
  final int requestedPageNumber;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        final viewportHeight = constraints.maxHeight;
        final logicalWidth = pdf.transform.width;
        final logicalHeight = pdf.transform.height;
        final scaleX =
            viewportWidth.isFinite && logicalWidth.isFinite && logicalWidth > 0
            ? viewportWidth / logicalWidth
            : 1.0;
        final scaleY =
            viewportHeight.isFinite &&
                logicalHeight.isFinite &&
                logicalHeight > 0
            ? viewportHeight / logicalHeight
            : 1.0;
        final rasterScale = boardObjectRasterScaleTier(
          math.max(scaleX, scaleY),
        );
        final rasterWidth = (logicalWidth * rasterScale)
            .clamp(1.0, double.maxFinite)
            .toDouble();
        final rasterHeight = (logicalHeight * rasterScale)
            .clamp(1.0, double.maxFinite)
            .toDouble();
        return FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(
            key: ValueKey<String>(
              'pdf-raster-${pdf.id}-${rasterScale.toStringAsFixed(3)}',
            ),
            width: rasterWidth,
            height: rasterHeight,
            child: PdfDocumentViewBuilder(
              documentRef: documentRef,
              loadingBuilder: (_) =>
                  const Center(child: CircularProgressIndicator()),
              errorBuilder: (_, _, _) => const Center(
                child: Icon(
                  Icons.picture_as_pdf,
                  color: Color(0xFFD04444),
                  size: 48,
                ),
              ),
              builder: (context, document) {
                if (document == null || document.pages.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                return PdfPageView(
                  document: document,
                  pageNumber: requestedPageNumber.clamp(
                    1,
                    document.pages.length,
                  ),
                  // Bound each visible PDF bitmap. At 200 dpi an A4 page is
                  // about 15 MiB RGBA instead of roughly 35 MiB at the package
                  // default, substantially reducing GC/GPU-memory pressure on
                  // 4K classroom displays.
                  maximumDpi: 200,
                );
              },
            ),
          ),
        );
      },
    ),
  );
}

class _TextBody extends StatefulWidget {
  const _TextBody(this.text, {required this.displayScale});
  final TextObject text;
  final double displayScale;

  @override
  State<_TextBody> createState() => _TextBodyState();
}

class _TextBodyState extends State<_TextBody> {
  final _BoardTextLayoutCache _layoutCache = _BoardTextLayoutCache();

  @override
  void dispose() {
    _layoutCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.text.text,
    child: CustomPaint(
      key: ValueKey<String>('board-text-${widget.text.id}'),
      painter: BoardTextPainter._cached(
        widget.text,
        displayScale: widget.displayScale,
        layoutCache: _layoutCache,
      ),
    ),
  );
}

/// Paints text in logical document coordinates, then scales the completed
/// paragraph. Zoom therefore cannot change wrapping or hide the final line.
class BoardTextPainter extends CustomPainter {
  const BoardTextPainter(this.text, {required this.displayScale})
    : _layoutCache = null;

  const BoardTextPainter._cached(
    this.text, {
    required this.displayScale,
    required _BoardTextLayoutCache layoutCache,
  }) : _layoutCache = layoutCache;

  final TextObject text;
  final double displayScale;
  final _BoardTextLayoutCache? _layoutCache;

  @visibleForTesting
  bool get debugUsesPersistentLayoutCache => _layoutCache != null;

  @visibleForTesting
  int get debugLayoutCount => _layoutCache?.layoutCount ?? 0;

  @override
  void paint(Canvas canvas, Size size) {
    if (text.text.isEmpty || size.isEmpty) return;
    final scale = displayScale.isFinite && displayScale > 0
        ? displayScale
        : 1.0;
    final logicalSize = Size(size.width / scale, size.height / scale);
    final contentRect = TextObjectLayout.contentRectFor(text, logicalSize);
    final persistentCache = _layoutCache;
    final painter =
        persistentCache?.layout(text, contentRect.width) ??
        (TextObjectLayout.createPainter(text)
          ..layout(maxWidth: contentRect.width));
    final x = switch (text.alignment) {
      BoardTextAlign.left => contentRect.left,
      BoardTextAlign.center => contentRect.center.dx - painter.width / 2,
      BoardTextAlign.right => contentRect.right - painter.width,
    };
    canvas
      ..save()
      ..scale(scale)
      ..clipRect(Offset.zero & logicalSize);
    painter.paint(canvas, Offset(x, contentRect.top));
    canvas.restore();
    if (persistentCache == null) painter.dispose();
  }

  @override
  bool shouldRepaint(covariant BoardTextPainter oldDelegate) =>
      oldDelegate.text != text || oldDelegate.displayScale != displayScale;
}

final class _BoardTextLayoutCache {
  TextPainter? _painter;
  TextObject? _value;
  double? _maximumWidth;
  int layoutCount = 0;

  TextPainter layout(TextObject value, double maximumWidth) {
    final cached = _painter;
    if (cached != null &&
        (_maximumWidth! - maximumWidth).abs() < 0.001 &&
        _hasSameLayout(_value!, value)) {
      return cached;
    }
    cached?.dispose();
    final painter = TextObjectLayout.createPainter(value)
      ..layout(maxWidth: maximumWidth);
    _painter = painter;
    _value = value;
    _maximumWidth = maximumWidth;
    layoutCount++;
    return painter;
  }

  bool _hasSameLayout(TextObject previous, TextObject next) =>
      previous.text == next.text &&
      previous.fontSize == next.fontSize &&
      previous.colorArgb == next.colorArgb &&
      previous.bold == next.bold &&
      previous.italic == next.italic &&
      previous.alignment == next.alignment &&
      previous.textLayoutVersion == next.textLayoutVersion;

  void dispose() {
    _painter?.dispose();
    _painter = null;
    _value = null;
    _maximumWidth = null;
  }
}

class _ShapePainter extends CustomPainter {
  const _ShapePainter(this.shape);
  final ShapeObject shape;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = switch (shape.shape) {
      ShapeKind.rectangle =>
        Path()..addRect(rect.deflate(shape.strokeWidth / 2)),
      ShapeKind.circle ||
      ShapeKind.ellipse => Path()..addOval(rect.deflate(shape.strokeWidth / 2)),
      ShapeKind.triangle =>
        Path()
          ..moveTo(size.width / 2, shape.strokeWidth / 2)
          ..lineTo(
            size.width - shape.strokeWidth / 2,
            size.height - shape.strokeWidth / 2,
          )
          ..lineTo(shape.strokeWidth / 2, size.height - shape.strokeWidth / 2)
          ..close(),
    };
    final fillColor = Color(shape.fillArgb);
    if (fillColor.a > 0) {
      canvas.drawPath(path, Paint()..color = fillColor);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Color(shape.strokeArgb)
        ..style = PaintingStyle.stroke
        ..strokeWidth = shape.strokeWidth,
    );
  }

  @override
  bool shouldRepaint(covariant _ShapePainter oldDelegate) =>
      oldDelegate.shape != shape;
}

class _TablePainter extends CustomPainter {
  const _TablePainter(this.table);
  final TableObject table;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFF9F9F6),
    );
    final cellWidth = size.width / table.columns;
    final cellHeight = size.height / table.rows;
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 2,
    );
    final cellBackgroundPaint = Paint();
    for (var row = 0; row < table.rows; row++) {
      for (var column = 0; column < table.columns; column++) {
        final cell = table.cellAt(row, column);
        final rect = Rect.fromLTWH(
          column * cellWidth,
          row * cellHeight,
          cellWidth,
          cellHeight,
        );
        final backgroundColor = Color(cell.backgroundArgb);
        if (backgroundColor.a > 0) {
          cellBackgroundPaint.color = backgroundColor;
          canvas.drawRect(rect, cellBackgroundPaint);
        }
        if (cell.text.isNotEmpty) {
          textPainter.text = TextSpan(
            text: cell.text,
            style: TextStyle(
              color: Color(cell.textArgb),
              fontSize: (cellHeight * .24).clamp(10, 24),
              fontWeight: cell.bold ? FontWeight.bold : FontWeight.normal,
            ),
          );
          textPainter.layout(maxWidth: math.max(1, cellWidth - 10));
          textPainter.paint(canvas, rect.topLeft + const Offset(5, 5));
        }
      }
    }
    final grid = Paint()
      ..color = Color(table.gridColorArgb)
      ..style = PaintingStyle.stroke
      ..strokeWidth = table.gridWidth;
    for (var column = 1; column < table.columns; column++) {
      canvas.drawLine(
        Offset(column * cellWidth, 0),
        Offset(column * cellWidth, size.height),
        grid,
      );
    }
    for (var row = 1; row < table.rows; row++) {
      canvas.drawLine(
        Offset(0, row * cellHeight),
        Offset(size.width, row * cellHeight),
        grid,
      );
    }
    textPainter.dispose();
  }

  @override
  bool shouldRepaint(covariant _TablePainter oldDelegate) =>
      oldDelegate.table != table;
}

class _CoverPainter extends CustomPainter {
  const _CoverPainter(this.cover);
  final CoverObject cover;

  @override
  void paint(Canvas canvas, Size size) {
    final reveal = cover.reveal.clamp(0.0, 1.0);
    final covered = switch (cover.direction) {
      RevealDirection.leftToRight => Rect.fromLTWH(
        size.width * reveal,
        0,
        size.width * (1 - reveal),
        size.height,
      ),
      RevealDirection.rightToLeft => Rect.fromLTWH(
        0,
        0,
        size.width * (1 - reveal),
        size.height,
      ),
      RevealDirection.topToBottom => Rect.fromLTWH(
        0,
        size.height * reveal,
        size.width,
        size.height * (1 - reveal),
      ),
      RevealDirection.bottomToTop => Rect.fromLTWH(
        0,
        0,
        size.width,
        size.height * (1 - reveal),
      ),
    };
    canvas.drawRect(covered, Paint()..color = Color(cover.colorArgb));
  }

  @override
  bool shouldRepaint(covariant _CoverPainter oldDelegate) =>
      oldDelegate.cover != cover;
}

class _ObjectAnnotationBody extends StatefulWidget {
  const _ObjectAnnotationBody({
    required this.layer,
    required this.logicalSize,
    super.key,
  });

  final ObjectInkLayer layer;
  final Size logicalSize;

  @override
  State<_ObjectAnnotationBody> createState() => _ObjectAnnotationBodyState();
}

class _ObjectAnnotationBodyState extends State<_ObjectAnnotationBody> {
  final ObjectAnnotationPictureCache _cache = ObjectAnnotationPictureCache();
  late _CachedAnnotationPainter _painter;

  @override
  void initState() {
    super.initState();
    _updatePictureCache();
  }

  @override
  void didUpdateWidget(covariant _ObjectAnnotationBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.layer, widget.layer) ||
        !_sameAspectRatio(oldWidget.logicalSize, widget.logicalSize)) {
      _updatePictureCache();
    }
  }

  void _updatePictureCache() {
    _cache.update(layer: widget.layer, logicalSize: widget.logicalSize);
    _painter = _CachedAnnotationPainter(
      pictures: _cache._pictures,
      logicalSize: _cache._recordingLogicalSize,
    );
  }

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _painter);

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }
}

/// Bounded vector-picture cache for object-bound ink.
///
/// Completed batches are immutable and survive normal annotation appends. Only
/// the at-most [strokesPerPicture] stroke tail is rerecorded, which keeps
/// pen-up cost independent of the amount of ink already attached to an image,
/// PDF page or table. A changed aspect ratio rebuilds the cache because
/// annotation pen tips must remain circular under non-uniform object resizing.
///
/// The class is public primarily so scale tests can assert the work bound
/// without relying on frame timings.
final class ObjectAnnotationPictureCache {
  static const int strokesPerPicture = 32;

  ObjectInkLayer? _layer;
  Size _recordingLogicalSize = Size.zero;
  final List<ui.Picture> _mutablePictures = <ui.Picture>[];
  List<ui.Picture> _pictures = const <ui.Picture>[];
  bool _disposed = false;

  int _debugRecordedStrokeCount = 0;
  int _debugLastRecordedStrokeCount = 0;
  int _debugPictureCreateCount = 0;
  int _debugPictureDisposeCount = 0;
  int _debugFullRebuildCount = 0;

  @visibleForTesting
  int get debugRecordedStrokeCount => _debugRecordedStrokeCount;

  @visibleForTesting
  int get debugLastRecordedStrokeCount => _debugLastRecordedStrokeCount;

  @visibleForTesting
  int get debugPictureCreateCount => _debugPictureCreateCount;

  @visibleForTesting
  int get debugPictureDisposeCount => _debugPictureDisposeCount;

  @visibleForTesting
  int get debugFullRebuildCount => _debugFullRebuildCount;

  @visibleForTesting
  int get debugPictureCount => _mutablePictures.length;

  void update({required ObjectInkLayer layer, required Size logicalSize}) {
    if (_disposed) {
      throw StateError('Der Annotation-Cache wurde bereits freigegeben.');
    }
    _debugLastRecordedStrokeCount = 0;

    final previous = _layer;
    if (!_isRenderableSize(logicalSize)) {
      _disposeAllPictures();
      _layer = layer;
      _recordingLogicalSize = logicalSize;
      _publishPictures();
      return;
    }

    if (previous != null &&
        _isRenderableSize(_recordingLogicalSize) &&
        _sameAspectRatio(_recordingLogicalSize, logicalSize)) {
      if (identical(layer.strokes, previous.strokes)) {
        _layer = layer;
        return;
      }
      if (layer.isSingleStrokeAppendOf(previous)) {
        _appendTail(layer);
        _layer = layer;
        _publishPictures();
        return;
      }
    }

    _rebuild(layer, logicalSize);
  }

  void _appendTail(ObjectInkLayer layer) {
    final previousLength = layer.strokes.length - 1;
    final tailLength = previousLength % strokesPerPicture;
    final tailStart = previousLength - tailLength;
    if (tailLength > 0) {
      _disposePicture(_mutablePictures.removeLast());
    }
    _mutablePictures.add(
      _recordRange(
        layer.strokes,
        tailStart,
        layer.strokes.length,
        _recordingLogicalSize,
      ),
    );
  }

  void _rebuild(ObjectInkLayer layer, Size logicalSize) {
    _disposeAllPictures();
    _recordingLogicalSize = logicalSize;
    _debugFullRebuildCount++;
    for (
      var start = 0;
      start < layer.strokes.length;
      start += strokesPerPicture
    ) {
      _mutablePictures.add(
        _recordRange(
          layer.strokes,
          start,
          math.min(start + strokesPerPicture, layer.strokes.length),
          logicalSize,
        ),
      );
    }
    _layer = layer;
    _publishPictures();
  }

  ui.Picture _recordRange(
    List<InkStroke> strokes,
    int start,
    int end,
    Size logicalSize,
  ) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (var index = start; index < end; index++) {
      InkPainter.drawObjectLocalStroke(canvas, strokes[index], logicalSize);
    }
    final picture = recorder.endRecording();
    final recorded = end - start;
    _debugRecordedStrokeCount += recorded;
    _debugLastRecordedStrokeCount += recorded;
    _debugPictureCreateCount++;
    return picture;
  }

  void _publishPictures() {
    _pictures = List<ui.Picture>.unmodifiable(_mutablePictures);
  }

  void _disposePicture(ui.Picture picture) {
    picture.dispose();
    _debugPictureDisposeCount++;
  }

  void _disposeAllPictures() {
    for (final picture in _mutablePictures) {
      _disposePicture(picture);
    }
    _mutablePictures.clear();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _disposeAllPictures();
    _pictures = const <ui.Picture>[];
    _layer = null;
  }
}

bool _isRenderableSize(Size size) =>
    size.width.isFinite &&
    size.height.isFinite &&
    size.width > 0 &&
    size.height > 0;

bool _sameAspectRatio(Size previous, Size next) {
  if (!_isRenderableSize(previous) || !_isRenderableSize(next)) {
    return previous == next;
  }
  final previousRatio = previous.width / previous.height;
  final nextRatio = next.width / next.height;
  return (previousRatio - nextRatio).abs() <=
      math.max(previousRatio.abs(), nextRatio.abs()) * 0.000001;
}

class _CachedAnnotationPainter extends CustomPainter {
  const _CachedAnnotationPainter({
    required this.pictures,
    required this.logicalSize,
  });

  final List<ui.Picture> pictures;
  final Size logicalSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty ||
        !logicalSize.width.isFinite ||
        !logicalSize.height.isFinite ||
        logicalSize.width <= 0 ||
        logicalSize.height <= 0) {
      return;
    }
    canvas
      ..save()
      ..scale(size.width / logicalSize.width, size.height / logicalSize.height);
    for (final picture in pictures) {
      canvas.drawPicture(picture);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CachedAnnotationPainter oldDelegate) =>
      !identical(oldDelegate.pictures, pictures) ||
      oldDelegate.logicalSize != logicalSize;
}
