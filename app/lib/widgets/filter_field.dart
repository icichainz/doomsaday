/// The one filter input, and the registry that lets `/` focus it.
///
/// A screen's filter field registers its focus node while it is mounted; the
/// chrome's `/` shortcut asks the registry to focus whatever is registered, so
/// no screen has to know about the key binding.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../layout/layout.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'stroke_icons.dart';

class ScreenFilterFocus {
  FocusNode? _node;

  void register(FocusNode node) => _node = node;

  void unregister(FocusNode node) {
    if (identical(_node, node)) _node = null;
  }

  /// True when there was a field to focus.
  bool focus() {
    final FocusNode? node = _node;
    if (node == null || !node.canRequestFocus) return false;
    node.requestFocus();
    return true;
  }
}

final screenFilterProvider = Provider<ScreenFilterFocus>(
  (ref) => ScreenFilterFocus(),
);

/// D2 and D4's filter box: 36 px with a pointer, a search glyph and the `/`
/// hint chip on the right.
class FilterField extends ConsumerStatefulWidget {
  const FilterField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.width,
    this.showHintKey = true,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final double? width;
  final bool showHintKey;
  final bool autofocus;

  @override
  ConsumerState<FilterField> createState() => _FilterFieldState();
}

class _FilterFieldState extends ConsumerState<FilterField> {
  final FocusNode _focus = FocusNode(debugLabel: 'screen filter');

  /// Held rather than read again in `dispose`, where `ref` is already gone.
  late final ScreenFilterFocus _registry;

  @override
  void initState() {
    super.initState();
    _registry = ref.read(screenFilterProvider)..register(_focus);
  }

  @override
  void dispose() {
    _registry.unregister(_focus);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Density d = context.density;
    // With a pointer it is D2/D4's 36 px box; on a touch screen (the tablet
    // containers list) the same box at 44 px with 15 px text.
    final bool touch = !d.compact;
    final double fontSize = touch ? 15 : 13;
    final Widget box = Container(
      height: touch ? 44 : d.field,
      padding: EdgeInsets.symmetric(horizontal: touch ? 14 : 10),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(touch ? 12 : 10),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: <Widget>[
          StrokeIcon(
            StrokeGlyph.search,
            size: touch ? 17 : 15,
            color: t.mutedText,
          ),
          SizedBox(width: touch ? 10 : 8),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              autofocus: widget.autofocus,
              onChanged: widget.onChanged,
              style: TextStyle(color: t.text, fontSize: fontSize),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: TextStyle(color: t.mutedText, fontSize: fontSize),
              ),
            ),
          ),
          if (widget.showHintKey && d.compact) ...<Widget>[
            const SizedBox(width: 6),
            KeyHint(label: '/'),
          ],
        ],
      ),
    );
    return widget.width == null
        ? box
        : SizedBox(width: widget.width, child: box);
  }
}

/// The bordered `⌘K` / `/` chip the desktop boards put inside a field.
class KeyHint extends StatelessWidget {
  const KeyHint({super.key, required this.label}) : _command = false;

  /// The palette's chip. The command symbol is painted rather than typed,
  /// because no bundled face carries U+2318, and off Apple it reads "Ctrl".
  const KeyHint.command({super.key, this.label = 'K'}) : _command = true;

  final String label;
  final bool _command;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final TextStyle style = TextStyle(
      fontFamily: AppFonts.mono,
      fontSize: 11,
      color: t.mutedText,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.strongBorder),
      ),
      child: _command
          ? CommandKeyLabel(letter: label, style: style)
          : Text(label, style: style),
    );
  }
}
