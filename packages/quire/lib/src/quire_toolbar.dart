import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:quire_core/quire_core.dart';

import 'insert_table_dialog.dart';
import 'link_dialog.dart';
import 'quire_editor_controller.dart';
import 'table_settings_menu.dart';
import 'text_size_menu.dart';

/// Desktop has no software keyboard to hide — `defaultTargetPlatform` rather
/// than `dart:io`'s `Platform` so this stays safe to evaluate on web too.
bool get _hasSoftwareKeyboard =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.fuchsia;

const _boldAttribution = Attribution('bold');
const _italicAttribution = Attribution('italic');
const _underlineAttribution = Attribution('underline');

/// Alignments the toolbar offers, in the order the icon row shows them.
const _alignments = <(String, IconData, String)>[
  ('left', Icons.format_align_left, 'Align left'),
  ('center', Icons.format_align_center, 'Align center'),
  ('right', Icons.format_align_right, 'Align right'),
  ('justify', Icons.format_align_justify, 'Justify'),
];

/// Fixed line-spacing multipliers the increase/decrease buttons step
/// through — mirrors [ChangeLineSpacingRequest]'s 1.0–2.5 clamp without
/// exposing the whole range as discrete steps.
const _lineSpacingSteps = <double>[1.0, 1.15, 1.5, 2.0];

/// Used before the keyboard has ever been on screen, so the panel still has a
/// sane height on first open.
const _fallbackPanelHeight = 280.0;

/// A plain Material toolbar of formatting actions, reflecting
/// [QuireEditorController.activeAttributions] and the focused node's
/// `blockType`.
///
/// The bar itself carries only what you reach for mid-sentence and fits it on
/// one screen width — no horizontal scroll. Everything else lives behind the
/// `+` button, which swaps the keyboard for a labelled list of every action
/// (Notion-style), sized to the keyboard it replaced.
class QuireToolbar extends StatefulWidget {
  const QuireToolbar({super.key, required this.controller, this.onPickImage});

  final QuireEditorController controller;

  /// Lets a host insert an image without this package depending on an
  /// image-picker package: return the picked image's local path or URL, or
  /// `null` if the user cancelled. The image button is hidden when this is
  /// `null`.
  final Future<String?> Function()? onPickImage;

  @override
  State<QuireToolbar> createState() => _QuireToolbarState();
}

class _QuireToolbarState extends State<QuireToolbar>
    with WidgetsBindingObserver {
  bool _panelOpen = false;

  /// Whether the panel's slot is currently showing the emoji picker instead
  /// of the options list — swapped in place the same way the panel itself
  /// swaps in place of the keyboard, so picking "Emoji" doesn't pop a modal
  /// sheet on top of everything.
  bool _showEmojiPicker = false;

  /// Last keyboard height seen. Remembered because the panel is only ever
  /// shown *with the keyboard down*, when the live inset reads zero.
  double _keyboardHeight = 0;

  /// True from opening the panel until the keyboard has finished sliding
  /// away, so its still-shrinking inset isn't read as the keyboard returning.
  bool _keyboardLeaving = false;

  /// True from the X being pressed until the panel is actually gone.
  /// [_panelOpen] stays true that whole time (it's what keeps the panel
  /// sized against the rising keyboard) — this is just what the button shows,
  /// and it flips the instant it's pressed rather than waiting on the
  /// keyboard, mirroring how + shows X the instant it's pressed.
  bool _closingPanel = false;

  /// Whatever held focus right before the panel opened. [controller] only
  /// knows about its own text nodes — on a note screen the title field can
  /// hold focus instead, and closing the panel needs to hand focus back to
  /// whichever it was, not just the editor's.
  FocusNode? _previousFocus;

  @override
  void initState() {
    super.initState();
    // The keyboard's height is read off the view, not off MediaQuery — a
    // Scaffold with resizeToAvoidBottomInset has already consumed the inset
    // by the time it reaches this widget — so the metrics callback is what
    // drives the frames of the swap.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => setState(() {});

  void _togglePanel() {
    if (_panelOpen) {
      // Don't drop the panel here: asking for focus starts the keyboard
      // rising, and the sizing in [build] shrinks the panel by exactly as
      // much on the way, closing it when it reaches nothing. Same handoff as
      // the open, run backwards.
      final id = widget.controller.focusedNodeId;
      final previousFocus = _previousFocus;
      if (id == null && previousFocus?.context == null) {
        // Nothing to hand off to (the panel opened with no node focused, or
        // that field is gone now) — there's no keyboard coming to shrink it,
        // so just close.
        setState(() {
          _panelOpen = false;
          _closingPanel = false;
          _showEmojiPicker = false;
        });
        return;
      }
      setState(() {
        _keyboardLeaving = false;
        _closingPanel = true;
      });
      // Prefer the editor's own path when it applies — it also restores the
      // caret, which a bare FocusNode.requestFocus() wouldn't.
      if (id != null) {
        widget.controller.requestFocus(id);
      } else {
        previousFocus!.requestFocus();
      }
      return;
    }
    // Remembered before unfocusing below wipes it, so the close can hand
    // focus back even when it wasn't one of the editor's own nodes. A
    // FocusScopeNode means nothing real was focused (it's what the framework
    // defaults primaryFocus to on its own) — not worth restoring.
    final primary = FocusManager.instance.primaryFocus;
    _previousFocus = primary is FocusScopeNode ? null : primary;
    setState(() {
      _panelOpen = true;
      _keyboardLeaving = true;
      _closingPanel = false;
    });
    // Drop focus so the keyboard leaves and the panel takes its place. The
    // composer's selection survives, so the panel's actions still apply where
    // the caret was.
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final view = View.of(context);
    final insets = view.viewInsets.bottom / view.devicePixelRatio;
    // What the host's SafeArea will pad once the keyboard is out of the way,
    // by the same rule MediaQuery uses: the inset eats the padding.
    final safeBottom =
        (view.viewPadding.bottom / view.devicePixelRatio - insets).clamp(
          0.0,
          double.infinity,
        );
    // Only while no panel is in play: mid-swap the inset is a fraction of the
    // keyboard's height, and recording that would size the panel to a sliver.
    if (!_panelOpen && insets > 0) _keyboardHeight = insets;
    if (insets == 0) _keyboardLeaving = false;

    // The panel occupies exactly what the keyboard vacates: as the keyboard
    // slides the inset moves and this moves against it by the same amount, so
    // the bar never budges and one animates into the other — in both
    // directions. The host's own safe-area padding (which only appears as the
    // keyboard leaves) comes off the same total for the same reason.
    final panelHeight = _panelOpen
        ? ((_keyboardHeight == 0 ? _fallbackPanelHeight : _keyboardHeight) -
                  insets -
                  safeBottom)
              .clamp(0.0, double.infinity)
        : 0.0;
    // Squeezed to nothing by a keyboard on its way back — either the close
    // above, or something else taking focus. Either way the panel is done.
    // Not a setState: this build is already the inset change's.
    if (_panelOpen && !_keyboardLeaving && panelHeight == 0) {
      _panelOpen = false;
      _closingPanel = false;
      _showEmojiPicker = false;
    }
    final showingOptions = _panelOpen && !_closingPanel;

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final active = widget.controller.activeAttributions;

        final scheme = Theme.of(context).colorScheme;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              // Without this the bar sits flush against the screen edges and
              // reads as cut off.
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Padding(
                  // Keeps the controls off the border the DecoratedBox just
                  // added — flush against it read as cramped.
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      TextSizeMenu(controller: widget.controller),
                      const _Separator(),
                      _BarButton(
                        tooltip: 'Bold',
                        icon: Icons.format_bold,
                        isSelected: active.contains(_boldAttribution),
                        onPressed: widget.controller.toggleBold,
                      ),
                      _BarButton(
                        tooltip: 'Italic',
                        icon: Icons.format_italic,
                        isSelected: active.contains(_italicAttribution),
                        onPressed: widget.controller.toggleItalic,
                      ),
                      _BarButton(
                        tooltip: 'Underline',
                        icon: Icons.format_underlined,
                        isSelected: active.contains(_underlineAttribution),
                        onPressed: widget.controller.toggleUnderline,
                      ),
                      _BarButton(
                        tooltip: 'Link',
                        icon: Icons.link,
                        iconColor: Colors.blue,
                        onPressed: () async {
                          final selection =
                              widget.controller.composer.selection;
                          final selectedText = selection == null
                              ? ''
                              : flattenSelectionText(
                                  widget.controller.document,
                                  selection,
                                );
                          final result = await showLinkDialog(
                            context,
                            initialText: selectedText,
                          );
                          if (result != null) {
                            widget.controller.insertLink(
                              url: result.url,
                              displayText: result.text,
                            );
                          }
                        },
                      ),
                      const Spacer(),
                      // Sits next to the keyboard button because the two
                      // trade places: one puts the options where the
                      // keyboard was, the other takes both away.
                      _BarButton(
                        tooltip: showingOptions
                            ? 'Back to keyboard'
                            : 'More options',
                        icon: showingOptions ? Icons.close : Icons.add,
                        onPressed: _togglePanel,
                      ),
                      // Unfocuses whatever holds focus (which may not be one
                      // of the editor's own nodes — a host title field, say)
                      // without touching the composer's selection, so
                      // tapping back in returns the caret to where it was.
                      // Desktop has no software keyboard to hide, so the
                      // button itself has nothing to do there.
                      if (_hasSoftwareKeyboard)
                        _BarButton(
                          tooltip: 'Hide keyboard',
                          icon: Icons.keyboard_hide,
                          onPressed: () {
                            // Everything goes at once here — there's nothing
                            // for the panel to hand off to.
                            if (_panelOpen) {
                              setState(() {
                                _panelOpen = false;
                                _closingPanel = false;
                              });
                            }
                            FocusManager.instance.primaryFocus?.unfocus();
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (_panelOpen)
              SizedBox(
                height: panelHeight,
                child: _showEmojiPicker
                    ? _EmojiPanel(
                        controller: widget.controller,
                        // Mirrors the panel's own "X" — the picker is a view
                        // inside the same slot, not a separate sheet, so
                        // closing it means closing the whole panel and
                        // handing focus (and the keyboard) back, not
                        // stepping back to the options list.
                        onClose: _togglePanel,
                      )
                    : _OptionsPanel(
                        controller: widget.controller,
                        onPickImage: widget.onPickImage,
                        onShowEmoji: () =>
                            setState(() => _showEmojiPicker = true),
                      ),
              ),
          ],
        );
      },
    );
  }
}

/// The emoji picker ships its own light-only default palette — this maps it
/// onto the host app's [ColorScheme] so it reads as part of the editor
/// (light or dark) instead of a foreign light popup dropped on top of it.
Config _emojiPickerConfig(ColorScheme scheme) => Config(
  // Null, not the package's own fixed default (256): the picker now lives
  // inside an [Expanded] in [_EmojiPanel], so its own ancestor already
  // bounds its height — a second, independent fixed height here just fights
  // that instead of filling it.
  height: null,
  emojiViewConfig: EmojiViewConfig(backgroundColor: scheme.surface),
  categoryViewConfig: CategoryViewConfig(
    backgroundColor: scheme.surface,
    indicatorColor: scheme.primary,
    iconColor: scheme.onSurfaceVariant,
    iconColorSelected: scheme.primary,
    backspaceColor: scheme.primary,
    dividerColor: scheme.outlineVariant,
  ),
  bottomActionBarConfig: BottomActionBarConfig(
    backgroundColor: scheme.surface,
    buttonColor: scheme.primary,
    buttonIconColor: Colors.white,
    // The package's own search/backspace buttons are a 48px IconButton
    // (Material's minimum tap target) inside a 40px CircleAvatar — the
    // button always clips against its own circle. Building the row
    // ourselves with a circular *button style* instead of a separate
    // undersized avatar sidesteps that entirely.
    customBottomActionBar: (config, state, showSearchView) =>
        _EmojiActionBar(scheme: scheme, state: state, onSearch: showSearchView),
  ),
  searchViewConfig: SearchViewConfig(
    backgroundColor: scheme.surfaceContainerHighest,
    buttonIconColor: scheme.onSurfaceVariant,
  ),
  skinToneConfig: SkinToneConfig(
    dialogBackgroundColor: scheme.surface,
    indicatorColor: scheme.onSurfaceVariant,
  ),
);

/// Replaces the emoji picker's own search/backspace row — see the
/// `customBottomActionBar` comment above for why.
class _EmojiActionBar extends StatelessWidget {
  const _EmojiActionBar({
    required this.scheme,
    required this.state,
    required this.onSearch,
  });

  final ColorScheme scheme;
  final EmojiViewState state;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final buttonStyle = IconButton.styleFrom(
      backgroundColor: scheme.primary,
      // Default black glyph reads as too dark against the filled button —
      // white matches the rest of the picker's on-primary text.
      foregroundColor: Colors.white,
      shape: const CircleBorder(),
    );
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            tooltip: 'Search emoji',
            style: buttonStyle,
            icon: const Icon(Icons.search),
            onPressed: onSearch,
          ),
          IconButton(
            tooltip: 'Backspace',
            style: buttonStyle,
            icon: const Icon(Icons.backspace),
            onPressed: state.onBackspacePressed,
          ),
        ],
      ),
    );
  }
}

/// Every action the bar itself no longer has room for, one labelled row each,
/// scrolling vertically inside the keyboard-sized slot.
class _OptionsPanel extends StatelessWidget {
  const _OptionsPanel({
    required this.controller,
    this.onPickImage,
    required this.onShowEmoji,
  });

  final QuireEditorController controller;
  final Future<String?> Function()? onPickImage;
  final VoidCallback onShowEmoji;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tableCell = controller.focusedTableCell;

    Widget block(String label, String blockType, IconData icon) => _OptionRow(
      label: label,
      icon: icon,
      // Each of these turns itself off when pressed while lit (see
      // QuireEditorController.setBlockType).
      selected: controller.isBlockType(blockType),
      onTap: () => controller.setBlockType(blockType),
    );

    // A floating card in the keyboard's slot, not a slab filling it: the
    // options read as a sheet over the page. Material (rather than a
    // DecoratedBox) because the rows are ListTiles, which paint their ink on
    // the nearest Material ancestor.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Material(
        // `surface`, not a tonal `surfaceContainer*`: those are derived from
        // the seed hue, so on a host with a coloured seed the card comes out
        // tinted and a shade off every other panel in the app.
        color: scheme.surface,
        elevation: 3,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            // No bold/italic/underline here — the bar already carries them.
            block(
              'Bullet list',
              'listItemUnordered',
              Icons.format_list_bulleted,
            ),
            block(
              'Numbered list',
              'listItemOrdered',
              Icons.format_list_numbered,
            ),
            block('Checklist', 'listItemTask', Icons.checklist),
            block('Toggle list', 'toggleList', Icons.arrow_drop_down_circle),
            block('Callout', 'callout', Icons.rectangle_outlined),
            _OptionRow(
              label: 'Decrease indent',
              icon: Icons.format_indent_decrease,
              onTap: () => controller.changeIndent(-1),
            ),
            _OptionRow(
              label: 'Increase indent',
              icon: Icons.format_indent_increase,
              onTap: () => controller.changeIndent(1),
            ),
            _AlignmentRow(controller: controller),
            Builder(
              builder: (context) {
                final spacing = controller.focusedTextNode?.lineSpacing ?? 1.15;
                final index = _lineSpacingSteps.indexOf(spacing);
                // Not one of the fixed steps (e.g. loaded from other
                // content) — treat as between steps rather than crashing on
                // a -1 lookup either side.
                final safeIndex = index == -1 ? 0 : index;
                return Column(
                  children: [
                    _OptionRow(
                      label: 'Decrease line spacing',
                      icon: Icons.unfold_less,
                      onTap: safeIndex > 0
                          ? () => controller.changeLineSpacing(
                              _lineSpacingSteps[safeIndex - 1],
                            )
                          : null,
                    ),
                    _OptionRow(
                      label: 'Increase line spacing',
                      icon: Icons.unfold_more,
                      onTap: safeIndex < _lineSpacingSteps.length - 1
                          ? () => controller.changeLineSpacing(
                              _lineSpacingSteps[safeIndex + 1],
                            )
                          : null,
                    ),
                  ],
                );
              },
            ),
            _OptionRow(
              label: 'Table',
              icon: Icons.table_chart_outlined,
              onTap: () async {
                final size = await showInsertTableDialog(context);
                if (size == null || !context.mounted) return;
                controller.insertTable(rows: size.rows, columns: size.columns);
              },
            ),
            if (onPickImage != null)
              _OptionRow(
                label: 'Image',
                icon: Icons.image_outlined,
                onTap: () async {
                  final url = await onPickImage!();
                  if (url != null) controller.insertImage(url);
                },
              ),
            _OptionRow(
              label: 'Emoji',
              icon: Icons.emoji_emotions_outlined,
              onTap: onShowEmoji,
            ),
            if (tableCell != null)
              _OptionRow(
                label: 'Table settings',
                icon: Icons.settings_outlined,
                trailing: TableSettingsMenu(
                  controller: controller,
                  tableId: tableCell.table.id,
                ),
              ),
            _OptionRow(
              label: 'Find & replace',
              icon: Icons.search,
              onTap: controller.openFind,
            ),
            _OptionRow(
              label: 'Undo',
              icon: Icons.undo,
              onTap: controller.canUndo ? controller.undo : null,
            ),
            _OptionRow(
              label: 'Redo',
              icon: Icons.redo,
              onTap: controller.canRedo ? controller.redo : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// The emoji picker, swapped into the panel's own slot — sized to fill it
/// (via [Expanded], not the package's own fixed default height) with a
/// small header bar carrying the close button, so it reads as one more view
/// inside the panel rather than a separate sheet layered on top of it.
class _EmojiPanel extends StatelessWidget {
  const _EmojiPanel({required this.controller, required this.onClose});

  final QuireEditorController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Material(
        color: scheme.surface,
        elevation: 3,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Row(
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: Text('Emoji'),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Close emoji picker',
                  icon: const Icon(Icons.close),
                  onPressed: onClose,
                ),
              ],
            ),
            Expanded(
              child: EmojiPicker(
                config: _emojiPickerConfig(scheme),
                // Picking an emoji shouldn't bring the keyboard back up —
                // leave the field unfocused so the picker stays open for
                // more picks, mirroring how the options panel itself stays
                // open until its own close button is pressed.
                onEmojiSelected: (category, emoji) =>
                    controller.insertEmoji(emoji.emoji),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The alignment control: unlike the single-icon rows above it, four
/// alignments only make sense side by side so the current one reads at a
/// glance — an `_OptionRow` per alignment would just be four rows saying
/// "Align left", "Align center"... with no way to compare them.
class _AlignmentRow extends StatelessWidget {
  const _AlignmentRow({required this.controller});

  final QuireEditorController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.format_align_left),
      title: const Text('Alignment'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (align, icon, tooltip) in _alignments)
            IconButton(
              tooltip: tooltip,
              visualDensity: VisualDensity.compact,
              isSelected: controller.isTextAlign(align),
              color: controller.isTextAlign(align)
                  ? scheme.primary
                  : scheme.onSurface,
              icon: Icon(icon),
              onPressed: () => controller.changeTextAlign(align),
            ),
        ],
      ),
    );
  }
}

/// One row of the options panel: icon, name, and — when the action has an
/// on/off state — a tick on the right.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.icon,
    this.onTap,
    this.selected = false,
    this.trailing,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool selected;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null || trailing != null;
    final color = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : selected
        ? scheme.primary
        : scheme.onSurface;

    return ListTile(
      dense: true,
      onTap: onTap,
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      trailing:
          trailing ??
          (selected
              ? Icon(Icons.check, size: 18, color: scheme.primary)
              : null),
    );
  }
}

/// A toolbar icon button, tightened so the whole bar fits the narrowest phone
/// without scrolling sideways.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.isSelected = false,
    this.iconColor,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool isSelected;

  /// Overrides the normal selected/unselected theme color — the Link button
  /// wants a fixed link-blue regardless of state, unlike Bold/Italic/Underline.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    isSelected: isSelected,
    visualDensity: VisualDensity.compact,
    icon: Icon(icon, color: iconColor),
    onPressed: onPressed,
  );
}

/// A hairline between groups of actions.
class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 22,
    margin: const EdgeInsets.symmetric(horizontal: 6),
    color: Theme.of(context).colorScheme.outlineVariant,
  );
}
