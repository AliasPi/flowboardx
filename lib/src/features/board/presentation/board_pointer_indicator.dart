import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../input/eraser_contact_geometry.dart';
import '../engine/input_policy.dart';

enum BoardPointerIndicatorKind { ink, eraser, selection, shape }

@immutable
final class BoardPointerIndicator {
  const BoardPointerIndicator({
    required this.pointer,
    required this.position,
    required this.kind,
    required this.radius,
  });

  final int pointer;
  final Offset position;
  final BoardPointerIndicatorKind kind;
  final double radius;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BoardPointerIndicator &&
          pointer == other.pointer &&
          position == other.position &&
          kind == other.kind &&
          radius == other.radius;

  @override
  int get hashCode => Object.hash(pointer, position, kind, radius);
}

/// Paints only the live tool contact markers.
///
/// The board owns a separate notifier for these snapshots, so high-frequency
/// pointer moves repaint this small overlay without rebuilding the document,
/// scene, or selection layers.
final class BoardPointerIndicatorPainter extends CustomPainter {
  const BoardPointerIndicatorPainter({
    required this.indicators,
    required this.hoverPosition,
    required this.tool,
    required this.brushWidth,
    required this.viewportScale,
  });

  final List<BoardPointerIndicator> indicators;
  final Offset? hoverPosition;
  final BoardTool tool;
  final double brushWidth;
  final double viewportScale;

  @override
  void paint(Canvas canvas, Size size) {
    if (indicators.isNotEmpty) {
      for (final indicator in indicators) {
        _paintIndicator(canvas, indicator);
      }
      return;
    }
    final hover = hoverPosition;
    if (hover == null) return;
    final kind = switch (tool) {
      BoardTool.eraser => BoardPointerIndicatorKind.eraser,
      BoardTool.selectRectangle ||
      BoardTool.selectLasso => BoardPointerIndicatorKind.selection,
      BoardTool.shape => BoardPointerIndicatorKind.shape,
      BoardTool.pen ||
      BoardTool.marker ||
      BoardTool.dashedPen ||
      BoardTool.straightLine => BoardPointerIndicatorKind.ink,
    };
    _paintIndicator(
      canvas,
      BoardPointerIndicator(
        pointer: -1,
        position: hover,
        kind: kind,
        radius: _defaultRadius(kind),
      ),
    );
  }

  double _defaultRadius(BoardPointerIndicatorKind kind) {
    if (kind == BoardPointerIndicatorKind.selection ||
        kind == BoardPointerIndicatorKind.shape) {
      return 7;
    }
    return EraserContactGeometry.cursorScreenRadius(
      logicalWidth: brushWidth,
      viewportScale: viewportScale,
    );
  }

  void _paintIndicator(Canvas canvas, BoardPointerIndicator indicator) {
    final radius = indicator.radius.isFinite
        ? indicator.radius.clamp(.5, 160.0)
        : _defaultRadius(indicator.kind);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (indicator.kind) {
      case BoardPointerIndicatorKind.ink:
        paint
          ..color = FlowboardColors.mint.withValues(alpha: .82)
          ..strokeWidth = 1.25;
        canvas.drawCircle(indicator.position, radius, paint);
      case BoardPointerIndicatorKind.eraser:
        paint
          ..color = FlowboardColors.warning.withValues(alpha: .9)
          ..strokeWidth = 1.6;
        canvas.drawCircle(indicator.position, radius, paint);
      case BoardPointerIndicatorKind.selection:
        paint
          ..color = FlowboardColors.blue.withValues(alpha: .9)
          ..strokeWidth = 1.4;
        canvas.drawCircle(indicator.position, radius, paint);
        canvas.drawLine(
          indicator.position - Offset(radius + 3, 0),
          indicator.position + Offset(radius + 3, 0),
          paint,
        );
        canvas.drawLine(
          indicator.position - Offset(0, radius + 3),
          indicator.position + Offset(0, radius + 3),
          paint,
        );
      case BoardPointerIndicatorKind.shape:
        paint
          ..color = FlowboardColors.mint.withValues(alpha: .88)
          ..strokeWidth = 1.4;
        canvas.drawCircle(indicator.position, radius, paint);
        canvas.drawLine(
          indicator.position - Offset(radius + 2, 0),
          indicator.position + Offset(radius + 2, 0),
          paint,
        );
        canvas.drawLine(
          indicator.position - Offset(0, radius + 2),
          indicator.position + Offset(0, radius + 2),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(covariant BoardPointerIndicatorPainter oldDelegate) =>
      !listEquals(oldDelegate.indicators, indicators) ||
      oldDelegate.hoverPosition != hoverPosition ||
      oldDelegate.tool != tool ||
      oldDelegate.brushWidth != brushWidth ||
      oldDelegate.viewportScale != viewportScale;
}
