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

  /// Detects an explicit eraser tool.
  ///
  /// A Flutter [PointerDeviceKind.touch] never becomes destructive from
  /// radius, size or pressure. Several classroom panels report an ordinary
  /// finger with the same broad ellipse as a resting hand; treating that
  /// metadata as intent made selecting ink erase it at the same time. Touch
  /// fist erasing is therefore owned by the independent native
  /// `TOOL_TYPE_PALM` gate or the coherent 3+ contact cluster recognizer.
  bool isEraserContact(PointerEvent event) {
    return event.kind == PointerDeviceKind.invertedStylus;
  }

  /// Single Flutter touch contacts are never promoted to an eraser.
  ///
  /// Keep this policy boundary explicit so callers cannot accidentally
  /// reintroduce destructive radius-based promotion on a later MOVE packet.
  /// Native explicit palms and coherent touch clusters bypass this method
  /// through their dedicated, independently verified paths.
  bool shouldPromoteToEraser(
    PointerEvent event, {
    required PointerRole currentRole,
    required int activeNavigationTouches,
    required bool stylusCurrentlyActive,
  }) {
    return false;
  }

  /// Radius in logical screen pixels. It tracks the reported physical contact;
  /// normalized size can only refine a contact already established as broad.
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
    if (event.kind == PointerDeviceKind.invertedStylus) {
      return PointerRole.erase;
    }
    // Palm rejection outranks broad-touch erasing while this participant's
    // pen is down. Otherwise a reported palm radius would erase before the
    // stylus guard below gets a chance to ignore it.
    if (event.kind == PointerDeviceKind.touch && stylusCurrentlyActive) {
      return PointerRole.ignored;
    }
    if (isEraserContact(event)) return PointerRole.erase;
    if (event.kind == PointerDeviceKind.stylus) {
      if (tool == BoardTool.eraser) return PointerRole.erase;
      return _isSelectionTool(tool) ? PointerRole.select : PointerRole.ink;
    }

    if (event.kind == PointerDeviceKind.touch) {
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
