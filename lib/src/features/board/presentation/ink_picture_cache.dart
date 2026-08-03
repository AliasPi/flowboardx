import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../domain/model/ink.dart';
import 'ink_painter.dart';

/// Retains immutable world-space ink display lists across widget rebuilds.
///
/// The cache is deliberately vector based, so one recording can be translated
/// and scaled for every viewport without rebuilding paths on the Dart thread.
class InkPictureCache {
  InkPictureCache({required this.livePreview});

  /// Persisted scene runs are already bounded to 48 strokes / 2048 points.
  /// Recording small sub-batches reduces both native Picture handles and
  /// drawPicture calls without making a sparse transform rerecord a whole run.
  static const int maximumBatchStrokes = 8;
  static const int maximumBatchPoints = 512;

  final bool livePreview;
  final Map<String, _CachedInkPicture> _entries = <String, _CachedInkPicture>{};
  final List<_CachedInkBatch> _batches = <_CachedInkBatch>[];
  List<InkStroke>? _batchSource;
  List<ui.Picture> _batchPictures = const <ui.Picture>[];
  bool _disposed = false;
  int _batchPictureCreateCount = 0;
  int _batchPictureDisposeCount = 0;
  int _lastBatchRecordedStrokeCount = 0;

  @visibleForTesting
  int get entryCount => _entries.length;

  @visibleForTesting
  int get batchPictureCount => _batches.length;

  @visibleForTesting
  int get batchPictureCreateCount => _batchPictureCreateCount;

  @visibleForTesting
  int get batchPictureDisposeCount => _batchPictureDisposeCount;

  @visibleForTesting
  int get lastBatchRecordedStrokeCount => _lastBatchRecordedStrokeCount;

  ui.Picture pictureFor(InkStroke stroke) {
    if (_disposed) {
      throw StateError('Der Ink-Cache wurde bereits freigegeben.');
    }
    final existing = _entries[stroke.id];
    if (existing != null && identical(existing.stroke, stroke)) {
      return existing.picture;
    }
    existing?.picture.dispose();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (livePreview) {
      InkPainter.drawLivePreviewStroke(canvas, stroke);
    } else {
      InkPainter.drawStroke(canvas, stroke);
    }
    final picture = recorder.endRecording();
    _entries[stroke.id] = _CachedInkPicture(stroke, picture);
    return picture;
  }

  /// Returns vector display lists for one bounded persisted scene run.
  ///
  /// The identical immutable source is an O(1) hit on viewport/overlay frames.
  /// On an append or sparse transform, identity comparison is limited to the
  /// run's tiny batches and only affected batches are rerecorded.
  List<ui.Picture> batchPicturesFor(List<InkStroke> strokes) {
    if (_disposed) {
      throw StateError('Der Ink-Cache wurde bereits freigegeben.');
    }
    _lastBatchRecordedStrokeCount = 0;
    if (identical(_batchSource, strokes)) return _batchPictures;

    final next = <_CachedInkBatch>[];
    var start = 0;
    var batchIndex = 0;
    while (start < strokes.length) {
      var end = start;
      var points = 0;
      while (end < strokes.length && end - start < maximumBatchStrokes) {
        final nextPoints = strokes[end].points.length;
        if (end > start && points + nextPoints > maximumBatchPoints) break;
        points += nextPoints;
        end++;
        if (points >= maximumBatchPoints) break;
      }
      // The loop always accepts the first stroke, including a recovered
      // oversized stroke or an empty defensive record.
      if (end == start) end++;

      final existing = batchIndex < _batches.length
          ? _batches[batchIndex]
          : null;
      if (existing != null && existing.matches(strokes, start, end)) {
        next.add(existing);
      } else {
        if (existing != null) _disposeBatch(existing);
        next.add(_recordBatch(strokes, start, end));
      }
      start = end;
      batchIndex++;
    }
    for (var index = next.length; index < _batches.length; index++) {
      _disposeBatch(_batches[index]);
    }
    _batches
      ..clear()
      ..addAll(next);
    _batchSource = strokes;
    _batchPictures = List<ui.Picture>.unmodifiable(
      _batches.map((entry) => entry.picture),
    );
    return _batchPictures;
  }

  _CachedInkBatch _recordBatch(List<InkStroke> strokes, int start, int end) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (var index = start; index < end; index++) {
      InkPainter.drawStroke(canvas, strokes[index]);
    }
    final entry = _CachedInkBatch(
      List<InkStroke>.unmodifiable(strokes.getRange(start, end)),
      recorder.endRecording(),
    );
    _batchPictureCreateCount++;
    _lastBatchRecordedStrokeCount += end - start;
    return entry;
  }

  void _disposeBatch(_CachedInkBatch batch) {
    batch.picture.dispose();
    _batchPictureDisposeCount++;
  }

  void retainOnly(Set<String> ids) {
    if (_disposed) return;
    for (final id in _entries.keys.toList(growable: false)) {
      if (ids.contains(id)) continue;
      _entries.remove(id)?.picture.dispose();
    }
  }

  void clear() {
    if (_disposed) return;
    for (final entry in _entries.values) {
      entry.picture.dispose();
    }
    _entries.clear();
    for (final batch in _batches) {
      _disposeBatch(batch);
    }
    _batches.clear();
    _batchSource = null;
    _batchPictures = const <ui.Picture>[];
  }

  void dispose() {
    if (_disposed) return;
    clear();
    _disposed = true;
  }
}

final class LiveInkPictureCache extends InkPictureCache {
  LiveInkPictureCache() : super(livePreview: true);
}

final class _CachedInkPicture {
  const _CachedInkPicture(this.stroke, this.picture);

  final InkStroke stroke;
  final ui.Picture picture;
}

final class _CachedInkBatch {
  const _CachedInkBatch(this.strokes, this.picture);

  final List<InkStroke> strokes;
  final ui.Picture picture;

  bool matches(List<InkStroke> source, int start, int end) {
    if (strokes.length != end - start) return false;
    for (var index = 0; index < strokes.length; index++) {
      if (!identical(strokes[index], source[start + index])) return false;
    }
    return true;
  }
}
