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

/// Owns the large timer as a root [OverlayEntry].
///
/// Rendering above the Navigator is essential for the alarm: a PDF dialog,
/// bottom sheet or editor progress veil must never cover its mandatory
/// acknowledgement. The entry itself remains hit-test transparent outside the
/// timer rectangle, so the board stays usable whenever no modal barrier is
/// present underneath it.
final class CountdownTimerOverlayPresenter {
  OverlayEntry? _entry;
  Rect? _lastRect;

  bool get isVisible => _entry != null;

  /// Inserts, or raises, the timer above every currently visible route.
  ///
  /// Returns `false` only when the caller's context has not reached an Overlay
  /// yet; state owners can retry in their next post-frame callback.
  bool show(
    BuildContext context, {
    required CountdownTimerController controller,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return false;
    _removeEntry();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) => Positioned.fill(
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            clipBehavior: Clip.none,
            children: [
              CountdownTimerOverlay(
                controller: controller,
                bounds: Rect.fromLTWH(
                  12,
                  84,
                  math.max(0, constraints.maxWidth - 24),
                  math.max(0, constraints.maxHeight - 96),
                ),
                initialRect: _lastRect,
                onRectChanged: (value) => _lastRect = value,
                onClose: () => hide(controller: controller),
              ),
            ],
          ),
        ),
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    return true;
  }

  /// Hides the panel unless an active alarm still requires confirmation.
  void hide({
    required CountdownTimerController controller,
    bool force = false,
  }) {
    if (!force && controller.isAlarmActive) return;
    _removeEntry();
  }

  void _removeEntry() {
    final entry = _entry;
    _entry = null;
    if (entry == null) return;
    entry.remove();
    entry.dispose();
  }

  void dispose() => _removeEntry();
}

/// Emits one request when a countdown enters its final minute and another when
/// it reaches the alarm state.
///
/// The edge-triggered behavior lets a teacher close the panel during the final
/// minute without it reopening on every one-second tick. Reaching `00:00` is a
/// distinct stage and therefore always requests the panel again for the
/// mandatory alarm acknowledgement.
class CountdownTimerAutoPresentation extends StatefulWidget {
  const CountdownTimerAutoPresentation({
    required this.controller,
    required this.onShowLarge,
    super.key,
  });

  final CountdownTimerController controller;
  final VoidCallback onShowLarge;

  @override
  State<CountdownTimerAutoPresentation> createState() =>
      _CountdownTimerAutoPresentationState();
}

class _CountdownTimerAutoPresentationState
    extends State<CountdownTimerAutoPresentation> {
  late CountdownTimerStatus _lastStatus = widget.controller.state.status;
  bool _finalMinuteRequested = false;
  bool _alarmRequested = false;
  int _postFrameRequestGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleCountdownChange);
    _requestForAlreadyActiveState();
  }

  @override
  void didUpdateWidget(covariant CountdownTimerAutoPresentation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleCountdownChange);
    _postFrameRequestGeneration++;
    _lastStatus = widget.controller.state.status;
    _finalMinuteRequested = false;
    _alarmRequested = false;
    widget.controller.addListener(_handleCountdownChange);
    _requestForAlreadyActiveState();
  }

  void _handleCountdownChange() {
    final state = widget.controller.state;
    if (state.status == CountdownTimerStatus.idle ||
        (_lastStatus == CountdownTimerStatus.finished && state.isRunning)) {
      _finalMinuteRequested = false;
      _alarmRequested = false;
    }
    _lastStatus = state.status;
    final stage = state.presentationStage;
    if (stage == CountdownTimerPresentationStage.none) return;
    if (stage == CountdownTimerPresentationStage.finalMinute) {
      if (_finalMinuteRequested) return;
      _finalMinuteRequested = true;
    } else {
      if (_alarmRequested) return;
      _alarmRequested = true;
    }
    // A synchronous milestone supersedes any initial post-frame request.
    _postFrameRequestGeneration++;
    widget.onShowLarge();
  }

  void _requestForAlreadyActiveState() {
    final stage = widget.controller.state.presentationStage;
    if (stage == CountdownTimerPresentationStage.none) return;
    if (stage == CountdownTimerPresentationStage.finalMinute) {
      _finalMinuteRequested = true;
    } else {
      _alarmRequested = true;
    }
    final controller = widget.controller;
    final generation = ++_postFrameRequestGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _postFrameRequestGeneration ||
          !identical(widget.controller, controller) ||
          controller.state.presentationStage ==
              CountdownTimerPresentationStage.none) {
        return;
      }
      widget.onShowLarge();
    });
  }

  @override
  void dispose() {
    _postFrameRequestGeneration++;
    widget.controller.removeListener(_handleCountdownChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
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

/// Minimal timer-only surface rendered while Android owns the PiP window.
///
/// Controls and board chrome deliberately stay out of this tree. Tapping the
/// system PiP window expands the activity, where the synchronized large panel
/// exposes pause, reset and alarm acknowledgement again.
class CountdownTimerPictureInPictureView extends StatelessWidget {
  const CountdownTimerPictureInPictureView({
    required this.controller,
    super.key,
  });

  final CountdownTimerController controller;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const ValueKey('countdown-picture-in-picture'),
      color: FlowboardColors.background,
      child: ValueListenableBuilder<CountdownTimerState>(
        valueListenable: controller.liveState,
        builder: (context, state, _) {
          final urgent =
              state.isRunning && state.remaining <= const Duration(seconds: 30);
          final color = state.isFinished || urgent
              ? FlowboardColors.warning
              : FlowboardColors.textPrimary;
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
              child: FittedBox(
                fit: BoxFit.contain,
                child: Semantics(
                  liveRegion: true,
                  label:
                      'Verbleibende Zeit ${formatCountdown(state.remaining)}',
                  child: Text(
                    formatCountdown(state.remaining),
                    key: const ValueKey('countdown-picture-in-picture-value'),
                    maxLines: 1,
                    style: TextStyle(
                      color: color,
                      fontSize: 92,
                      height: .9,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
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
                child: ValueListenableBuilder<CountdownTimerState>(
                  valueListenable: widget.controller.liveState,
                  builder: (context, state, _) => _CountdownDisplay(
                    controller: widget.controller,
                    state: state,
                  ),
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
                      ValueListenableBuilder<CountdownTimerState>(
                        valueListenable: widget.controller.liveState,
                        builder: (context, state, _) => IconButton(
                          key: const ValueKey('countdown-overlay-close'),
                          tooltip: state.alarmActive
                              ? 'Alarm zuerst bestätigen'
                              : 'Große Timeranzeige schließen',
                          onPressed: state.alarmActive ? null : widget.onClose,
                          icon: const Icon(Icons.close_rounded),
                        ),
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
  const _CountdownDisplay({required this.controller, required this.state});

  final CountdownTimerController controller;
  final CountdownTimerState state;

  @override
  Widget build(BuildContext context) {
    final urgent =
        state.isRunning && state.remaining <= const Duration(seconds: 30);
    final finished = state.isFinished;
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
                          'Verbleibende Zeit ${formatCountdown(state.remaining)}',
                      child: Text(
                        formatCountdown(state.remaining),
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
                  if (state.alarmActive) ...[
                    FilledButton.icon(
                      key: const ValueKey(
                        'countdown-overlay-acknowledge-alarm',
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: FlowboardColors.warning,
                        foregroundColor: FlowboardColors.background,
                      ),
                      onPressed: controller.acknowledgeAlarm,
                      icon: const Icon(Icons.notifications_off_rounded),
                      label: const Text('Alarm stoppen'),
                    ),
                    const SizedBox(width: 10),
                  ] else ...[
                    IconButton.filledTonal(
                      key: const ValueKey('countdown-overlay-start-pause'),
                      tooltip: state.isRunning ? 'Pausieren' : 'Starten',
                      onPressed: state.isRunning
                          ? controller.pause
                          : controller.start,
                      icon: Icon(
                        state.isRunning
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  if (!state.alarmActive)
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
