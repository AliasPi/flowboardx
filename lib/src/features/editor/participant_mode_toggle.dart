import 'package:flutter/material.dart';

enum EditorParticipantMode { onePerson, twoPeople }

/// Compact, pen-friendly switch used in the editor's top bar.
class ParticipantModeToggle extends StatelessWidget {
  const ParticipantModeToggle({
    required this.mode,
    required this.onChanged,
    super.key,
  });

  final EditorParticipantMode mode;
  final ValueChanged<EditorParticipantMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Arbeitsmodus',
      child: SegmentedButton<EditorParticipantMode>(
        key: const ValueKey('participant-mode-toggle'),
        showSelectedIcon: false,
        segments: const <ButtonSegment<EditorParticipantMode>>[
          ButtonSegment<EditorParticipantMode>(
            value: EditorParticipantMode.onePerson,
            icon: Icon(Icons.person_rounded),
            tooltip: 'Eine Person',
          ),
          ButtonSegment<EditorParticipantMode>(
            value: EditorParticipantMode.twoPeople,
            icon: Icon(Icons.people_alt_rounded),
            tooltip: 'Zwei Personen',
          ),
        ],
        selected: <EditorParticipantMode>{mode},
        onSelectionChanged: (selection) {
          if (selection.isNotEmpty) onChanged(selection.single);
        },
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(42, 42)),
          maximumSize: const WidgetStatePropertyAll(Size(46, 46)),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),
    );
  }
}
