import 'package:flutter/material.dart';

/// A visual pictogram beside the existing action text.
/// The text remains the accessible name and can wrap on narrow displays.
class DiagnosticButtonLabel extends StatelessWidget {
  const DiagnosticButtonLabel(this.icon, this.label, {super.key});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 18)),
          const SizedBox(width: 6),
          Flexible(child: Text(label, textAlign: TextAlign.center)),
        ],
      );
}
