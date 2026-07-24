import 'package:flutter_test/flutter_test.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/engine/input_policy.dart';
import 'package:flowboard_x/src/features/editor/board_participant_controller.dart';

void main() {
  test('participants keep independent tool and pen choices', () {
    final left = BoardParticipantController(id: 'left');
    final right = BoardParticipantController(id: 'right');
    addTearDown(left.dispose);
    addTearDown(right.dispose);

    left.updatePen(colorArgb: 0xFFFF0000, width: 14, type: InkToolType.marker);
    right.setTool(BoardTool.selectLasso);

    expect(left.tool, BoardTool.marker);
    expect(left.penStyle.colorArgb, 0xFFFF0000);
    expect(left.penStyle.width, 14);
    expect(right.tool, BoardTool.selectLasso);
    expect(right.penStyle.colorArgb, 0xFF000000);
    expect(right.penStyle.width, 8);
  });

  test('opening pen restores normal black eight pixel default', () {
    final participant = BoardParticipantController(id: 'left')
      ..updatePen(colorArgb: 0xFF2196F3, width: 20, type: InkToolType.dashed)
      ..selectDefaultPen();
    addTearDown(participant.dispose);

    expect(participant.tool, BoardTool.pen);
    expect(participant.penStyle.colorArgb, 0xFF000000);
    expect(participant.penStyle.width, 8);
    expect(participant.penStyle.type, InkToolType.normal);
  });

  test('participants keep independent stylus eraser thicknesses', () {
    final left = BoardParticipantController(id: 'left')..updateEraserWidth(2);
    final right = BoardParticipantController(id: 'right')
      ..updateEraserWidth(32);
    addTearDown(left.dispose);
    addTearDown(right.dispose);

    expect(left.tool, BoardTool.eraser);
    expect(left.penStyle.width, 2);
    expect(right.tool, BoardTool.eraser);
    expect(right.penStyle.width, 32);

    left.updateEraserWidth(12);
    expect(left.penStyle.width, 12);
    expect(right.penStyle.width, 32);
  });

  test('shape choice is local and retained', () {
    final participant = BoardParticipantController(id: 'right')
      ..armShape(ShapeKind.triangle);
    addTearDown(participant.dispose);

    expect(participant.tool, BoardTool.shape);
    expect(participant.activeShape, ShapeKind.triangle);
  });
}
