// File purpose: Provides the application's reusable styled text input widget.

import 'package:flutter/material.dart';
import 'package:reiri_app_core/reiri_deco.dart';
import 'package:std_widget/reiri_icons.dart';

/// Project-local text input that uses the shared Reiri decoration without
/// depending on the broken std_widget TextInput implementation.
class ReiriTextInput extends StatefulWidget {
  const ReiriTextInput({
    super.key,
    this.text,
    this.hint,
    this.width,
    this.align = TextAlign.start,
    this.margin,
    this.padding,
    this.decoration,
    this.maxLength,
    this.passwd = false,
    this.onChanged,
    this.onSubmitted,
  });

  final String? text;
  final String? hint;
  final double? width;
  final TextAlign align;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final Decoration? decoration;
  final bool passwd;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<ReiriTextInput> createState() => _ReiriTextInputState();
}

/// Manages focus, validation, and visibility for a Reiri text field.
class _ReiriTextInputState extends State<ReiriTextInput> {
  late final TextEditingController _controller;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      Expanded(
        child: TextField(
          textAlign: widget.align,
          obscureText: widget.passwd && !_showPassword,
          decoration: RDeco().input.copyWith(
            hintText: widget.hint,
            hintStyle: TextStyle(
              color: Theme.of(context).colorScheme.onPrimary,
            ),
            filled: true,
            fillColor: Theme.of(context).colorScheme.surface,
            counterText: '',
            contentPadding: const EdgeInsets.symmetric(horizontal: 2),
          ),
          controller: _controller,
          maxLength: widget.maxLength,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
        ),
      ),
    ];

    if (widget.passwd) {
      children.add(
        GestureDetector(
          onTap: () => setState(() => _showPassword = !_showPassword),
          child: ReiriIcons.icon(
            _showPassword ? ReiriIcons.eyes_visible : ReiriIcons.eyes_hidden,
            width: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }

    return Container(
      width: widget.width,
      margin: widget.margin,
      padding: widget.padding,
      decoration: widget.decoration,
      child: Row(children: children),
    );
  }
}
