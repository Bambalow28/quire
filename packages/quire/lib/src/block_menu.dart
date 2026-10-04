import 'package:flutter/material.dart';
import 'package:quire_core/quire_core.dart';

import 'quire_editor_controller.dart';
import 'syntax_highlight.dart';

/// What the block menu can ask for. The sheet only reports the choice; the
/// caller applies it once the sheet is gone, so focus lands where the edit
/// happened rather than on the sheet.
sealed class _BlockChoice {
  const _BlockChoice();
}

class _Move extends _BlockChoice {
  const _Move(this.up);
  final bool up;
}

class _Duplicate extends _BlockChoice {
  const _Duplicate();
}

class _Delete extends _BlockChoice {
  const _Delete();
}

class _TurnInto extends _BlockChoice {
  const _TurnInto(this.blockType);
  final String blockType;
}

const _turnIntoOptions = <(String, String, IconData)>[
  ('Text', 'paragraph', Icons.notes),
  ('Heading 1', 'header1', Icons.looks_one_outlined),
  ('Heading 2', 'header2', Icons.looks_two_outlined),
  ('Heading 3', 'header3', Icons.looks_3_outlined),
  ('Bulleted list', 'listItemUnordered', Icons.format_list_bulleted),
  ('Numbered list', 'listItemOrdered', Icons.format_list_numbered),
  ('To-do', 'listItemTask', Icons.checklist),
  ('Toggle list', 'toggleList', Icons.arrow_drop_down_circle_outlined),
  ('Quote', 'blockquote', Icons.format_quote),
  ('Callout', 'callout', Icons.rectangle_outlined),
  ('Code', 'code', Icons.code),
];

String _describe(DocumentNode node) {
  if (node is ImageNode) return 'Image';
  if (node is TableNode) return 'Table';
  if (node is HorizontalRuleNode) return 'Divider';
  if (node is TextNode) {
    for (final (label, type, _) in _turnIntoOptions) {
      if (type == node.blockType) return label;
    }
  }
  return 'Block';
}

/// Opens the actions for the top-level block [blockId]: move, duplicate,
/// delete, and (for text) turn into another block type.
Future<void> showBlockMenu(
  BuildContext context,
  QuireEditorController controller,
  String blockId,
) async {
  final node = controller.document.getNodeById(blockId);
  if (node == null || !controller.document.isTopLevel(blockId)) return;
  final choice = await showModalBottomSheet<_BlockChoice>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _BlockMenu(
      title: _describe(node),
      currentType: node is TextNode ? node.blockType : null,
      canMoveUp: controller.canMoveBlock(blockId, up: true),
      canMoveDown: controller.canMoveBlock(blockId, up: false),
    ),
  );
  if (choice == null) return;
  switch (choice) {
    case _Move(:final up):
      controller.moveBlock(blockId, up ? -1 : 1);
    case _Duplicate():
      controller.duplicateBlock(blockId);
    case _Delete():
      controller.deleteBlock(blockId);
    case _TurnInto(:final blockType):
      controller.turnBlockInto(blockId, blockType);
  }
}

class _BlockMenu extends StatelessWidget {
  const _BlockMenu({
    required this.title,
    required this.currentType,
    required this.canMoveUp,
    required this.canMoveDown,
  });

  final String title;
  final String? currentType;
  final bool canMoveUp;
  final bool canMoveDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget action(
      String label,
      IconData icon,
      _BlockChoice choice, {
      bool enabled = true,
      bool destructive = false,
    }) {
      final color = !enabled
          ? scheme.onSurface.withValues(alpha: 0.38)
          : destructive
          ? scheme.error
          : scheme.onSurface;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? () => Navigator.of(context).pop(choice) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    action(
                      'Move up',
                      Icons.arrow_upward,
                      const _Move(true),
                      enabled: canMoveUp,
                    ),
                    action(
                      'Move down',
                      Icons.arrow_downward,
                      const _Move(false),
                      enabled: canMoveDown,
                    ),
                    action('Duplicate', Icons.content_copy, const _Duplicate()),
                    action(
                      'Delete',
                      Icons.delete_outline,
                      const _Delete(),
                      destructive: true,
                    ),
                  ],
                ),
              ),
              if (currentType != null) ...[
                const Divider(height: 24),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    'Turn into',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ),
                for (final (label, type, icon) in _turnIntoOptions)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      icon,
                      color: type == currentType ? scheme.primary : null,
                    ),
                    title: Text(
                      label,
                      style: TextStyle(
                        color: type == currentType ? scheme.primary : null,
                      ),
                    ),
                    trailing: type == currentType
                        ? Icon(Icons.check, size: 18, color: scheme.primary)
                        : null,
                    onTap: () => Navigator.of(context).pop(_TurnInto(type)),
                  ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lists the code languages; returns the chosen id (`plain` for none), or null
/// when dismissed.
Future<String?> showCodeLanguageSheet(BuildContext context, String? current) {
  final selected = canonicalLanguage(current) ?? 'plain';
  return showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: ListView(
          children: [
            for (final (id, label) in kCodeLanguages)
              ListTile(
                dense: true,
                title: Text(
                  label,
                  style: TextStyle(
                    color: id == selected ? scheme.primary : null,
                  ),
                ),
                trailing: id == selected
                    ? Icon(Icons.check, size: 18, color: scheme.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(id),
              ),
          ],
        ),
      );
    },
  );
}
