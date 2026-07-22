import '../model/document.dart';

abstract interface class DocumentCommand {
  String get label;
  WhiteboardDocument apply(WhiteboardDocument document);
}

final class CompositeDocumentCommand implements DocumentCommand {
  CompositeDocumentCommand({
    required this.label,
    required Iterable<DocumentCommand> commands,
  }) : commands = List.unmodifiable(commands);

  @override
  final String label;
  final List<DocumentCommand> commands;

  @override
  WhiteboardDocument apply(WhiteboardDocument document) =>
      commands.fold(document, (current, command) => command.apply(current));
}
