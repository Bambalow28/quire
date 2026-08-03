import 'package:flutter/material.dart';

import 'quire_editor_controller.dart';

/// The table-editing menu, shared by [QuireToolbar]'s table-settings button
/// and each table's own settings button in [QuireEditor] — one definition,
/// used both places.
///
/// [tableId] is the table this menu belongs to. The caret-position actions
/// (insert/delete row or column, merge, split) act on the caret's current
/// cell exactly as they do today, but only when the caret is actually inside
/// *this* table — otherwise they're disabled (not hidden, so the menu
/// doesn't change shape). "Add row/column at end" and "Delete table" need no
/// caret and are always enabled.
class TableSettingsMenu extends StatelessWidget {
  const TableSettingsMenu({
    super.key,
    required this.controller,
    required this.tableId,
    this.icon = const Icon(Icons.settings_outlined),
    this.iconSize,
    this.padding = const EdgeInsets.all(8),
    this.tooltip = 'Table settings',
  });

  final QuireEditorController controller;
  final String tableId;
  final Widget icon;
  final double? iconSize;
  final EdgeInsetsGeometry padding;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final cell = controller.focusedTableCell;
    final caretHere = cell != null && cell.table.id == tableId;

    return PopupMenuButton<VoidCallback>(
      tooltip: tooltip,
      icon: icon,
      iconSize: iconSize,
      padding: padding,
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: caretHere,
          value: controller.insertTableRowAbove,
          child: const Text('Insert row above'),
        ),
        PopupMenuItem(
          enabled: caretHere,
          value: controller.insertTableRowBelow,
          child: const Text('Insert row below'),
        ),
        PopupMenuItem(
          enabled: caretHere,
          value: controller.insertTableColumnLeft,
          child: const Text('Insert column left'),
        ),
        PopupMenuItem(
          enabled: caretHere,
          value: controller.insertTableColumnRight,
          child: const Text('Insert column right'),
        ),
        PopupMenuItem(
          enabled: caretHere,
          value: controller.deleteTableRow,
          child: const Text('Delete row'),
        ),
        PopupMenuItem(
          enabled: caretHere,
          value: controller.deleteTableColumn,
          child: const Text('Delete column'),
        ),
        PopupMenuItem(
          enabled: caretHere && controller.canMergeFocusedCellRight,
          value: controller.mergeWithNextCell,
          child: const Text('Merge with cell to the right'),
        ),
        PopupMenuItem(
          enabled: caretHere && controller.canSplitFocusedCell,
          value: controller.splitFocusedCell,
          child: const Text('Split cell'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: () => controller.addTableRowAtEnd(tableId),
          child: const Text('Add row at end'),
        ),
        PopupMenuItem(
          value: () => controller.addTableColumnAtEnd(tableId),
          child: const Text('Add column at end'),
        ),
        PopupMenuItem(
          value: () => _confirmDelete(context),
          child: const Text('Delete table'),
        ),
      ],
    );
  }

  /// Deleting a table removes a chunk of content, so this asks first —
  /// undo covers it either way, but confirmation is the cheaper safety net
  /// against an accidental tap.
  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete table?'),
        content: const Text('This removes the table and everything in it.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      controller.deleteTableById(tableId);
    }
  }
}
