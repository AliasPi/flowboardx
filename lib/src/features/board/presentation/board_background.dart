import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';

class BoardBackgroundPainter extends CustomPainter {
  const BoardBackgroundPainter({
    required this.viewportScale,
    required this.viewportOffset,
    this.pageExtent = const Size(1920, 1080),
  });

  final double viewportScale;
  final Offset viewportOffset;
  final Size pageExtent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = FlowboardColors.canvas,
    );

    final minorStep = 32.0 * viewportScale;
    if (minorStep >= 8) {
      final minor = Paint()
        ..color = const Color(0xFFDFE2DE).withValues(alpha: 0.36)
        ..strokeWidth = 1;
      final originX = viewportOffset.dx % minorStep;
      final originY = viewportOffset.dy % minorStep;
      for (var x = originX; x < size.width; x += minorStep) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), minor);
      }
      for (var y = originY; y < size.height; y += minorStep) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), minor);
      }
    }

    final screenCell = Size(
      pageExtent.width * viewportScale,
      pageExtent.height * viewportScale,
    );
    if (screenCell.width <= 0 || screenCell.height <= 0) return;
    final major = Paint()
      ..color = const Color(0xFF97A09A).withValues(alpha: 0.35)
      ..strokeWidth = 1.4;
    for (var col = -1; col <= 2; col++) {
      final x = viewportOffset.dx + col * screenCell.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), major);
    }
    for (var row = -1; row <= 2; row++) {
      final y = viewportOffset.dy + row * screenCell.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), major);
    }

    final boardRect = Rect.fromLTRB(
      viewportOffset.dx - screenCell.width,
      viewportOffset.dy - screenCell.height,
      viewportOffset.dx + screenCell.width * 2,
      viewportOffset.dy + screenCell.height * 2,
    );
    final viewport = Offset.zero & size;
    final visible = boardRect.intersect(viewport);
    final outside = Paint()
      ..color = const Color(0xFF17201F).withValues(alpha: .16);
    if (visible.isEmpty) {
      canvas.drawRect(viewport, outside);
    } else {
      if (visible.top > 0) {
        canvas.drawRect(Rect.fromLTRB(0, 0, size.width, visible.top), outside);
      }
      if (visible.bottom < size.height) {
        canvas.drawRect(
          Rect.fromLTRB(0, visible.bottom, size.width, size.height),
          outside,
        );
      }
      if (visible.left > 0) {
        canvas.drawRect(
          Rect.fromLTRB(0, visible.top, visible.left, visible.bottom),
          outside,
        );
      }
      if (visible.right < size.width) {
        canvas.drawRect(
          Rect.fromLTRB(visible.right, visible.top, size.width, visible.bottom),
          outside,
        );
      }
    }
    canvas.drawRect(
      boardRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF58635F).withValues(alpha: .48),
    );
  }

  @override
  bool shouldRepaint(covariant BoardBackgroundPainter oldDelegate) =>
      oldDelegate.viewportScale != viewportScale ||
      oldDelegate.viewportOffset != viewportOffset ||
      oldDelegate.pageExtent != pageExtent;
}
