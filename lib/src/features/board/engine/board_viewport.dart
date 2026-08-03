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
    final previousOffset = _offset;
    _offset += delta;
    _clamp(
      viewportSize,
      visibleScreenBounds: visibleScreenBounds,
      horizontalConstraint: horizontalConstraint,
    );
    if (_offset != previousOffset) notifyListeners();
  }

  void zoomAt({
    required double factor,
    required Offset focalPoint,
    required Size viewportSize,
    Rect? visibleScreenBounds,
    BoardViewportHorizontalConstraint? horizontalConstraint,
  }) {
    if (!factor.isFinite || factor <= 0) return;
    final previousScale = _scale;
    final previousOffset = _offset;
    final worldFocal = screenToWorld(focalPoint);
    _scale = (_scale * factor).clamp(minScale, maxScale);
    _offset = focalPoint - worldFocal * _scale;
    _clamp(
      viewportSize,
      visibleScreenBounds: visibleScreenBounds,
      horizontalConstraint: horizontalConstraint,
    );
    if (_scale != previousScale || _offset != previousOffset) {
      notifyListeners();
    }
  }

  /// Applies one two-pointer camera sample as a single atomic state change.
  ///
  /// The operation deliberately retains the established gesture order:
  ///
  /// 1. move the previous centroid to the new centroid and clamp;
  /// 2. zoom around the new centroid and clamp again.
  ///
  /// This is geometrically identical to calling [panBy] followed by [zoomAt],
  /// but listeners observe only the final camera. A hardware move event can
  /// therefore invalidate the board at most once.
  void applyGestureTransform({
    required Offset panDelta,
    required Offset focalPoint,
    required Size viewportSize,
    double? zoomFactor,
    Rect? visibleScreenBounds,
    BoardViewportHorizontalConstraint? horizontalConstraint,
  }) {
    final previousScale = _scale;
    final previousOffset = _offset;

    if (panDelta.dx.isFinite && panDelta.dy.isFinite) {
      _offset += panDelta;
    }
    _clamp(
      viewportSize,
      visibleScreenBounds: visibleScreenBounds,
      horizontalConstraint: horizontalConstraint,
    );

    final factor = zoomFactor;
    if (factor != null &&
        factor.isFinite &&
        factor > 0 &&
        focalPoint.dx.isFinite &&
        focalPoint.dy.isFinite) {
      final worldFocal = screenToWorld(focalPoint);
      final nextScale = (_scale * factor).clamp(minScale, maxScale);
      if (nextScale != _scale) {
        _scale = nextScale;
        _offset = focalPoint - worldFocal * _scale;
      }
      _clamp(
        viewportSize,
        visibleScreenBounds: visibleScreenBounds,
        horizontalConstraint: horizontalConstraint,
      );
    }

    if (_scale != previousScale || _offset != previousOffset) {
      notifyListeners();
    }
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

  /// Aligns the participant-facing edge of a split viewport exactly with its
  /// stable world-space divider.
  ///
  /// Unlike [constrain], this is an explicit alignment operation rather than
  /// a one-sided guard. It is intended for entering a partitioned workspace:
  /// the left participant sees [BoardViewportHorizontalConstraint.worldBoundaryX]
  /// at the right edge of their region and the right participant sees it at
  /// the left edge. Subsequent pan and zoom operations remain free inside the
  /// assigned half and continue to use the regular one-sided constraint.
  void alignToHorizontalPartition({
    required Size viewportSize,
    required BoardViewportHorizontalConstraint horizontalConstraint,
    Rect? visibleScreenBounds,
  }) {
    if (viewportSize.isEmpty ||
        !viewportSize.width.isFinite ||
        !viewportSize.height.isFinite ||
        !horizontalConstraint.isValid ||
        !_scale.isFinite ||
        _scale <= 0) {
      return;
    }
    final visibleBounds = _safeVisibleBounds(viewportSize, visibleScreenBounds);
    final targetScreenX =
        horizontalConstraint.side == BoardViewportPartitionSide.left
        ? visibleBounds.right
        : visibleBounds.left;
    final alignedX =
        targetScreenX - horizontalConstraint.worldBoundaryX * _scale;
    if (!alignedX.isFinite) return;

    final previous = _offset;
    _offset = Offset(alignedX, _offset.dy);
    _clamp(
      viewportSize,
      visibleScreenBounds: visibleBounds,
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
