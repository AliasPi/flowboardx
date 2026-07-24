import 'package:flutter/foundation.dart';

import '../../domain/model/board_object.dart';
import '../../domain/model/ink.dart';
import '../board/engine/ink_session_manager.dart';
import '../board/engine/input_policy.dart';

/// Per-person interaction state for a shared whiteboard document.
///
/// The document, command history and ink session manager intentionally remain
/// shared. Tool choices are not document content, however, and must therefore
/// not leak from one side of a two-person workspace to the other.
class BoardParticipantController extends ChangeNotifier {
  BoardParticipantController({
    required this.id,
    BoardTool tool = BoardTool.pen,
    ShapeKind activeShape = ShapeKind.rectangle,
    ActivePenStyle penStyle = const ActivePenStyle(
      colorArgb: 0xFF000000,
      width: 8,
    ),
  }) : _tool = tool,
       _activeShape = activeShape,
       _penStyle = penStyle;

  final String id;

  BoardTool _tool;
  ShapeKind _activeShape;
  ActivePenStyle _penStyle;
  bool _disposed = false;

  BoardTool get tool => _tool;
  ShapeKind get activeShape => _activeShape;
  ActivePenStyle get penStyle => _penStyle;

  bool get isSelectionTool =>
      _tool == BoardTool.selectRectangle || _tool == BoardTool.selectLasso;

  void setTool(BoardTool value) {
    var nextStyle = _penStyle;
    switch (value) {
      case BoardTool.pen:
        nextStyle = nextStyle.copyWith(type: InkToolType.normal);
      case BoardTool.marker:
        nextStyle = nextStyle.copyWith(type: InkToolType.marker);
      case BoardTool.dashedPen:
        nextStyle = nextStyle.copyWith(type: InkToolType.dashed);
      case BoardTool.straightLine:
        nextStyle = nextStyle.copyWith(type: InkToolType.straightLine);
      case BoardTool.eraser:
      // The eraser shares the thickness value with the last ink style, but
      // never changes the persisted stroke type.
      case BoardTool.selectRectangle ||
          BoardTool.selectLasso ||
          BoardTool.shape:
        break;
    }
    if (_tool == value && _samePenStyle(nextStyle, _penStyle)) return;
    _tool = value;
    _penStyle = nextStyle;
    notifyListeners();
  }

  /// Applies the predictable pen default used when the pen branch is opened.
  void selectDefaultPen() {
    const defaults = ActivePenStyle(
      colorArgb: 0xFF000000,
      width: 8,
      type: InkToolType.normal,
    );
    if (_tool == BoardTool.pen && _samePenStyle(_penStyle, defaults)) return;
    _tool = BoardTool.pen;
    _penStyle = defaults;
    notifyListeners();
  }

  void updatePen({int? colorArgb, double? width, InkToolType? type}) {
    final next = _penStyle.copyWith(
      colorArgb: colorArgb,
      width: width,
      type: type,
    );
    final nextTool = switch (next.type) {
      InkToolType.normal => BoardTool.pen,
      InkToolType.marker => BoardTool.marker,
      InkToolType.dashed => BoardTool.dashedPen,
      InkToolType.straightLine => BoardTool.straightLine,
    };
    if (_tool == nextTool && _samePenStyle(_penStyle, next)) return;
    _tool = nextTool;
    _penStyle = next;
    notifyListeners();
  }

  void updateEraserWidth(double width) {
    final safeWidth = width.isFinite ? width.clamp(.5, 80.0) : _penStyle.width;
    final next = _penStyle.copyWith(width: safeWidth);
    if (_tool == BoardTool.eraser && _samePenStyle(_penStyle, next)) return;
    _tool = BoardTool.eraser;
    _penStyle = next;
    notifyListeners();
  }

  void armShape(ShapeKind value) {
    if (_tool == BoardTool.shape && _activeShape == value) return;
    _activeShape = value;
    _tool = BoardTool.shape;
    notifyListeners();
  }

  void synchronize({
    required BoardTool tool,
    required ShapeKind activeShape,
    required ActivePenStyle penStyle,
  }) {
    if (_tool == tool &&
        _activeShape == activeShape &&
        _samePenStyle(_penStyle, penStyle)) {
      return;
    }
    _tool = tool;
    _activeShape = activeShape;
    _penStyle = penStyle;
    notifyListeners();
  }

  static bool _samePenStyle(ActivePenStyle a, ActivePenStyle b) =>
      a.colorArgb == b.colorArgb && a.width == b.width && a.type == b.type;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
