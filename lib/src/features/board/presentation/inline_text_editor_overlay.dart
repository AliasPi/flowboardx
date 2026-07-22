import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../domain/model/board_object.dart';
import '../../editor/editor_controller.dart';
import '../../editor/inline_text_editing_engine.dart';

/// Direct, keyboard-free correction layer for one converted text object.
///
/// Handwriting over a word replaces it after a short pause. A deliberate
/// horizontal stroke through words deletes them immediately. Ink remains only
/// a transient visual preview and is never committed to the whiteboard page.
class InlineTextEditorOverlay extends StatefulWidget {
  const InlineTextEditorOverlay({
    required this.controller,
    required this.objectId,
    required this.onDone,
    super.key,
  });

  final EditorController controller;
  final String objectId;
  final VoidCallback onDone;

  @override
  State<InlineTextEditorOverlay> createState() =>
      _InlineTextEditorOverlayState();
}

class _InlineTextEditorOverlayState extends State<InlineTextEditorOverlay> {
  static const Duration _recognitionPause = Duration(milliseconds: 760);
  final Map<int, List<Offset>> _activeStrokes = <int, List<Offset>>{};
  final List<List<Offset>> _pendingStrokes = <List<Offset>>[];
  List<List<Offset>> _recognizingStrokes = const <List<Offset>>[];
  Timer? _recognitionTimer;
  Future<void>? _recognitionFuture;
  int _recognitionEpoch = 0;
  bool _recognizing = false;
  bool _finishing = false;
  bool _offscreenExitScheduled = false;
  bool _doneSent = false;

  EditorController get controller => widget.controller;

  TextObject? get _value {
    final object = controller.page.objectById(widget.objectId);
    return object is TextObject ? object : null;
  }

  @override
  void didUpdateWidget(covariant InlineTextEditorOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.objectId != widget.objectId ||
        oldWidget.controller != widget.controller) {
      _flushDetachedPending(oldWidget.controller, oldWidget.objectId);
      _resetInk();
    }
  }

  @override
  void dispose() {
    _recognitionTimer?.cancel();
    _recognitionEpoch++;
    // A parent can remove the editor without using its Done action (for
    // example during navigation). Completed pen strokes must still be handed
    // to the recognition service instead of disappearing with this widget.
    _flushDetachedPending(controller, widget.objectId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    if (value == null) return const SizedBox.shrink();
    final objectRect = Rect.fromPoints(
      controller.viewport.worldToScreen(
        Offset(value.transform.x, value.transform.y),
      ),
      controller.viewport.worldToScreen(
        Offset(
          value.transform.x + value.transform.width,
          value.transform.y + value.transform.height,
        ),
      ),
    );
    final viewport = MediaQuery.sizeOf(context);
    // Inline correction is an explicit editing mode, so the transparent
    // capture area may safely extend beyond the current object. A generous,
    // viewport-relative append zone prevents long handwritten words from
    // being cut off before recognition can grow the text field.
    final appendZoneWidth = (viewport.width * .34).clamp(280.0, 560.0);
    final viewportRect = Offset.zero & viewport;
    final desiredCaptureRect = Rect.fromLTRB(
      objectRect.left - 18,
      objectRect.top - 18,
      objectRect.right + appendZoneWidth,
      objectRect.bottom + 56,
    );
    if (!desiredCaptureRect.overlaps(viewportRect)) {
      // A viewport move or window resize can move the edited object entirely
      // off-screen between frames. Flush completed handwriting before ending
      // the transient mode; otherwise the 760 ms recognition pause would be a
      // data-loss window. The guard also prevents one callback per rebuild.
      if (!_offscreenExitScheduled && !_doneSent) {
        _offscreenExitScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_finishEditing());
        });
      }
      return const SizedBox.shrink();
    }
    _offscreenExitScheduled = false;
    final captureRect = desiredCaptureRect.intersect(viewportRect);
    final scale = controller.viewport.scale;
    final objectOrigin = objectRect.topLeft - captureRect.topLeft;
    final toolbarWidth = math.max(1.0, math.min(640.0, viewport.width - 16));
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: math.max(
            8,
            math.min(objectRect.left, viewport.width - toolbarWidth - 8),
          ),
          top: math.max(78, objectRect.top - 58),
          width: toolbarWidth,
          child: Material(
            color: FlowboardColors.panel,
            elevation: 10,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 5, 5, 5),
              child: Row(
                children: [
                  const Icon(
                    Icons.draw_rounded,
                    size: 20,
                    color: FlowboardColors.mint,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Über ein Wort schreiben: ersetzen · Durchstreichen: löschen · '
                      'rechts weiterschreiben: anhängen',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                  if (_recognizing)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  IconButton(
                    tooltip: 'Textkorrektur beenden',
                    onPressed: _activeStrokes.isEmpty
                        ? () => unawaited(_finishEditing())
                        : null,
                    icon: const Icon(Icons.check_rounded),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned.fromRect(
          rect: captureRect,
          child: Semantics(
            label: 'Text direkt mit dem Stift korrigieren',
            container: true,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) => _onPointerDown(event, captureRect),
              onPointerMove: (event) => _onPointerMove(event, captureRect),
              onPointerUp: (event) => _onPointerUp(event, value),
              onPointerCancel: _onPointerCancel,
              child: CustomPaint(
                painter: _InlineCorrectionInkPainter(
                  strokes: <List<Offset>>[
                    ..._recognizingStrokes,
                    ..._pendingStrokes,
                    ..._activeStrokes.values,
                  ],
                  scale: scale,
                  objectOrigin: objectOrigin,
                  recognizing: _recognizing,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _onPointerDown(PointerDownEvent event, Rect captureRect) {
    if (!_supports(event.kind) || _recognizing) return;
    _recognitionTimer?.cancel();
    _activeStrokes[event.pointer] = <Offset>[
      _objectLocal(event.localPosition, captureRect),
    ];
    setState(() {});
  }

  void _onPointerMove(PointerMoveEvent event, Rect captureRect) {
    final points = _activeStrokes[event.pointer];
    if (points == null) return;
    final next = _objectLocal(event.localPosition, captureRect);
    if ((points.last - next).distance >= .75 / controller.viewport.scale) {
      points.add(next);
      setState(() {});
    }
  }

  void _onPointerUp(PointerUpEvent event, TextObject value) {
    final points = _activeStrokes.remove(event.pointer);
    if (points == null) return;
    if (points.length == 1) points.add(points.single + const Offset(.01, .01));
    if (InlineTextEditingEngine.isStrikeThrough(value, points)) {
      _pendingStrokes.clear();
      _recognitionTimer?.cancel();
      controller.applyInlineTextStrike(
        objectId: widget.objectId,
        localPoints: points,
      );
      setState(() {});
      return;
    }
    _pendingStrokes.add(List<Offset>.unmodifiable(points));
    _recognitionTimer = Timer(
      _recognitionPause,
      () => unawaited(_recognizePending()),
    );
    setState(() {});
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_activeStrokes.remove(event.pointer) != null) setState(() {});
  }

  Offset _objectLocal(Offset eventLocal, Rect captureRect) {
    final value = _value;
    if (value == null) return Offset.zero;
    final screen = captureRect.topLeft + eventLocal;
    final world = controller.viewport.screenToWorld(screen);
    return Offset(world.dx - value.transform.x, world.dy - value.transform.y);
  }

  Future<void> _recognizePending() async {
    final running = _recognitionFuture;
    if (running != null) {
      await running;
      return;
    }
    if (_pendingStrokes.isEmpty || !mounted) return;
    final submitted = List<List<Offset>>.unmodifiable(
      _pendingStrokes.map(List<Offset>.unmodifiable),
    );
    setState(() {
      _pendingStrokes.clear();
      _recognizingStrokes = submitted;
      _recognizing = true;
    });
    final epoch = _recognitionEpoch;
    final recognition = controller.applyInlineTextHandwriting(
      objectId: widget.objectId,
      localStrokes: submitted,
    );
    _recognitionFuture = recognition;
    try {
      await recognition;
    } finally {
      if (epoch == _recognitionEpoch) {
        if (identical(_recognitionFuture, recognition)) {
          _recognitionFuture = null;
        }
        if (mounted) {
          setState(() {
            _recognizingStrokes = const <List<Offset>>[];
            _recognizing = false;
          });
        }
      }
    }
  }

  Future<void> _finishEditing() async {
    if (_finishing || _doneSent) return;
    _finishing = true;
    _recognitionTimer?.cancel();
    try {
      // Await both already submitted recognition and any strokes still held
      // during the debounce pause. A loop covers a future extension where
      // input may be queued while recognition is in flight.
      do {
        await _recognizePending();
      } while (mounted && _pendingStrokes.isNotEmpty);
      if (mounted && !_doneSent) {
        _doneSent = true;
        widget.onDone();
      }
    } finally {
      _finishing = false;
    }
  }

  void _flushDetachedPending(
    EditorController targetController,
    String targetObjectId,
  ) {
    if (_pendingStrokes.isEmpty) return;
    final submitted = List<List<Offset>>.unmodifiable(
      _pendingStrokes.map(List<Offset>.unmodifiable),
    );
    _pendingStrokes.clear();
    unawaited(
      targetController.applyInlineTextHandwriting(
        objectId: targetObjectId,
        localStrokes: submitted,
      ),
    );
  }

  void _resetInk() {
    _recognitionTimer?.cancel();
    _recognitionEpoch++;
    _activeStrokes.clear();
    _pendingStrokes.clear();
    _recognizingStrokes = const <List<Offset>>[];
    _recognizing = false;
    _recognitionFuture = null;
    _finishing = false;
    _offscreenExitScheduled = false;
    _doneSent = false;
  }

  static bool _supports(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus ||
      kind == PointerDeviceKind.touch ||
      kind == PointerDeviceKind.mouse;
}

class _InlineCorrectionInkPainter extends CustomPainter {
  const _InlineCorrectionInkPainter({
    required this.strokes,
    required this.scale,
    required this.objectOrigin,
    required this.recognizing,
  });

  final List<List<Offset>> strokes;
  final double scale;
  final Offset objectOrigin;
  final bool recognizing;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = (recognizing ? FlowboardColors.blue : FlowboardColors.mint)
          .withValues(alpha: .88)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = math.max(2.5, 4 * scale);
    for (final points in strokes) {
      if (points.isEmpty) continue;
      final path = Path()
        ..moveTo(
          objectOrigin.dx + points.first.dx * scale,
          objectOrigin.dy + points.first.dy * scale,
        );
      for (final point in points.skip(1)) {
        path.lineTo(
          objectOrigin.dx + point.dx * scale,
          objectOrigin.dy + point.dy * scale,
        );
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _InlineCorrectionInkPainter oldDelegate) =>
      oldDelegate.strokes != strokes ||
      oldDelegate.scale != scale ||
      oldDelegate.objectOrigin != objectOrigin ||
      oldDelegate.recognizing != recognizing;
}
