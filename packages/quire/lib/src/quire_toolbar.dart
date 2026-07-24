import 'package:flutter/material.dart';
import 'package:quire_core/quire_core.dart';

import 'insert_table_dialog.dart';
import 'quire_editor_controller.dart';
import 'table_settings_menu.dart';

const _boldAttribution = Attribution('bold');
const _italicAttribution = Attribution('italic');
const _underlineAttribution = Attribution('underline');
const _strikethroughAttribution = Attribution('strikethrough');

/// A plain Material toolbar of formatting actions, reflecting
/// [QuireEditorController.activeAttributions] and the focused node's
/// `blockType`. This is a demo surface, not a design exercise.
class QuireToolbar extends StatelessWidget {
  const QuireToolbar({super.key, required this.controller, this.onPickImage});

  final QuireEditorController controller;

  /// Lets a host insert an image without this package depending on an
  /// image-picker package: return the picked image's local path or URL, or
  /// `null` if the user cancelled. The image button is hidden when this is
  /// `null`.
  final Future<String?> Function()? onPickImage;

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
                tooltip: 'Strikethrough',
                isSelected: active.contains(_strikethroughAttribution),
                icon: const Icon(Icons.strikethrough_s),
                onPressed: controller.toggleStrikethrough,
              ),
              if (onPickImage != null)
                IconButton(
                  tooltip: 'Insert image',
                  icon: const Icon(Icons.image_outlined),
                  onPressed: () async {
                    final url = await onPickImage!();
                    if (url != null) controller.insertImage(url);
                  },
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
                tooltip: 'Checklist',
                isSelected: blockType == 'listItemTask',
                icon: const Icon(Icons.checklist),
                onPressed: () => controller.setBlockType('listItemTask'),
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
                onPressed: () async {
                  final size = await showInsertTableDialog(context);
                  if (size == null || !context.mounted) return;
                  controller.insertTable(
                    rows: size.rows,
                    columns: size.columns,
                  );
                },
              ),
              if (tableCell != null)
                TableSettingsMenu(
                  controller: controller,
                  tableId: tableCell.table.id,
                ),
              // Unfocuses whatever holds focus (which may not be one of the
              // editor's own nodes — a host title field, say) without
              // touching the composer's selection, so tapping back in
              // returns the caret to where it was.
              IconButton(
                tooltip: 'Hide keyboard',
                icon: const Icon(Icons.keyboard_hide),
                onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
              ),
            ],
          ),
        );
      },
    );
  }
}
