import 'package:flutter/gestures.dart';

enum PointerRole { ink, erase, navigate, select, ignored }

enum BoardTool {
  pen,
  marker,
  dashedPen,
  straightLine,
  selectRectangle,
  selectLasso,
  shape,
}

class PointerPolicy {
  const PointerPolicy({
    this.palmRadiusThreshold = 22,
    this.palmPressureThreshold = 0.82,
  });

  final double palmRadiusThreshold;
  final double palmPressureThreshold;

  PointerRole classifyDown(
    PointerDownEvent event, {
    required BoardTool tool,
    required bool selectionActive,
    required bool stylusCurrentlyActive,
    required int activeNavigationTouches,
  }) {
    if (event.kind == PointerDeviceKind.invertedStylus) {
      return PointerRole.erase;
    }
    if (event.kind == PointerDeviceKind.stylus) {
      return _isSelectionTool(tool) ? PointerRole.select : PointerRole.ink;
    }

    if (event.kind == PointerDeviceKind.touch) {
      final radius = event.radiusMajor.isFinite ? event.radiusMajor : 0;
      final hasPressureRange =
          event.pressureMax.isFinite &&
          event.pressureMin.isFinite &&
          event.pressureMax > event.pressureMin;
      final normalizedPressure = hasPressureRange
          ? (event.pressure - event.pressureMin) /
                (event.pressureMax - event.pressureMin)
          : 0.0;
      final isPalm =
          radius >= palmRadiusThreshold ||
          (radius >= palmRadiusThreshold * .6 &&
              normalizedPressure >= palmPressureThreshold);
      if (isPalm) return PointerRole.erase;

      // Small contacts arriving while a pen is down are almost always fingers
      // resting on the panel. A deliberate broad edge still remains an eraser.
      if (stylusCurrentlyActive) return PointerRole.ignored;
      if (_isSelectionTool(tool) || selectionActive) return PointerRole.select;
      return PointerRole.navigate;
    }

    if (event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.trackpad) {
      if ((event.buttons & kSecondaryMouseButton) != 0) {
        return PointerRole.navigate;
      }
      return _isSelectionTool(tool) ? PointerRole.select : PointerRole.ink;
    }
    return PointerRole.ignored;
  }

  bool _isSelectionTool(BoardTool tool) =>
      tool == BoardTool.selectRectangle || tool == BoardTool.selectLasso;
}
