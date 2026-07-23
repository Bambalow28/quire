import 'package:flutter/material.dart';
import 'package:quire_core/quire_core.dart';

import 'quire_editor_controller.dart';

const _boldAttribution = Attribution('bold');
const _italicAttribution = Attribution('italic');
const _underlineAttribution = Attribution('underline');

/// A plain Material toolbar of formatting actions, reflecting
/// [QuireEditorController.activeAttributions] and the focused node's
/// `blockType`. This is a demo surface, not a design exercise.
class QuireToolbar extends StatelessWidget {
  const QuireToolbar({super.key, required this.controller});

  final QuireEditorController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final active = controller.activeAttributions;
        final blockType = controller.focusedTextNode?.blockType;
        final tableCell = controller.focusedTableCell;
        // Scrolls sideways rather than wrapping: the host gives this a
        // fixed-height slot (an AppBar bottom), and a second row would
        // overflow it.
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Bold',
                isSelected: active.contains(_boldAttribution),
                icon: const Icon(Icons.format_bold),
                onPressed: controller.toggleBold,
              ),
              IconButton(
                tooltip: 'Italic',
                isSelected: active.contains(_italicAttribution),
                icon: const Icon(Icons.format_italic),
                onPressed: controller.toggleItalic,
              ),
              IconButton(
                tooltip: 'Underline',
                isSelected: active.contains(_underlineAttribution),
                icon: const Icon(Icons.format_underlined),
                onPressed: controller.toggleUnderline,
              ),
              IconButton(
                tooltip: 'Heading 1',
                isSelected: blockType == 'header1',
                icon: const Icon(Icons.looks_one_outlined),
                onPressed: () => controller.setBlockType('header1'),
              ),
              IconButton(
                tooltip: 'Heading 2',
                isSelected: blockType == 'header2',
                icon: const Icon(Icons.looks_two_outlined),
                onPressed: () => controller.setBlockType('header2'),
              ),
              IconButton(
                tooltip: 'Bullet list',
                isSelected: blockType == 'listItemUnordered',
                icon: const Icon(Icons.format_list_bulleted),
                onPressed: () => controller.setBlockType('listItemUnordered'),
              ),
              IconButton(
                tooltip: 'Numbered list',
                isSelected: blockType == 'listItemOrdered',
                icon: const Icon(Icons.format_list_numbered),
                onPressed: () => controller.setBlockType('listItemOrdered'),
              ),
              IconButton(
                tooltip: 'Decrease indent',
                icon: const Icon(Icons.format_indent_decrease),
                onPressed: () => controller.changeIndent(-1),
              ),
              IconButton(
                tooltip: 'Increase indent',
                icon: const Icon(Icons.format_indent_increase),
                onPressed: () => controller.changeIndent(1),
              ),
              IconButton(
                tooltip: 'Undo',
                icon: const Icon(Icons.undo),
                onPressed: controller.canUndo ? controller.undo : null,
              ),
              IconButton(
                tooltip: 'Redo',
                icon: const Icon(Icons.redo),
                onPressed: controller.canRedo ? controller.redo : null,
              ),
              IconButton(
                tooltip: 'Insert table',
                icon: const Icon(Icons.table_chart_outlined),
                onPressed: controller.insertTable,
              ),
              if (tableCell != null) ...[
                IconButton(
                  tooltip: 'Insert row below',
                  icon: const Icon(Icons.table_rows_outlined),
                  onPressed: controller.insertTableRowBelow,
                ),
                IconButton(
                  tooltip: 'Delete row',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: controller.deleteTableRow,
                ),
                IconButton(
                  tooltip: 'Insert column right',
                  icon: const Icon(Icons.view_column_outlined),
                  onPressed: controller.insertTableColumnRight,
                ),
                IconButton(
                  tooltip: 'Delete column',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: controller.deleteTableColumn,
                ),
                IconButton(
                  tooltip: 'Merge with next cell',
                  icon: const Icon(Icons.call_merge),
                  onPressed: controller.mergeWithNextCell,
                ),
                IconButton(
                  tooltip: 'Split cell',
                  icon: const Icon(Icons.call_split),
                  onPressed: controller.splitFocusedCell,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
