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

  final bool livePreview;
  final Map<String, _CachedInkPicture> _entries = <String, _CachedInkPicture>{};
  bool _disposed = false;

  @visibleForTesting
  int get entryCount => _entries.length;

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
