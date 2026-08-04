import 'package:flutter/material.dart';

import 'quire_editor_controller.dart';

/// One step of the text-size scale the toolbar offers: a name, the block type
/// that carries it, and the point size [QuireEditor] actually renders that
/// block type at (see its `_styleFor` — these must stay in step with it).
typedef _SizeStep = ({String label, String blockType, double size});

/// Largest first, so the menu reads top-to-bottom as a shrinking ladder.
/// `paragraph` anchors the bottom: it's the only non-heading here, and every
/// other block type (list items included) also renders at its size.
const _steps = <_SizeStep>[
  (label: 'Title', blockType: 'header1', size: 32),
  (label: 'Heading', blockType: 'header2', size: 28),
  (label: 'Subheading', blockType: 'header3', size: 24),
  (label: 'Body', blockType: 'paragraph', size: 16),
];

/// Menu-preview size for a step. Scaled down from the real size so a four-row
/// menu doesn't fill the screen, but floored so Body still reads as text and
/// the steps stay visibly apart.
double _previewSize(double size) => (size * 0.75).clamp(15.0, 24.0);

/// Each item's own height, mirroring the `height:` given to its
/// [PopupMenuItem] below — kept as one function so the two can't drift apart.
double _itemHeight(double size) => (_previewSize(size) + 30).clamp(48.0, 60.0);

/// Custom sizes are clamped to this range — wide enough for anything a note
/// actually needs, narrow enough that +/- taps stay useful.
const _minCustomSize = 8.0;
const _maxCustomSize = 72.0;

/// Height of the trailing "custom size" row, plus the divider above it.
const _customRowHeight = 48.0;
const _dividerHeight = 17.0; // PopupMenuDivider's default height.

/// Sentinel `value` for the custom row's [PopupMenuItem] — see the
/// `onSelected` wrapper in [TextSizeMenu.build].
const _customRowValue = '_custom';

/// Total height of the menu's content, plus the framework's own vertical
/// menuPadding (8 top + 8 bottom — see [PopupMenuButtonState.menuPadding]).
/// Used to anchor the menu above the button by exactly its own height, so it
/// opens sitting on top of the button rather than below it.
final double _menuHeight =
    _steps.fold(0.0, (sum, step) => sum + _itemHeight(step.size)) +
    _dividerHeight +
    _customRowHeight +
    16;

/// Extra lift on top of [_menuHeight] so the menu doesn't sit flush against
/// the toolbar's own rounded container — a hairline of visible gap reads as
/// two separate surfaces instead of one that got cut in half.
const _menuGap = 8.0;

/// The toolbar's text-size control: a compact pill showing the current size,
/// opening a menu that renders each step's name *at* its own size, with the
/// point value alongside.
///
/// Replaces the old pair of H1/H2 icon buttons. Two reasons it's a menu and
/// not more buttons: the scale it exposes is wider than two (the editor has
/// always rendered header3 — nothing in the toolbar reached it), and one
/// control that names the current size beats N buttons where "none lit"
/// silently means Body.
///
/// A selection here names the size it wants, so — unlike the list buttons —
/// picking the active step is a no-op rather than a toggle back to Body.
class TextSizeMenu extends StatelessWidget {
  const TextSizeMenu({super.key, required this.controller});

  final QuireEditorController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blockType = controller.focusedTextNode?.blockType;
    final current = _steps.firstWhere(
      (s) => s.blockType == blockType,
      orElse: () => _steps.last,
    );
    // An explicit fontSize attribution (set via the custom row below) always
    // wins over the block type's size — it's what the renderer actually
    // draws (see node_text_controller.dart's `fontSize` case). Falls back to
    // the block default when there's no explicit size, including for a
    // mixed selection (see `explicitFontSize`'s doc comment).
    final explicitSize = controller.explicitFontSize;
    final effectiveSize = explicitSize ?? current.size;
    // Body-with-no-override is the resting state; anything else is worth
    // flagging, the same way a lit IconButton flags an active attribution.
    final raised = current.blockType != 'paragraph' || explicitSize != null;

    return PopupMenuButton<String>(
      tooltip: 'Text size',
      // The button sits in a toolbar right above the keyboard, so "under"
      // (the framework default here) opens the menu into the sliver of
      // screen the keyboard already occupies — showMenu lays out against the
      // full screen, blind to the keyboard inset, so the menu ends up
      // rendered behind it. Opening upward by the menu's own known height
      // instead keeps it entirely above both the button and the keyboard.
      position: PopupMenuPosition.over,
      offset: Offset(0, -_menuHeight - _menuGap),
      // The menu route otherwise takes primary focus for itself when it
      // opens, which blurs whatever text field had it and drops the
      // keyboard. Its items aren't text input, so there's nothing focus
      // needs to move to.
      requestFocus: false,
      // The 48pt child below already carries the tap target; PopupMenuButton's
      // default 8pt padding on top of it would make this control taller than
      // the icon buttons and stretch the whole bar.
      padding: EdgeInsets.zero,
      // The custom-size row (below) has no block type of its own — it's
      // given the `_customRowValue` sentinel just so `PopupMenuButton<String>`
      // has something to pop with when a tap lands outside its buttons, and
      // this filters that sentinel out rather than treating it as a block
      // type.
      onSelected: (value) {
        if (value != _customRowValue) controller.applyBlockType(value);
      },
      itemBuilder: (context) => [
        for (final step in _steps)
          PopupMenuItem(
            value: step.blockType,
            height: _itemHeight(step.size),
            // Wrapped in a ListenableBuilder because the custom row's +/-
            // (below) can flip which row is checked while this menu is
            // still open — the item list itself is only ever built once,
            // when the menu opens, so without this the checkmark would
            // freeze at whatever was true at that moment.
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final isActive =
                    step.blockType == current.blockType &&
                    controller.explicitFontSize == null;
                return Row(
                  children: [
                    SizedBox(
                      width: 26,
                      child: isActive
                          ? Icon(Icons.check, size: 18, color: scheme.primary)
                          : null,
                    ),
                    // The whole point of the menu: each name is drawn at its
                    // own size, so the choice is visible rather than
                    // inferred from a label.
                    Expanded(
                      child: Text(
                        step.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: _previewSize(step.size),
                          fontWeight: step.blockType == 'paragraph'
                              ? FontWeight.w400
                              : FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 20),
                    Text(
                      '${step.size.toInt()}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        const PopupMenuDivider(),
        // Custom sizing: the four named steps above are still block-type
        // changes, this row is the only place that sets an explicit
        // `fontSize` attribution. +/- nudge by 1pt in place, and tapping the
        // number opens a dialog for an exact value — none of the three close
        // the menu; only picking one of the named steps above does that.
        PopupMenuItem(
          value: _customRowValue,
          height: _customRowHeight,
          // Wrapped in a ListenableBuilder so the row's own number (and its
          // checkmark) update live as +/- are pressed, without the menu
          // needing to close and reopen to see the new value — see the
          // itemBuilder-only-runs-once note above.
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final explicitSize = controller.explicitFontSize;
              final rowSize = explicitSize ?? current.size;
              return Row(
                children: [
                  SizedBox(
                    width: 26,
                    child: explicitSize != null
                        ? Icon(Icons.check, size: 18, color: scheme.primary)
                        : null,
                  ),
                  Expanded(
                    child: Text(
                      'Custom',
                      style: TextStyle(color: scheme.onSurface),
                    ),
                  ),
                  IconButton(
                    key: const Key('customSizeDecrement'),
                    icon: const Icon(Icons.remove, size: 18),
                    tooltip: 'Smaller',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: () => controller.setFontSize(
                      (rowSize - 1)
                          .clamp(_minCustomSize, _maxCustomSize)
                          .toDouble(),
                    ),
                  ),
                  InkWell(
                    key: const Key('customSizeValue'),
                    onTap: () => _pickCustomSize(context, controller, rowSize),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        '${rowSize.round()}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('customSizeIncrement'),
                    icon: const Icon(Icons.add, size: 18),
                    tooltip: 'Larger',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: () => controller.setFontSize(
                      (rowSize + 1)
                          .clamp(_minCustomSize, _maxCustomSize)
                          .toDouble(),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
      // A 48pt row keeps the tap target legal while the pill itself stays
      // visually light next to the icon buttons either side of it.
      child: SizedBox(
        height: 48,
        child: Center(
          child: Container(
            height: 34,
            padding: const EdgeInsets.only(left: 10, right: 4),
            decoration: BoxDecoration(
              // No outline: the icon buttons beside it have none either, and
              // a box around this one control made it read as a stray field
              // dropped into the bar. The tint alone carries the active state.
              color: raised
                  ? scheme.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Always two digits across the whole scale, so the pill's
                // width — and everything after it in the toolbar — doesn't
                // shift as the caret moves between blocks.
                Text(
                  '${effectiveSize.round()}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: raised ? scheme.primary : scheme.onSurface,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.arrow_drop_down,
                  size: 20,
                  color: raised ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a small dialog for typing an exact custom point size, clamped to
/// [_minCustomSize]-[_maxCustomSize], and applies it via
/// [QuireEditorController.setFontSize]. Cancelling or entering something
/// unparsable leaves the size unchanged.
Future<void> _pickCustomSize(
  BuildContext context,
  QuireEditorController controller,
  double current,
) async {
  final textController = TextEditingController(text: '${current.round()}');
  final entered = await showDialog<double>(
    context: context,
    builder: (dialogContext) {
      void submit() {
        final parsed = double.tryParse(textController.text);
        Navigator.pop(dialogContext, parsed);
      }

      return AlertDialog(
        title: const Text('Custom size'),
        content: TextField(
          controller: textController,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: 'pt'),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(onPressed: submit, child: const Text('Apply')),
        ],
      );
    },
  );
  if (entered != null) {
    controller.setFontSize(
      entered.clamp(_minCustomSize, _maxCustomSize).toDouble(),
    );
  }
}
