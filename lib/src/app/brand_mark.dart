import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';

class FlowboardMark extends StatelessWidget {
  const FlowboardMark({super.key, this.size = 44, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Flowboard X',
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _FlowboardMarkPainter(color ?? FlowboardColors.mint),
      ),
    );
  }
}

class _FlowboardMarkPainter extends CustomPainter {
  const _FlowboardMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final scale = size.shortestSide / 48;
    final glow = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 7 * scale);
    canvas.drawCircle(center, 19 * scale, glow);

    final gear = Path();
    for (var i = 0; i < 16; i++) {
      final angle = -math.pi / 2 + i * math.pi / 8;
      final radius = (i.isEven ? 17 : 13.5) * scale;
      final point = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      if (i == 0) {
        gear.moveTo(point.dx, point.dy);
      } else {
        gear.lineTo(point.dx, point.dy);
      }
    }
    gear.close();
    canvas.drawPath(gear, Paint()..color = color.withValues(alpha: 0.82));
    canvas.drawCircle(
      center,
      7.5 * scale,
      Paint()..color = const Color(0xFF18201F),
    );

    final pen = Paint()
      ..color = Colors.white
      ..strokeWidth = 5.2 * scale
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      center + Offset(-10, 12) * scale,
      center + Offset(10, -12) * scale,
      pen,
    );
    final nib = Path()
      ..moveTo(center.dx - 14 * scale, center.dy + 16 * scale)
      ..lineTo(center.dx - 8 * scale, center.dy + 5 * scale)
      ..lineTo(center.dx - 3 * scale, center.dy + 10 * scale)
      ..close();
    canvas.drawPath(nib, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _FlowboardMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}
