import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import 'countdown_timer_controller.dart';

/// Toolbar action that opens the timer setup without covering the board after
/// the setup has been confirmed.
class CountdownTimerToolbarButton extends StatelessWidget {
  const CountdownTimerToolbarButton({
    required this.controller,
    required this.onShowLarge,
    this.showLabel = false,
    super.key,
  });

  final CountdownTimerController controller;
  final VoidCallback onShowLarge;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CountdownTimerState>(
      valueListenable: controller.liveState,
      builder: (context, state, _) {
        final label = state.alarmActive
            ? 'Alarm bestätigen'
            : state.status == CountdownTimerStatus.idle
            ? 'Timer'
            : formatCountdown(state.remaining);
        final icon = state.alarmActive
            ? Icons.notifications_active_rounded
            : state.isRunning
            ? Icons.timer_rounded
            : Icons.timer_outlined;
        void onPressed() {
          if (state.alarmActive) {
            // Alarm acknowledgement intentionally lives in the large panel.
            // This avoids an accidental toolbar tap silently stopping an alarm
            // while the acknowledgement UI is covered or off-screen.
            onShowLarge();
            return;
          }
          showCountdownTimerSetup(
            context,
            controller: controller,
            onShowLarge: onShowLarge,
          );
        }

        if (showLabel) {
          return TextButton.icon(
            key: const ValueKey('countdown-toolbar-button'),
            onPressed: onPressed,
            icon: Icon(
              icon,
              color: state.alarmActive ? FlowboardColors.warning : null,
            ),
            label: Text(label),
          );
        }
        return IconButton(
          key: const ValueKey('countdown-toolbar-button'),
          tooltip: state.alarmActive
              ? 'Alarm im großen Timerfenster bestätigen'
              : state.isRunning
              ? 'Timer: ${formatCountdown(state.remaining)}'
              : 'Timer einstellen',
          onPressed: onPressed,
          icon: Icon(
            icon,
            color: state.alarmActive ? FlowboardColors.warning : null,
          ),
        );
      },
    );
  }
}

Future<void> showCountdownTimerSetup(
  BuildContext context, {
  required CountdownTimerController controller,
  required VoidCallback onShowLarge,
}) => showDialog<void>(
  context: context,
  builder: (context) => CountdownTimerSetupDialog(
    controller: controller,
    onShowLarge: onShowLarge,
  ),
);

class CountdownTimerSetupDialog extends StatefulWidget {
  const CountdownTimerSetupDialog({
    required this.controller,
    required this.onShowLarge,
    super.key,
  });

  final CountdownTimerController controller;
  final VoidCallback onShowLarge;

  @override
  State<CountdownTimerSetupDialog> createState() =>
      _CountdownTimerSetupDialogState();
}

class _CountdownTimerSetupDialogState extends State<CountdownTimerSetupDialog> {
  static const int _maximumSeconds =
      23 * Duration.secondsPerHour + 59 * Duration.secondsPerMinute + 59;

  late int _editingSeconds = _initialSeconds();
  bool _dirty = false;
  bool _autoDismissScheduled = false;
  bool _routePopRequested = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleAutomaticPresentation);
    _handleAutomaticPresentation();
  }

  @override
  void didUpdateWidget(covariant CountdownTimerSetupDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleAutomaticPresentation);
    _autoDismissScheduled = false;
    _routePopRequested = false;
    widget.controller.addListener(_handleAutomaticPresentation);
    _handleAutomaticPresentation();
  }

  /// Never leave the setup dialog in front of the mandatory large display.
  ///
  /// This also covers a timer expiring while its setup dialog is still open:
  /// the alarm acknowledgement remains reachable only in the large panel.
  void _handleAutomaticPresentation() {
    if (_autoDismissScheduled ||
        widget.controller.state.presentationStage ==
            CountdownTimerPresentationStage.none) {
      return;
    }
    _autoDismissScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _routePopRequested) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isCurrent) return;
      _routePopRequested = true;
      widget.onShowLarge();
      Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleAutomaticPresentation);
    super.dispose();
  }

  int _initialSeconds() {
    final source =
        widget.controller.status == CountdownTimerStatus.idle ||
            widget.controller.status == CountdownTimerStatus.finished
        ? widget.controller.configuredDuration
        : widget.controller.remaining;
    return source.inSeconds.clamp(1, _maximumSeconds);
  }

  void _adjust(int delta) {
    setState(() {
      _editingSeconds = (_editingSeconds + delta).clamp(1, _maximumSeconds);
      _dirty = true;
    });
  }

  void _preset(int minutes) {
    setState(() {
      _editingSeconds = (minutes * 60).clamp(1, _maximumSeconds);
      _dirty = true;
    });
  }

  void _startOrPause() {
    // Starting a short countdown publishes the final-minute milestone
    // synchronously. Own the route pop here so its automatic callback cannot
    // pop the editor route a second time while this dialog animates out.
    _routePopRequested = true;
    if (widget.controller.isRunning && !_dirty) {
      widget.controller.pause();
    } else {
      if (_dirty ||
          widget.controller.isFinished ||
          widget.controller.configuredDuration == Duration.zero) {
        widget.controller.setDuration(Duration(seconds: _editingSeconds));
      }
      widget.controller.start();
    }
    if (widget.controller.state.presentationStage !=
        CountdownTimerPresentationStage.none) {
      widget.onShowLarge();
    }
    Navigator.of(context).pop();
  }

  void _showLarge() {
    _routePopRequested = true;
    if (_dirty) {
      widget.controller.setDuration(Duration(seconds: _editingSeconds));
    }
    widget.onShowLarge();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hours = _editingSeconds ~/ Duration.secondsPerHour;
    final minutes =
        (_editingSeconds ~/ Duration.secondsPerMinute) %
        Duration.minutesPerHour;
    final seconds = _editingSeconds % Duration.secondsPerMinute;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.timer_outlined, color: FlowboardColors.mint),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Timer',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Schließen',
                    onPressed: () {
                      _routePopRequested = true;
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                decoration: BoxDecoration(
                  color: FlowboardColors.background,
                  borderRadius: BorderRadius.circular(18),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 22,
                ),
                child: Text(
                  formatCountdown(Duration(seconds: _editingSeconds)),
                  key: const ValueKey('countdown-setup-value'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.displayMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final minutes in const <int>[1, 3, 5, 10, 15, 30])
                    ChoiceChip(
                      label: Text('$minutes min'),
                      selected: _editingSeconds == minutes * 60,
                      onSelected: (_) => _preset(minutes),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  _DurationStepper(
                    label: 'Stunden',
                    value: hours.toString().padLeft(2, '0'),
                    onDecrease: () => _adjust(-Duration.secondsPerHour),
                    onIncrease: () => _adjust(Duration.secondsPerHour),
                  ),
                  _DurationStepper(
                    label: 'Minuten',
                    value: minutes.toString().padLeft(2, '0'),
                    onDecrease: () => _adjust(-Duration.secondsPerMinute),
                    onIncrease: () => _adjust(Duration.secondsPerMinute),
                  ),
                  _DurationStepper(
                    label: 'Sekunden',
                    value: seconds.toString().padLeft(2, '0'),
                    onDecrease: () => _adjust(-10),
                    onIncrease: () => _adjust(10),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.end,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('countdown-setup-reset'),
                    onPressed: () {
                      widget.controller.reset();
                      setState(() {
                        _editingSeconds = widget
                            .controller
                            .configuredDuration
                            .inSeconds
                            .clamp(1, _maximumSeconds);
                        _dirty = false;
                      });
                    },
                    icon: const Icon(Icons.replay_rounded),
                    label: const Text('Zurücksetzen'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('countdown-setup-show-large'),
                    onPressed: _showLarge,
                    icon: const Icon(Icons.open_in_full_rounded),
                    label: const Text('Groß anzeigen'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('countdown-setup-start-pause'),
                    onPressed: _startOrPause,
                    icon: Icon(
                      widget.controller.isRunning && !_dirty
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                    label: Text(
                      widget.controller.isRunning && !_dirty
                          ? 'Pausieren'
                          : 'Starten',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DurationStepper extends StatelessWidget {
  const _DurationStepper({
    required this.label,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
  });

  final String label;
  final String value;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label $value',
      child: Container(
        width: 176,
        padding: const EdgeInsets.fromLTRB(7, 7, 7, 10),
        decoration: BoxDecoration(
          color: FlowboardColors.panelElevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: FlowboardColors.divider),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: FlowboardColors.textSecondary,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  tooltip: '$label verringern',
                  onPressed: onDecrease,
                  icon: const Icon(Icons.remove_rounded),
                ),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      value,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '$label erhöhen',
                  onPressed: onIncrease,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
