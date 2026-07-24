import 'package:flutter/material.dart';

enum BoardViewportPartitionSide { left, right }

/// A stable world-space divider for a horizontally partitioned viewport.
///
/// [worldBoundaryX] is deliberately independent of the current camera. This
/// means zooming and panning cannot move a participant through the divider:
/// the left participant's visible right edge stays at or before the boundary,
/// and the right participant's visible left edge stays at or after it.
@immutable
class BoardViewportHorizontalConstraint {
  const BoardViewportHorizontalConstraint({
    required this.side,
    required this.worldBoundaryX,
  });

  final BoardViewportPartitionSide side;
  final double worldBoundaryX;

  bool get isValid => worldBoundaryX.isFinite;
}

class BoardViewport extends ChangeNotifier {
  BoardViewport({
    this.pageSize = const Size(1920, 1080),
    double scale = 1,
    Offset offset = Offset.zero,
  }) : _scale = scale,
       _offset = offset;

  final Size pageSize;
  static const minScale = 0.18;
  static const maxScale = 4.5;

  double _scale;
  Offset _offset;

  double get scale => _scale;
  Offset get offset => _offset;
  Rect get worldBounds => Rect.fromLTWH(
    -pageSize.width,
    -pageSize.height,
    pageSize.width * 3,
    pageSize.height * 3,
  );

  Offset screenToWorld(Offset screen) => (screen - _offset) / _scale;
  Offset worldToScreen(Offset world) => world * _scale + _offset;

  void restore({required double scale, required Offset offset}) {
    _scale = scale.clamp(minScale, maxScale);
    _offset = offset;
    notifyListeners();
  }

  void panBy(
    Offset delta,
    Size viewportSize, {
    Rect? visibleScreenBounds,
    BoardViewportHorizontalConstraint? horizontalConstraint,
  }) {
    _offset += delta;
    _clamp(
      viewportSize,
      visibleScreenBounds: visibleScreenBounds,
      horizontalConstraint: horizontalConstraint,
    );
    notifyListeners();
  }

  void zoomAt({
    required double factor,
    required Offset focalPoint,
    required Size viewportSize,
    Rect? visibleScreenBounds,
    BoardViewportHorizontalConstraint? horizontalConstraint,
  }) {
    if (!factor.isFinite || factor <= 0) return;
    final worldFocal = screenToWorld(focalPoint);
    _scale = (_scale * factor).clamp(minScale, maxScale);
    _offset = focalPoint - worldFocal * _scale;
    _clamp(
      viewportSize,
      visibleScreenBounds: visibleScreenBounds,
      horizontalConstraint: horizontalConstraint,
    );
    notifyListeners();
  }

  void centerOn(
    Offset worldPosition,
    Size viewportSize, {
    Rect? visibleScreenBounds,
    BoardViewportHorizontalConstraint? horizontalConstraint,
  }) {
    if (!worldPosition.dx.isFinite ||
        !worldPosition.dy.isFinite ||
        viewportSize.isEmpty) {
      return;
    }
    final visibleBounds = _safeVisibleBounds(viewportSize, visibleScreenBounds);
    _offset = visibleBounds.center - worldPosition * _scale;
    _clamp(
      viewportSize,
      visibleScreenBounds: visibleBounds,
      horizontalConstraint: horizontalConstraint,
    );
    notifyListeners();
  }

  /// Re-applies the board and optional split-view constraints without
  /// changing the intended scale or position first.
  void constrain({
    required Size viewportSize,
    Rect? visibleScreenBounds,
    BoardViewportHorizontalConstraint? horizontalConstraint,
  }) {
    final previous = _offset;
    _clamp(
      viewportSize,
      visibleScreenBounds: visibleScreenBounds,
      horizontalConstraint: horizontalConstraint,
    );
    if (_offset != previous) notifyListeners();
  }

  Rect _safeVisibleBounds(Size viewportSize, Rect? requested) {
    final surfaceBounds = Offset.zero & viewportSize;
    if (viewportSize.isEmpty || requested == null) return surfaceBounds;
    final clipped = requested.intersect(surfaceBounds);
    if (!clipped.left.isFinite ||
        !clipped.top.isFinite ||
        !clipped.width.isFinite ||
        !clipped.height.isFinite ||
        clipped.isEmpty) {
      return surfaceBounds;
    }
    return clipped;
  }

  void _clamp(
    Size viewportSize, {
    Rect? visibleScreenBounds,
    BoardViewportHorizontalConstraint? horizontalConstraint,
  }) {
    if (viewportSize.isEmpty ||
        !viewportSize.width.isFinite ||
        !viewportSize.height.isFinite) {
      return;
    }
    final visibleBounds = _safeVisibleBounds(viewportSize, visibleScreenBounds);
    // Keep at least 12% of the complete 3x3 board visible. This prevents
    // losing the canvas without forcing any edge docking behavior in the UI.
    final visibleMarginX = visibleBounds.width * 0.12;
    final visibleMarginY = visibleBounds.height * 0.12;
    final left = worldBounds.left * _scale + _offset.dx;
    final right = worldBounds.right * _scale + _offset.dx;
    final top = worldBounds.top * _scale + _offset.dy;
    final bottom = worldBounds.bottom * _scale + _offset.dy;
    final minimumVisibleX = visibleBounds.left + visibleMarginX;
    final maximumVisibleX = visibleBounds.right - visibleMarginX;
    final minimumVisibleY = visibleBounds.top + visibleMarginY;
    final maximumVisibleY = visibleBounds.bottom - visibleMarginY;
    if (right < minimumVisibleX) {
      _offset = Offset(_offset.dx + minimumVisibleX - right, _offset.dy);
    }
    if (left > maximumVisibleX) {
      _offset = Offset(_offset.dx + maximumVisibleX - left, _offset.dy);
    }
    if (bottom < minimumVisibleY) {
      _offset = Offset(_offset.dx, _offset.dy + minimumVisibleY - bottom);
    }
    if (top > maximumVisibleY) {
      _offset = Offset(_offset.dx, _offset.dy + maximumVisibleY - top);
    }

    final constraint = horizontalConstraint;
    if (constraint == null || !constraint.isValid) return;
    final boundaryScreenX = constraint.worldBoundaryX * _scale + _offset.dx;
    switch (constraint.side) {
      case BoardViewportPartitionSide.left:
        if (boundaryScreenX < visibleBounds.right) {
          _offset = Offset(
            _offset.dx + visibleBounds.right - boundaryScreenX,
            _offset.dy,
          );
        }
      case BoardViewportPartitionSide.right:
        if (boundaryScreenX > visibleBounds.left) {
          _offset = Offset(
            _offset.dx + visibleBounds.left - boundaryScreenX,
            _offset.dy,
          );
        }
    }
  }
}
