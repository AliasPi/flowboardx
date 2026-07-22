import 'dart:async';

import '../model/document.dart';
import 'document_command.dart';

final class CommandHistory {
  CommandHistory(
    WhiteboardDocument initial, {
    this.maxDepth = 200,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _document = initial {
    if (maxDepth < 1) {
      throw ArgumentError.value(maxDepth, 'maxDepth', 'muss positiv sein');
    }
  }

  final int maxDepth;
  final DateTime Function() _clock;
  final List<_HistoryEntry> _undoStack = [];
  final List<_HistoryEntry> _redoStack = [];
  final StreamController<WhiteboardDocument> _changes =
      StreamController.broadcast(sync: true);
  WhiteboardDocument _document;
  bool _disposed = false;

  WhiteboardDocument get document => _document;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  int get undoDepth => _undoStack.length;
  int get redoDepth => _redoStack.length;
  Stream<WhiteboardDocument> get changes => _changes.stream;

  WhiteboardDocument execute(DocumentCommand command) {
    _ensureActive();
    final before = _document;
    final candidate = command.apply(before);
    if (identical(candidate, before)) return _document;
    final after = _withMonotonicRevision(candidate, after: before);
    _undoStack.add(_HistoryEntry(command.label, before, after));
    if (_undoStack.length > maxDepth) _undoStack.removeAt(0);
    _redoStack.clear();
    return _publish(after);
  }

  /// Applies persistent UI state (page/viewport) without consuming Undo/Redo.
  WhiteboardDocument executeUntracked(DocumentCommand command) {
    _ensureActive();
    final before = _document;
    final candidate = command.apply(before);
    if (identical(candidate, before)) return _document;
    return _publish(_withMonotonicRevision(candidate, after: before));
  }

  WhiteboardDocument undo() {
    _ensureActive();
    if (_undoStack.isEmpty) return _document;
    final entry = _undoStack.removeLast();
    _redoStack.add(entry);
    final restored = _preserveNavigation(entry.before, _document);
    return _publish(_withMonotonicRevision(restored, after: _document));
  }

  WhiteboardDocument redo() {
    _ensureActive();
    if (_redoStack.isEmpty) return _document;
    final entry = _redoStack.removeLast();
    _undoStack.add(entry);
    final restored = _preserveNavigation(entry.after, _document);
    return _publish(_withMonotonicRevision(restored, after: _document));
  }

  /// Replaces the loaded document and starts a fresh history boundary.
  void reset(WhiteboardDocument document) {
    _ensureActive();
    _document = document;
    _undoStack.clear();
    _redoStack.clear();
    _changes.add(document);
  }

  void clear() {
    _ensureActive();
    _undoStack.clear();
    _redoStack.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _changes.close();
  }

  WhiteboardDocument _publish(WhiteboardDocument document) {
    _document = document;
    _changes.add(document);
    return document;
  }

  WhiteboardDocument _withMonotonicRevision(
    WhiteboardDocument candidate, {
    required WhiteboardDocument after,
  }) {
    var timestamp = candidate.updatedAt;
    if (!timestamp.isAfter(after.updatedAt)) {
      final clockValue = _clock().toUtc();
      timestamp = clockValue.isAfter(after.updatedAt)
          ? clockValue
          : after.updatedAt.add(const Duration(microseconds: 1));
    }
    return candidate.copyWith(
      updatedAt: timestamp,
      revision: candidate.revision > after.revision
          ? candidate.revision
          : after.revision + 1,
    );
  }

  WhiteboardDocument _preserveNavigation(
    WhiteboardDocument content,
    WhiteboardDocument current,
  ) {
    final pages = content.pages
        .map((page) {
          final currentPage = current.pageById(page.id);
          return currentPage == null
              ? page
              : page.copyWith(viewport: currentPage.viewport);
        })
        .toList(growable: false);
    final currentPageId = current.currentPage.id;
    final matchingIndex = pages.indexWhere((page) => page.id == currentPageId);
    final custom = Map<String, String>.from(content.metadata.custom);
    for (final key in const <String>[
      'radialMenuX',
      'radialMenuY',
      'recentPenColors',
    ]) {
      final value = current.metadata.custom[key];
      if (value == null) {
        custom.remove(key);
      } else {
        custom[key] = value;
      }
    }
    return content.copyWith(
      pages: pages,
      metadata: content.metadata.copyWith(custom: custom),
      currentPageIndex: matchingIndex >= 0
          ? matchingIndex
          : content.currentPageIndex.clamp(0, pages.length - 1),
    );
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('CommandHistory wurde bereits geschlossen.');
    }
  }
}

final class _HistoryEntry {
  const _HistoryEntry(this.label, this.before, this.after);

  final String label;
  final WhiteboardDocument before;
  final WhiteboardDocument after;
}
