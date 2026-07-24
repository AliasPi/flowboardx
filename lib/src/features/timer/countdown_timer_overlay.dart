import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import 'countdown_timer_controller.dart';

/// Geometry helpers shared by the overlay and its tests.
abstract final class CountdownOverlayGeometry {
  static const Size defaultSize = Size(430, 220);
  static const Size minimumSize = Size(300, 176);

  static Rect initialRect(Rect bounds) {
    final width = math.min(defaultSize.width, bounds.width);
    final height = math.min(defaultSize.height, bounds.height);
    return constrain(
      Rect.fromLTWH(
        bounds.center.dx - width / 2,
        bounds.top + math.min(112, math.max(0, bounds.height - height)),
        width,
        height,
      ),
      bounds,
    );
  }

  static Rect constrain(Rect rect, Rect bounds) {
    if (bounds.isEmpty) return Rect.zero;
    final minWidth = math.min(minimumSize.width, bounds.width);
    final minHeight = math.min(minimumSize.height, bounds.height);
    final width = rect.width.clamp(minWidth, bounds.width);
    final height = rect.height.clamp(minHeight, bounds.height);
    final left = rect.left.clamp(bounds.left, bounds.right - width);
    final top = rect.top.clamp(bounds.top, bounds.bottom - height);
    return Rect.fromLTWH(left, top, width, height);
  }

  static Rect resizeBottomRight(Rect rect, Offset delta, Rect bounds) =>
      constrain(
        Rect.fromLTWH(
          rect.left,
          rect.top,
          rect.width + delta.dx,
          rect.height + delta.dy,
        ),
        bounds,
      );
}

/// Large, draggable countdown display for use as a direct child of a [Stack].
///
/// Only the current panel rectangle participates in hit testing. Writing and
/// gestures outside the visible timer continue to reach the board underneath.
class CountdownTimerOverlay extends StatefulWidget {
  const CountdownTimerOverlay({
    required this.controller,
    required this.bounds,
    required this.onClose,
    this.initialRect,
    this.onRectChanged,
    super.key,
  });

  final CountdownTimerController controller;
  final Rect bounds;
  final Rect? initialRect;
  final VoidCallback onClose;
  final ValueChanged<Rect>? onRectChanged;

  @override
  State<CountdownTimerOverlay> createState() => _CountdownTimerOverlayState();
}

class _CountdownTimerOverlayState extends State<CountdownTimerOverlay> {
  late Rect _rect = CountdownOverlayGeometry.constrain(
    widget.initialRect ?? CountdownOverlayGeometry.initialRect(widget.bounds),
    widget.bounds,
  );

  @override
  void didUpdateWidget(covariant CountdownTimerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bounds != widget.bounds) {
      _updateRect(
        CountdownOverlayGeometry.constrain(_rect, widget.bounds),
        report: false,
      );
    }
  }

  void _updateRect(Rect value, {bool report = true}) {
    if (value == _rect) return;
    setState(() => _rect = value);
    if (report) widget.onRectChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fromRect(
      rect: _rect,
      child: RepaintBoundary(
        key: const ValueKey('countdown-large-overlay'),
        child: Material(
          elevation: 18,
          shadowColor: Colors.black54,
          color: FlowboardColors.panel.withValues(alpha: .96),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(
              color: FlowboardColors.mint.withValues(alpha: .72),
              width: 1.5,
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: widget.controller,
                  builder: (context, _) =>
                      _CountdownDisplay(controller: widget.controller),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 46,
                child: GestureDetector(
                  key: const ValueKey('countdown-overlay-drag-handle'),
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) => _updateRect(
                    CountdownOverlayGeometry.constrain(
                      _rect.shift(details.delta),
                      widget.bounds,
                    ),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 14),
                      const Icon(
                        Icons.drag_indicator_rounded,
                        size: 21,
                        color: FlowboardColors.textSecondary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Timer',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: FlowboardColors.textSecondary,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        key: const ValueKey('countdown-overlay-close'),
                        tooltip: 'Große Timeranzeige schließen',
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close_rounded),
                      ),
                      const SizedBox(width: 2),
                    ],
                  ),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                width: 54,
                height: 54,
                child: GestureDetector(
                  key: const ValueKey('countdown-overlay-resize-handle'),
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) => _updateRect(
                    CountdownOverlayGeometry.resizeBottomRight(
                      _rect,
                      details.delta,
                      widget.bounds,
                    ),
                  ),
                  child: const Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(
                        Icons.open_in_full_rounded,
                        size: 24,
                        color: FlowboardColors.mint,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountdownDisplay extends StatelessWidget {
  const _CountdownDisplay({required this.controller});

  final CountdownTimerController controller;

  @override
  Widget build(BuildContext context) {
    final urgent =
        controller.isRunning &&
        controller.remaining <= const Duration(seconds: 30);
    final finished = controller.isFinished;
    final color = finished || urgent
        ? FlowboardColors.warning
        : FlowboardColors.textPrimary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 205;
        return Padding(
          padding: EdgeInsets.fromLTRB(24, compact ? 41 : 48, 24, 14),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: Semantics(
                      liveRegion: true,
                      label:
                          'Verbleibende Zeit ${formatCountdown(controller.remaining)}',
                      child: Text(
                        formatCountdown(controller.remaining),
                        key: const ValueKey('countdown-large-value'),
                        maxLines: 1,
                        style: TextStyle(
                          color: color,
                          fontSize: 86,
                          height: .92,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (!compact) const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filledTonal(
                    key: const ValueKey('countdown-overlay-start-pause'),
                    tooltip: controller.isRunning ? 'Pausieren' : 'Starten',
                    onPressed: controller.isRunning
                        ? controller.pause
                        : controller.start,
                    icon: Icon(
                      controller.isRunning
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton(
                    key: const ValueKey('countdown-overlay-reset'),
                    tooltip: 'Zurücksetzen',
                    onPressed: controller.reset,
                    icon: const Icon(Icons.replay_rounded),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
