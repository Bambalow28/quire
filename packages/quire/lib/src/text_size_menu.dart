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

/// Total height of the menu's content, plus the framework's own vertical
/// menuPadding (8 top + 8 bottom — see [PopupMenuButtonState.menuPadding]).
/// Used to anchor the menu above the button by exactly its own height, so it
/// opens sitting on top of the button rather than below it.
final double _menuHeight =
    _steps.fold(0.0, (sum, step) => sum + _itemHeight(step.size)) + 16;

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
    // Body is the resting state; anything else is worth flagging, the same
    // way a lit IconButton flags an active attribution.
    final raised = current.blockType != 'paragraph';

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
      onSelected: controller.applyBlockType,
      itemBuilder: (context) => [
        for (final step in _steps)
          PopupMenuItem(
            value: step.blockType,
            height: _itemHeight(step.size),
            child: Row(
              children: [
                SizedBox(
                  width: 26,
                  child: step.blockType == current.blockType
                      ? Icon(Icons.check, size: 18, color: scheme.primary)
                      : null,
                ),
                // The whole point of the menu: each name is drawn at its own
                // size, so the choice is visible rather than inferred from a
                // label.
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
                  '${current.size.toInt()}',
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
