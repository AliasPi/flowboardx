import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../domain/model/board_object.dart';
import '../../../domain/model/geometry.dart';
import '../../../domain/model/scene_order.dart';
import '../../assets/imported_image_layout.dart';
import '../../editor/text_object_layout.dart';
import 'ink_painter.dart';

abstract interface class BoardAssetResolver {
  Future<Uint8List?> readBytes(String assetId);
  String? localPath(String assetId);
}

class BoardObjectLayer extends StatelessWidget {
  const BoardObjectLayer({
    required this.objects,
    required this.annotationLayers,
    required this.scale,
    required this.offset,
    required this.assets,
    this.selectedIds = const <String>{},
    this.worldClip,
    super.key,
  });

  final List<BoardObject> objects;
  final List<ObjectInkLayer> annotationLayers;
  final double scale;
  final Offset offset;
  final BoardAssetResolver assets;
  final Set<String> selectedIds;
  final Rect2? worldClip;

  @override
  Widget build(BuildContext context) {
    final visibleLayers = annotationLayers
        .where((layer) => layer.visible)
        .toList(growable: false);
    final sorted = orderedBoardSceneItems(
      objects: objects.where(
        (object) =>
            worldClip == null || object.transform.bounds.intersects(worldClip!),
      ),
      strokes: const [],
    ).map((item) => item.object!).toList(growable: false);
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        for (final object in sorted)
          Positioned(
            key: ValueKey('board-object-${object.id}'),
            left: offset.dx + object.transform.x * scale,
            top: offset.dy + object.transform.y * scale,
            width: object.transform.width * scale,
            height: object.transform.height * scale,
            child: RepaintBoundary(
              child: IgnorePointer(
                child: Opacity(
                  opacity: object.opacity,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _ObjectBody(
                        object: object,
                        assets: assets,
                        displayScale: scale,
                      ),
                      if (activeObjectInkLayer(object, visibleLayers)
                          case final layer?)
                        CustomPaint(
                          painter: _NormalizedAnnotationPainter(layer),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ObjectBody extends StatelessWidget {
  const _ObjectBody({
    required this.object,
    required this.assets,
    required this.displayScale,
  });

  final BoardObject object;
  final BoardAssetResolver assets;
  final double displayScale;

  @override
  Widget build(BuildContext context) => switch (object) {
    final ShapeObject shape => CustomPaint(painter: _ShapePainter(shape)),
    final ImageObject image => _ImageBody(
      image: image,
      assets: assets,
      displayScale: displayScale,
    ),
    final PdfObject pdf => _PdfBody(pdf: pdf, assets: assets),
    final TableObject table => CustomPaint(painter: _TablePainter(table)),
    final CoverObject cover => CustomPaint(painter: _CoverPainter(cover)),
    final TextObject text => _TextBody(text, displayScale: displayScale),
  };
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
  late Future<({String? path, Uint8List? bytes})?> _validatedAsset =
      _loadValidatedAsset();

  Future<({String? path, Uint8List? bytes})?> _loadValidatedAsset() async {
    try {
      final path = widget.assets.localPath(widget.image.assetId);
      if (path != null) {
        await ImportedImageLayout.dimensionsFromFile(path);
        return (path: path, bytes: null);
      }
      final bytes = await widget.assets.readBytes(widget.image.assetId);
      if (bytes == null) return null;
      await ImportedImageLayout.dimensionsFromBytes(bytes);
      return (path: null, bytes: bytes);
    } on ImportedImageValidationException {
      // Recovered or crafted documents may reference invalid legacy assets.
      // Convert validation failures to render state here so an early async
      // error can never escape into Flutter's root zone before FutureBuilder
      // has attached its listener.
      return null;
    } on FileSystemException {
      return null;
    }
  }

  @override
  void didUpdateWidget(covariant _ImageBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.assetId != widget.image.assetId ||
        oldWidget.assets != widget.assets) {
      _validatedAsset = _loadValidatedAsset();
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
    return FutureBuilder<({String? path, Uint8List? bytes})?>(
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

class _PdfBody extends StatefulWidget {
  const _PdfBody({required this.pdf, required this.assets});

  final PdfObject pdf;
  final BoardAssetResolver assets;

  @override
  State<_PdfBody> createState() => _PdfBodyState();
}

class _PdfBodyState extends State<_PdfBody> {
  String? _path;
  PdfDocumentRefFile? _documentRef;

  void _resolveDocument() {
    final nextPath = widget.assets.localPath(widget.pdf.assetId);
    if (nextPath == _path) return;
    _path = nextPath;
    _documentRef = nextPath == null ? null : PdfDocumentRefFile(nextPath);
  }

  @override
  void initState() {
    super.initState();
    _resolveDocument();
  }

  @override
  void didUpdateWidget(covariant _PdfBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pdf.assetId != widget.pdf.assetId ||
        oldWidget.assets != widget.assets) {
      _resolveDocument();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pdf = widget.pdf;
    final documentRef = _documentRef;
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
    return ColoredBox(
      color: Colors.white,
      child: PdfDocumentViewBuilder(
        documentRef: documentRef,
        loadingBuilder: (_) => const Center(child: CircularProgressIndicator()),
        errorBuilder: (_, _, _) => const Center(
          child: Icon(Icons.picture_as_pdf, color: Color(0xFFD04444), size: 48),
        ),
        builder: (context, document) {
          if (document == null || document.pages.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          return PdfPageView(
            document: document,
            pageNumber: requested.clamp(1, document.pages.length),
          );
        },
      ),
    );
  }
}

class _TextBody extends StatelessWidget {
  const _TextBody(this.text, {required this.displayScale});
  final TextObject text;
  final double displayScale;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: switch (text.alignment) {
        BoardTextAlign.left => Alignment.topLeft,
        BoardTextAlign.center => Alignment.topCenter,
        BoardTextAlign.right => Alignment.topRight,
      },
      child: Text(
        text.text,
        textAlign: TextObjectLayout.textAlignFor(text.alignment),
        textScaler: TextScaler.noScaling,
        style: TextObjectLayout.styleFor(
          text,
        ).copyWith(fontSize: text.fontSize * displayScale),
      ),
    );
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
    if (Color(shape.fillArgb).a > 0) {
      canvas.drawPath(path, Paint()..color = Color(shape.fillArgb));
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
    for (var row = 0; row < table.rows; row++) {
      for (var column = 0; column < table.columns; column++) {
        final cell = table.cellAt(row, column);
        final rect = Rect.fromLTWH(
          column * cellWidth,
          row * cellHeight,
          cellWidth,
          cellHeight,
        );
        if (Color(cell.backgroundArgb).a > 0) {
          canvas.drawRect(rect, Paint()..color = Color(cell.backgroundArgb));
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

class _NormalizedAnnotationPainter extends CustomPainter {
  const _NormalizedAnnotationPainter(this.layer);
  final ObjectInkLayer layer;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in layer.strokes) {
      InkPainter.drawObjectLocalStroke(canvas, stroke, size);
    }
  }

  @override
  bool shouldRepaint(covariant _NormalizedAnnotationPainter oldDelegate) =>
      !identical(oldDelegate.layer, layer);
}
