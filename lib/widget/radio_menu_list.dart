import 'package:flutter/material.dart';
import 'package:std_widget/selector.dart';

/// Displays a reusable list of mutually exclusive radio options.
class RadioMenuList extends StatelessWidget {
  final String groupValue;
  final Map<String, SelectorItem> items;
  final ValueChanged<String?> onChanged;

  const RadioMenuList({
    super.key,
    required this.groupValue,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicWidth(
      child: Column(
        children: [
          for (var entry in items.entries)
            RadioMenuButton<String>(
              style: ButtonStyle(
                overlayColor: WidgetStateProperty.resolveWith((states) {
                  // Remove focused color (when mouse is out of button)
                  if (states.contains(WidgetState.focused)) {
                    return Colors.transparent;
                  }
                  return null; // Default for other states
                }),
              ),
              value: entry.key,
              groupValue: groupValue,
              onChanged: onChanged,
              child: Text(entry.value.label),
            ),
        ],
      ),
    );
  }
}
