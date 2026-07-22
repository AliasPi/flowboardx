import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../domain/export_snapshot.dart';

enum PdfExportStage { rasterizing, encoding, writing }

final class PdfExportProgress {
  const PdfExportProgress({
    required this.pageIndex,
    required this.pageCount,
    required this.stage,
  });

  final int pageIndex;
  final int pageCount;
  final PdfExportStage stage;

  double get fraction {
    final stageFraction = switch (stage) {
      PdfExportStage.rasterizing => 0.0,
      PdfExportStage.encoding => 0.55,
      PdfExportStage.writing => 0.9,
    };
    return ((pageIndex + stageFraction) / pageCount).clamp(0, 1);
  }
}

final class PdfExportCancelled implements Exception {
  const PdfExportCancelled();

  @override
  String toString() => 'PDF export was cancelled.';
}

/// Writes standards-compliant PDF 1.7 files without retaining every rendered
/// page in memory.
///
/// Pages are embedded as lossless, Flate-compressed RGB images. Alpha is
/// composited over [backgroundRgb]. Compression is performed in a helper
/// isolate so large pages do not stall pointer rendering on the UI isolate.
final class PdfExporter {
  const PdfExporter({
    this.pixelRatio = 1.5,
    this.maxPixelsPerPage = 16 * 1024 * 1024,
    this.backgroundRgb = 0xFFFFFF,
  }) : assert(pixelRatio > 0),
       assert(maxPixelsPerPage > 0),
       assert(backgroundRgb >= 0 && backgroundRgb <= 0xFFFFFF);

  final double pixelRatio;
  final int maxPixelsPerPage;
  final int backgroundRgb;

  Future<Uint8List> exportToBytes(
    ExportDocumentSnapshot document, {
    void Function(PdfExportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final target = _MemoryPdfTarget();
    await _writeDocument(
      document,
      target,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    return target.takeBytes();
  }

  /// Exports to a sibling temporary file and only swaps it into place after a
  /// complete PDF has been flushed. A previously valid export therefore
  /// survives process failure during rendering or encoding.
  Future<File> exportToFile(
    ExportDocumentSnapshot document,
    File destination, {
    bool overwrite = false,
    void Function(PdfExportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (await destination.exists() && !overwrite) {
      throw FileSystemException(
        'Export destination already exists.',
        destination.path,
      );
    }
    await destination.parent.create(recursive: true);

    final nonce = '${DateTime.now().microsecondsSinceEpoch}-$pid';
    final temporary = File('${destination.path}.$nonce.part');
    RandomAccessFile? output;
    try {
      output = await temporary.open(mode: FileMode.write);
      final target = _FilePdfTarget(output);
      await _writeDocument(
        document,
        target,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      await output.flush();
      await output.close();
      output = null;
      await _replaceFile(temporary, destination, overwrite: overwrite);
      return destination;
    } catch (_) {
      if (output != null) {
        await output.close().catchError((_) {});
      }
      if (await temporary.exists()) {
        await temporary.delete().catchError((_) => temporary);
      }
      rethrow;
    }
  }

  Future<void> _writeDocument(
    ExportDocumentSnapshot document,
    _PdfTarget target, {
    void Function(PdfExportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    void checkCancellation() {
      if (isCancelled?.call() ?? false) {
        throw const PdfExportCancelled();
      }
    }

    final pageCount = document.pages.length;
    final infoId = 3 + pageCount * 3;
    final offsets = List<int>.filled(infoId + 1, 0);

    await target.add(<int>[
      ...ascii.encode('%PDF-1.7\n%'),
      0xE2,
      0xE3,
      0xCF,
      0xD3,
      0x0A,
    ]);

    await _writeObject(
      target,
      offsets,
      1,
      ascii.encode('<< /Type /Catalog /Pages 2 0 R /PageLayout /SinglePage >>'),
    );

    final kids = List<String>.generate(
      pageCount,
      (index) => '${_pageObjectId(index)} 0 R',
      growable: false,
    ).join(' ');
    await _writeObject(
      target,
      offsets,
      2,
      ascii.encode('<< /Type /Pages /Count $pageCount /Kids [$kids] >>'),
    );

    for (var index = 0; index < pageCount; index++) {
      checkCancellation();
      final page = document.pages[index];
      onProgress?.call(
        PdfExportProgress(
          pageIndex: index,
          pageCount: pageCount,
          stage: PdfExportStage.rasterizing,
        ),
      );
      final raster = await page.rasterize(
        ExportRasterRequest(
          logicalWidth: page.logicalWidth,
          logicalHeight: page.logicalHeight,
          pixelRatio: pixelRatio,
          maxPixels: maxPixelsPerPage,
        ),
      );
      checkCancellation();
      final pixels = raster.width * raster.height;
      if (pixels > maxPixelsPerPage) {
        throw StateError(
          'Page ${index + 1} returned $pixels pixels, exceeding the configured '
          'limit of $maxPixelsPerPage.',
        );
      }

      onProgress?.call(
        PdfExportProgress(
          pageIndex: index,
          pageCount: pageCount,
          stage: PdfExportStage.encoding,
        ),
      );
      final compressedRgb = await _encodeRgbOffThread(
        _EncodeRasterTask(rgba: raster.rgbaBytes, backgroundRgb: backgroundRgb),
      );
      checkCancellation();

      final pageId = _pageObjectId(index);
      final contentId = pageId + 1;
      final imageId = pageId + 2;
      final width = _pdfNumber(page.widthPoints);
      final height = _pdfNumber(page.heightPoints);
      await _writeObject(
        target,
        offsets,
        pageId,
        ascii.encode(
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] '
          '/Resources << /ProcSet [/PDF /ImageC] /XObject << /Im0 $imageId 0 R >> >> '
          '/Contents $contentId 0 R >>',
        ),
      );

      final content = ascii.encode(
        'q\n$width 0 0 $height 0 0 cm\n/Im0 Do\nQ\n',
      );
      await _writeStreamObject(target, offsets, contentId, '', content);

      onProgress?.call(
        PdfExportProgress(
          pageIndex: index,
          pageCount: pageCount,
          stage: PdfExportStage.writing,
        ),
      );
      await _writeStreamObject(
        target,
        offsets,
        imageId,
        '/Type /XObject /Subtype /Image /Width ${raster.width} '
        '/Height ${raster.height} /ColorSpace /DeviceRGB '
        '/BitsPerComponent 8 /Filter /FlateDecode',
        compressedRgb,
      );
    }

    checkCancellation();
    await _writeObject(
      target,
      offsets,
      infoId,
      ascii.encode(
        '<< /Title ${_pdfString(document.title)} '
        '${document.author == null ? '' : '/Author ${_pdfString(document.author!)} '}'
        '/Creator ${_pdfString('Flowboard X')} '
        '/Producer ${_pdfString('Flowboard X raster PDF engine')} '
        '/CreationDate ${_pdfString(_pdfDate(document.createdAt))} '
        '/ModDate ${_pdfString(_pdfDate(document.modifiedAt))} >>',
      ),
    );

    final xrefOffset = target.offset;
    await target.add(ascii.encode('xref\n0 ${infoId + 1}\n'));
    await target.add(ascii.encode('0000000000 65535 f \n'));
    for (var id = 1; id <= infoId; id++) {
      if (offsets[id] > 9999999999) {
        throw StateError(
          'PDF exceeds the supported 10 GB cross-reference range.',
        );
      }
      await target.add(
        ascii.encode('${offsets[id].toString().padLeft(10, '0')} 00000 n \n'),
      );
    }
    await target.add(
      ascii.encode(
        'trailer\n<< /Size ${infoId + 1} /Root 1 0 R /Info $infoId 0 R >>\n'
        'startxref\n$xrefOffset\n%%EOF\n',
      ),
    );
  }

  static Future<void> _replaceFile(
    File temporary,
    File destination, {
    required bool overwrite,
  }) async {
    if (!await destination.exists()) {
      await temporary.rename(destination.path);
      return;
    }
    if (!overwrite) {
      throw FileSystemException(
        'Export destination already exists.',
        destination.path,
      );
    }

    final backup = File(
      '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.backup',
    );
    await destination.rename(backup.path);
    try {
      await temporary.rename(destination.path);
    } catch (_) {
      if (!await destination.exists() && await backup.exists()) {
        await backup.rename(destination.path);
      }
      rethrow;
    }
    // A failed cleanup must not turn an otherwise successful atomic export
    // into an application error. The backup remains recoverable and can be
    // removed by the next maintenance pass.
    await backup.delete().catchError((_) => backup);
  }
}

int _pageObjectId(int pageIndex) => 3 + pageIndex * 3;

Future<void> _writeObject(
  _PdfTarget target,
  List<int> offsets,
  int id,
  List<int> body,
) async {
  offsets[id] = target.offset;
  await target.add(ascii.encode('$id 0 obj\n'));
  await target.add(body);
  await target.add(ascii.encode('\nendobj\n'));
}

Future<void> _writeStreamObject(
  _PdfTarget target,
  List<int> offsets,
  int id,
  String dictionaryEntries,
  List<int> bytes,
) async {
  offsets[id] = target.offset;
  await target.add(
    ascii.encode(
      '$id 0 obj\n<< ${dictionaryEntries.isEmpty ? '' : '$dictionaryEntries '}'
      '/Length ${bytes.length} >>\nstream\n',
    ),
  );
  await target.add(bytes);
  await target.add(ascii.encode('\nendstream\nendobj\n'));
}

String _pdfNumber(double value) {
  final fixed = value.toStringAsFixed(3);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

String _pdfString(String value) {
  final isAscii = value.codeUnits.every((unit) => unit >= 0x20 && unit <= 0x7E);
  if (isAscii) {
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('(', r'\(')
        .replaceAll(')', r'\)');
    return '($escaped)';
  }

  final buffer = StringBuffer('<FEFF');
  for (final unit in value.codeUnits) {
    buffer.write(unit.toRadixString(16).padLeft(4, '0').toUpperCase());
  }
  return '${buffer.toString()}>';
}

String _pdfDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final absoluteMinutes = offset.inMinutes.abs();
  final zoneHours = absoluteMinutes ~/ 60;
  final zoneMinutes = absoluteMinutes % 60;
  return 'D:${local.year.toString().padLeft(4, '0')}'
      '${two(local.month)}${two(local.day)}${two(local.hour)}'
      '${two(local.minute)}${two(local.second)}$sign${two(zoneHours)}\'${two(zoneMinutes)}\'';
}

final class _EncodeRasterTask {
  const _EncodeRasterTask({required this.rgba, required this.backgroundRgb});

  final Uint8List rgba;
  final int backgroundRgb;

  Uint8List encode() => _encodeRgb(this);
}

Future<Uint8List> _encodeRgbOffThread(_EncodeRasterTask task) =>
    Isolate.run(task.encode);

Uint8List _encodeRgb(_EncodeRasterTask task) {
  final rgba = task.rgba;
  final rgb = Uint8List((rgba.length ~/ 4) * 3);
  final backgroundRed = (task.backgroundRgb >> 16) & 0xFF;
  final backgroundGreen = (task.backgroundRgb >> 8) & 0xFF;
  final backgroundBlue = task.backgroundRgb & 0xFF;
  var output = 0;
  for (var input = 0; input < rgba.length; input += 4) {
    final alpha = rgba[input + 3];
    final inverseAlpha = 255 - alpha;
    rgb[output++] =
        (rgba[input] * alpha + backgroundRed * inverseAlpha + 127) ~/ 255;
    rgb[output++] =
        (rgba[input + 1] * alpha + backgroundGreen * inverseAlpha + 127) ~/ 255;
    rgb[output++] =
        (rgba[input + 2] * alpha + backgroundBlue * inverseAlpha + 127) ~/ 255;
  }
  return Uint8List.fromList(ZLibEncoder(level: 6).convert(rgb));
}

abstract interface class _PdfTarget {
  int get offset;
  Future<void> add(List<int> bytes);
}

final class _MemoryPdfTarget implements _PdfTarget {
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _offset = 0;

  @override
  int get offset => _offset;

  @override
  Future<void> add(List<int> bytes) async {
    _builder.add(bytes);
    _offset += bytes.length;
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

final class _FilePdfTarget implements _PdfTarget {
  _FilePdfTarget(this._file);

  final RandomAccessFile _file;
  int _offset = 0;

  @override
  int get offset => _offset;

  @override
  Future<void> add(List<int> bytes) async {
    await _file.writeFrom(bytes);
    _offset += bytes.length;
  }
}
