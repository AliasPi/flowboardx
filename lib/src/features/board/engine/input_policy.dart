import 'package:flutter/gestures.dart';

import '../../input/eraser_contact_geometry.dart';
import '../../input/touch_contact_classifier.dart';

enum PointerRole { ink, erase, navigate, select, ignored }

enum BoardTool {
  pen,
  marker,
  dashedPen,
  straightLine,
  eraser,
  selectRectangle,
  selectLasso,
  shape,
}

class PointerPolicy {
  const PointerPolicy({
    this.palmRadiusThreshold = 20,
    this.palmSizeThreshold = 0.24,
  });

  final double palmRadiusThreshold;
  final double palmSizeThreshold;

  TouchContactClassifier get _contactClassifier => TouchContactClassifier(
    palmRadiusThreshold: palmRadiusThreshold,
    palmSizeThreshold: palmSizeThreshold,
  );

  /// Detects a deliberate board-eraser contact without treating ordinary
  /// pressure as a palm. Android's normalized [PointerEvent.size] is important
  /// because a number of large displays report zero for both radii.
  bool isEraserContact(PointerEvent event) {
    if (event.kind == PointerDeviceKind.invertedStylus) return true;
    return _contactClassifier.isBroadTouch(event);
  }

  /// Promotes a contact when Android reports its real footprint only after
  /// pointer-down. Established two-finger navigation is intentionally never
  /// promoted, which prevents a zoom gesture from becoming destructive.
  bool shouldPromoteToEraser(
    PointerEvent event, {
    required PointerRole currentRole,
    required int activeNavigationTouches,
  }) {
    if (event.kind != PointerDeviceKind.touch ||
        (currentRole != PointerRole.navigate &&
            currentRole != PointerRole.select &&
            currentRole != PointerRole.ignored)) {
      return false;
    }
    if (currentRole == PointerRole.navigate &&
        activeNavigationTouches > 1 &&
        !_contactClassifier.isStrongBroadTouch(event)) {
      return false;
    }
    return isEraserContact(event);
  }

  /// Radius in logical screen pixels. It tracks the reported contact while a
  /// bounded fallback maps Android's normalized size to a useful fist eraser.
  double eraserRadiusFor(PointerEvent event) {
    return _contactClassifier.eraserRadiusFor(event);
  }

  List<EraserBrushStamp> eraserFootprintFor(
    PointerEvent event, {
    required Offset center,
  }) {
    return _contactClassifier.eraserFootprintFor(event, center: center);
  }

  PointerRole classifyDown(
    PointerDownEvent event, {
    required BoardTool tool,
    required bool selectionActive,
    required bool stylusCurrentlyActive,
    required int activeNavigationTouches,
    bool fingerDrawingEnabled = false,
  }) {
    if (isEraserContact(event)) return PointerRole.erase;
    if (event.kind == PointerDeviceKind.stylus) {
      if (tool == BoardTool.eraser) return PointerRole.erase;
      return _isSelectionTool(tool) ? PointerRole.select : PointerRole.ink;
    }

    if (event.kind == PointerDeviceKind.touch) {
      // Small contacts arriving while a pen is down are almost always fingers
      // resting on the panel. A deliberate broad edge still remains an eraser.
      if (stylusCurrentlyActive) return PointerRole.ignored;
      if (_isSelectionTool(tool) || selectionActive) return PointerRole.select;
      if (fingerDrawingEnabled &&
          activeNavigationTouches == 0 &&
          _isInkTool(tool)) {
        return PointerRole.ink;
      }
      return PointerRole.navigate;
    }

    if (event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.trackpad) {
      if ((event.buttons & kSecondaryMouseButton) != 0) {
        return PointerRole.navigate;
      }
      if (tool == BoardTool.eraser) return PointerRole.erase;
      return _isSelectionTool(tool) ? PointerRole.select : PointerRole.ink;
    }
    return PointerRole.ignored;
  }

  bool _isSelectionTool(BoardTool tool) =>
      tool == BoardTool.selectRectangle || tool == BoardTool.selectLasso;

  bool _isInkTool(BoardTool tool) =>
      tool == BoardTool.pen ||
      tool == BoardTool.marker ||
      tool == BoardTool.dashedPen ||
      tool == BoardTool.straightLine;
}
