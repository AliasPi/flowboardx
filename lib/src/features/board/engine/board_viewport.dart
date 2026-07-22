import 'package:flutter/material.dart';

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

  void panBy(Offset delta, Size viewportSize) {
    _offset += delta;
    _clamp(viewportSize);
    notifyListeners();
  }

  void zoomAt({
    required double factor,
    required Offset focalPoint,
    required Size viewportSize,
  }) {
    if (!factor.isFinite || factor <= 0) return;
    final worldFocal = screenToWorld(focalPoint);
    _scale = (_scale * factor).clamp(minScale, maxScale);
    _offset = focalPoint - worldFocal * _scale;
    _clamp(viewportSize);
    notifyListeners();
  }

  void centerOn(Offset worldPosition, Size viewportSize) {
    if (!worldPosition.dx.isFinite ||
        !worldPosition.dy.isFinite ||
        viewportSize.isEmpty) {
      return;
    }
    _offset = viewportSize.center(Offset.zero) - worldPosition * _scale;
    _clamp(viewportSize);
    notifyListeners();
  }

  void _clamp(Size viewportSize) {
    // Keep at least 12% of the complete 3x3 board visible. This prevents
    // losing the canvas without forcing any edge docking behavior in the UI.
    final visibleMarginX = viewportSize.width * 0.12;
    final visibleMarginY = viewportSize.height * 0.12;
    final left = worldBounds.left * _scale + _offset.dx;
    final right = worldBounds.right * _scale + _offset.dx;
    final top = worldBounds.top * _scale + _offset.dy;
    final bottom = worldBounds.bottom * _scale + _offset.dy;
    if (right < visibleMarginX) {
      _offset = Offset(_offset.dx + visibleMarginX - right, _offset.dy);
    }
    if (left > viewportSize.width - visibleMarginX) {
      _offset = Offset(
        _offset.dx + viewportSize.width - visibleMarginX - left,
        _offset.dy,
      );
    }
    if (bottom < visibleMarginY) {
      _offset = Offset(_offset.dx, _offset.dy + visibleMarginY - bottom);
    }
    if (top > viewportSize.height - visibleMarginY) {
      _offset = Offset(
        _offset.dx,
        _offset.dy + viewportSize.height - visibleMarginY - top,
      );
    }
  }
}
