import 'dart:io';

import 'package:flutter/cupertino.dart'
    show cupertinoTextSelectionHandleControls;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart' hide TableCell;
import 'package:flutter/services.dart';
import 'package:quire_core/quire_core.dart';

import 'node_text_controller.dart';
import 'quire_editor_controller.dart';
import 'table_grid.dart';

// ponytail: one EditableText per node buys IME/handles/scribble for free but
// caps selection at a single node; upgrade to a single editor-level
// DeltaTextInputClient when cross-node selection is needed.

/// Renders [QuireEditorController.document] as one [EditableText] per
/// [TextNode] (plus image/rule widgets for the other node types).
class QuireEditor extends StatefulWidget {
  const QuireEditor({
    super.key,
    required this.controller,
    this.padding,
    this.placeholder,
  });

  final QuireEditorController controller;
  final EdgeInsetsGeometry? padding;

  /// Shown (in the host's muted theme color) when the document is a single
  /// empty text node and nothing is focused yet — e.g. "Start writing…".
  final String? placeholder;

  @override
  State<QuireEditor> createState() => _QuireEditorState();
}

class _QuireEditorState extends State<QuireEditor> {
  final Map<String, NodeTextController> _controllers = {};
  final Map<String, FocusNode> _focusNodes = {};
  bool _syncing = false;
  String? _lastRequestedFocusId;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onModelChanged);
    _syncAndPush();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onModelChanged);
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final focusNode in _focusNodes.values) {
      focusNode.dispose();
    }
    super.dispose();
  }

  /// Runs before `setState` so no controller/model listener ever fires
  /// mid-build (that's how you get "setState called during build" from
  /// EditableText's own listener).
  void _onModelChanged() {
    _syncAndPush();
    setState(() {});
  }

  void _syncAndPush() {
    _syncControllers();
    _pushModelToControllers();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeRequestFocus());
  }

  @override
  Widget build(BuildContext context) {
    final nodes = widget.controller.document.nodes;
    final padding = widget.padding ?? const EdgeInsets.all(16);
    // A CustomScrollView with a trailing SliverFillRemaining (rather than a
    // plain ListView) so the empty space below the last node is real,
    // tappable layout — not dead space the ListView never lays a hit-test
    // target over. This is this widget's equivalent of QuillEditor's
    // `expands: true`.
    final content = CustomScrollView(
      slivers: [
        SliverPadding(
          padding: padding,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildNode(context, nodes[index]),
              childCount: nodes.length,
            ),
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _focusLastNodeAtEnd,
          ),
        ),
      ],
    );

    if (!_showPlaceholder) return content;
    return Stack(
      children: [
        Padding(
          padding: padding,
          child: IgnorePointer(
            child: Text(
              widget.placeholder!,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
          ),
        ),
        content,
      ],
    );
  }

  bool get _showPlaceholder {
    final placeholder = widget.placeholder;
    if (placeholder == null || placeholder.isEmpty) return false;
    if (widget.controller.focusedNodeId != null) return false;
    final nodes = widget.controller.document.nodes;
    if (nodes.length != 1) return false;
    final only = nodes.first;
    return only is TextNode && only.text.text.isEmpty;
  }

  /// Tapping the empty tail below the last node focuses that node (if it's
  /// text) with the caret at its end — otherwise most of an almost-empty
  /// document would be dead to taps.
  void _focusLastNodeAtEnd() {
    TextNode? last;
    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is TextNode) last = node;
    }
    if (last == null) return;
    widget.controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition(last.id, TextNodePosition(last.text.text.length)),
      ),
    );
    widget.controller.focusNode(last.id);
  }

  // --- Controller/focus-node bookkeeping ----------------------------------

  void _syncControllers() {
    final liveIds = widget.controller.document.nodesInDocumentOrder
        .whereType<TextNode>()
        .map((n) => n.id)
        .toSet();

    for (final staleId
        in _controllers.keys.where((id) => !liveIds.contains(id)).toList()) {
      _controllers.remove(staleId)?.dispose();
      _focusNodes.remove(staleId)?.dispose();
    }

    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is! TextNode) continue;
      if (_controllers.containsKey(node.id)) continue;

      final controller = NodeTextController(nodeId: node.id, text: node.text);
      controller.addListener(() => _onControllerChanged(node.id));
      _controllers[node.id] = controller;

      final focusNode = FocusNode(debugLabel: node.id);
      focusNode.addListener(() {
        if (focusNode.hasFocus) widget.controller.focusNode(node.id);
      });
      _focusNodes[node.id] = focusNode;
    }
  }

  /// Pushes the model's [AttributedText] into each node's controller. Text
  /// is only overwritten when it actually differs from what the field
  /// already shows, and the field's selection is restored from the
  /// composer so a model-driven caret move (Enter, backspace-merge, undo)
  /// survives the round trip.
  void _pushModelToControllers() {
    _syncing = true;
    final composerSelection = widget.controller.composer.selection;
    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is! TextNode) continue;
      final controller = _controllers[node.id];
      if (controller == null) continue;

      final modelText = node.text.text;
      final targetsThisNode =
          composerSelection != null &&
          composerSelection.base.nodeId == node.id &&
          composerSelection.extent.nodeId == node.id;

      if (controller.text != modelText) {
        final selection = targetsThisNode
            ? _textSelectionFrom(composerSelection)
            : TextSelection.collapsed(
                offset: controller.selection.baseOffset.clamp(
                  0,
                  modelText.length,
                ),
              );
        controller.value = TextEditingValue(
          text: modelText,
          selection: selection,
        );
      } else if (targetsThisNode) {
        final selection = _textSelectionFrom(composerSelection);
        if (selection != controller.selection) {
          controller.selection = selection;
        }
      }
      controller.setAttributedText(node.text);
    }
    _syncing = false;
  }

  TextSelection _textSelectionFrom(DocumentSelection selection) {
    final base = selection.base.nodePosition;
    final extent = selection.extent.nodePosition;
    if (base is TextNodePosition && extent is TextNodePosition) {
      return TextSelection(
        baseOffset: base.offset,
        extentOffset: extent.offset,
      );
    }
    return const TextSelection.collapsed(offset: 0);
  }

  void _maybeRequestFocus() {
    if (!mounted) return;
    final id = widget.controller.focusedNodeId;
    if (id == null || id == _lastRequestedFocusId) return;
    final focusNode = _focusNodes[id];
    if (focusNode == null) return;
    _lastRequestedFocusId = id;
    if (!focusNode.hasFocus) focusNode.requestFocus();
  }

  /// Diffs the field's current plain text against the model's, as a single
  /// contiguous replacement (common prefix + common suffix — what an IME
  /// edit always looks like), and routes it through the model so
  /// attributions and undo survive. If only the selection moved, syncs that
  /// instead.
  void _onControllerChanged(String nodeId) {
    if (_syncing) return;
    final controller = _controllers[nodeId];
    if (controller == null) return;

    final oldText = controller.attributedText.text;
    final newText = controller.text;

    if (oldText != newText) {
      final prefixLen = _commonPrefixLength(oldText, newText);
      final suffixLen = _commonSuffixLength(oldText, newText, prefixLen);
      final deleteEnd = oldText.length - suffixLen;
      final insertedText = newText.substring(
        prefixLen,
        newText.length - suffixLen,
      );

      if (insertedText.contains('\n')) {
        // A soft keyboard's Return key sends no key event — with
        // TextInputAction.newline it lands here as a literal "\n" in the
        // diff. Split it into InsertNewlineRequests so it splits the node
        // the same way a physical Enter does, instead of leaving a raw
        // newline character inside one node's text.
        final segments = insertedText.split('\n');
        widget.controller.replaceText(
          nodeId: nodeId,
          start: prefixLen,
          end: deleteEnd,
          insertedText: segments.first,
        );
        if (segments.first.isEmpty && deleteEnd == prefixLen) {
          // replaceText was a no-op (nothing to delete or insert before the
          // first newline) and so left the composer's selection stale —
          // insertNewline splits at the composer's selection, so it must be
          // repositioned here or the split lands in the wrong place.
          widget.controller.changeSelection(
            DocumentSelection.collapsed(
              DocumentPosition(nodeId, TextNodePosition(prefixLen)),
            ),
          );
        }
        for (var i = 1; i < segments.length; i++) {
          widget.controller.insertNewline();
          final currentNodeId = widget.controller.focusedNodeId;
          if (currentNodeId != null && segments[i].isNotEmpty) {
            widget.controller.replaceText(
              nodeId: currentNodeId,
              start: 0,
              end: 0,
              insertedText: segments[i],
            );
          }
        }
      } else {
        widget.controller.replaceText(
          nodeId: nodeId,
          start: prefixLen,
          end: deleteEnd,
          insertedText: insertedText,
        );
      }
      return;
    }

    final selection = controller.selection;
    if (!selection.isValid) return;
    widget.controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition(nodeId, TextNodePosition(selection.baseOffset)),
        extent: DocumentPosition(
          nodeId,
          TextNodePosition(selection.extentOffset),
        ),
      ),
    );
  }

  int _commonPrefixLength(String a, String b) {
    final max = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < max && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  int _commonSuffixLength(String a, String b, int prefixLimit) {
    final maxA = a.length - prefixLimit;
    final maxB = b.length - prefixLimit;
    final max = maxA < maxB ? maxA : maxB;
    var i = 0;
    while (i < max &&
        a.codeUnitAt(a.length - 1 - i) == b.codeUnitAt(b.length - 1 - i)) {
      i++;
    }
    return i;
  }

  // --- Enter / backspace interception -------------------------------------

  /// Physical-key bindings (desktop). Soft-keyboard Enter is handled in the
  /// controller-diff path instead (see `_onControllerChanged`), since a
  /// soft Return key emits no key event at all.
  ///
  /// Backspace is only bound when the caret is collapsed at offset 0 — every
  /// other backspace press is left unbound so `EditableText` deletes
  /// natively (including inside an IME composing region, which a blanket
  /// binding would otherwise corrupt).
  // ponytail: a soft keyboard sends no key event, and thus no deletion
  // delta, when there's nothing left to delete — so paragraph-merge via
  // Backspace is unavailable on touch (still works with a hardware
  // keyboard/Backspace-as-delete on desktop). Upgrade path: an editor-level
  // DeltaTextInputClient, which sees the IME's actual delete requests
  // instead of relying on key events.
  Map<ShortcutActivator, VoidCallback> _shortcutBindings(String nodeId) {
    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.enter):
          widget.controller.insertNewline,
      const SingleActivator(LogicalKeyboardKey.numpadEnter):
          widget.controller.insertNewline,
      const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
          widget.controller.toggleBold,
      const SingleActivator(LogicalKeyboardKey.keyB, control: true):
          widget.controller.toggleBold,
      const SingleActivator(LogicalKeyboardKey.keyI, meta: true):
          widget.controller.toggleItalic,
      const SingleActivator(LogicalKeyboardKey.keyI, control: true):
          widget.controller.toggleItalic,
      const SingleActivator(LogicalKeyboardKey.keyU, meta: true):
          widget.controller.toggleUnderline,
      const SingleActivator(LogicalKeyboardKey.keyU, control: true):
          widget.controller.toggleUnderline,
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
          widget.controller.undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
          widget.controller.undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
          widget.controller.redo,
      const SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: true,
        shift: true,
      ): widget.controller.redo,
    };

    final selection = _controllers[nodeId]?.selection;
    if (selection != null && selection.isValid && selection.isCollapsed) {
      if (selection.baseOffset == 0) {
        bindings[const SingleActivator(LogicalKeyboardKey.backspace)] = () =>
            widget.controller.mergeWithPrevious(nodeId);
      }
    }

    if (widget.controller.isInsideTable(nodeId)) {
      bindings[const SingleActivator(LogicalKeyboardKey.tab)] = () =>
          widget.controller.moveToAdjacentCell(nodeId, forward: true);
      bindings[const SingleActivator(
        LogicalKeyboardKey.tab,
        shift: true,
      )] = () =>
          widget.controller.moveToAdjacentCell(nodeId, forward: false);
    }
    return bindings;
  }

  // --- Per-node-type widgets -----------------------------------------------

  Widget _buildNode(BuildContext context, DocumentNode node) {
    if (node is TextNode) return _buildTextNode(context, node);
    if (node is ImageNode) return _buildImageNode(context, node);
    if (node is TableNode) return _buildTableNode(context, node);
    if (node is HorizontalRuleNode) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Divider(),
      );
    }
    return const SizedBox.shrink();
  }

  /// Resolves [node]'s grid and renders one child per distinct cell (a
  /// merged cell renders once, spanning its full rectangle) — each cell's
  /// nodes recurse back through [_buildNode], reusing the same per-node-type
  /// widgets used at the top level.
  Widget _buildTableNode(BuildContext context, TableNode node) {
    final grid = node.grid;
    final seen = <TableCell>{};
    final children = <Widget>[];
    for (var r = 0; r < grid.length; r++) {
      for (var c = 0; c < grid[r].length; c++) {
        final cell = grid[r][c];
        if (cell == null || !seen.add(cell)) continue;
        children.add(
          TableCellData(
            row: r,
            column: c,
            rowSpan: cell.rowSpan,
            colSpan: cell.colSpan,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [for (final n in cell.nodes) _buildNode(context, n)],
              ),
            ),
          ),
        );
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TableGrid(
        rowCount: grid.length,
        columnCount: grid.isEmpty ? 0 : grid[0].length,
        columnWidths: node.columnWidths,
        borderColor: Theme.of(context).dividerColor,
        children: children,
      ),
    );
  }

  Widget _buildTextNode(BuildContext context, TextNode node) {
    final controller = _controllers[node.id]!;
    final focusNode = _focusNodes[node.id]!;
    final theme = Theme.of(context);

    final field = CallbackShortcuts(
      bindings: _shortcutBindings(node.id),
      child: EditableText(
        controller: controller,
        focusNode: focusNode,
        style: _styleFor(theme, node),
        textAlign: _textAlignFor(node),
        cursorColor: theme.colorScheme.primary,
        backgroundCursorColor: theme.colorScheme.surfaceContainerHighest,
        selectionColor: theme.colorScheme.primary.withValues(alpha: 0.3),
        maxLines: null,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        selectionControls: switch (defaultTargetPlatform) {
          TargetPlatform.iOS ||
          TargetPlatform.macOS => cupertinoTextSelectionHandleControls,
          _ => materialTextSelectionHandleControls,
        },
        contextMenuBuilder: (context, state) =>
            AdaptiveTextSelectionToolbar.editableText(editableTextState: state),
      ),
    );

    final prefix = _prefixFor(context, node);
    final row = prefix == null
        ? field
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              prefix,
              Expanded(child: field),
            ],
          );

    final indentPadding = node.indent * 24.0;

    switch (node.blockType) {
      case 'blockquote':
        return Container(
          margin: EdgeInsets.only(left: indentPadding, bottom: 4),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: theme.dividerColor, width: 3),
            ),
          ),
          child: row,
        );
      case 'code':
        return Container(
          margin: EdgeInsets.only(left: indentPadding, bottom: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: row,
        );
      default:
        return Padding(
          padding: EdgeInsets.only(left: indentPadding, bottom: 4),
          child: row,
        );
    }
  }

  Widget _buildImageNode(BuildContext context, ImageNode node) {
    Widget errorBuilder(BuildContext context, Object error, StackTrace? st) =>
        Container(
          height: 120,
          alignment: Alignment.center,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Icon(Icons.broken_image_outlined),
        );
    final uri = Uri.tryParse(node.url);
    final isNetwork =
        uri != null && (uri.isScheme('http') || uri.isScheme('https'));
    final image = isNetwork
        ? Image.network(node.url, errorBuilder: errorBuilder)
        : Image.file(File(node.url), errorBuilder: errorBuilder);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          image,
          if (node.altText != null && node.altText!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                node.altText!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  TextStyle _styleFor(ThemeData theme, TextNode node) {
    var base = theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16);
    if (node.blockType == 'listItemTask' && node.isChecked) {
      base = base.copyWith(
        decoration: TextDecoration.lineThrough,
        color: theme.hintColor,
      );
    }
    switch (node.blockType) {
      case 'header1':
        return base.copyWith(fontSize: 32, fontWeight: FontWeight.bold);
      case 'header2':
        return base.copyWith(fontSize: 28, fontWeight: FontWeight.bold);
      case 'header3':
        return base.copyWith(fontSize: 24, fontWeight: FontWeight.bold);
      case 'header4':
        return base.copyWith(fontSize: 20, fontWeight: FontWeight.bold);
      case 'header5':
        return base.copyWith(fontSize: 18, fontWeight: FontWeight.bold);
      case 'header6':
        return base.copyWith(fontSize: 16, fontWeight: FontWeight.bold);
      case 'blockquote':
        return base.copyWith(fontStyle: FontStyle.italic);
      case 'code':
        return base.copyWith(fontFamily: 'monospace');
      default:
        return base;
    }
  }

  TextAlign _textAlignFor(TextNode node) {
    switch (node.metadata['textAlign']) {
      case 'center':
        return TextAlign.center;
      case 'right':
        return TextAlign.right;
      case 'justify':
        return TextAlign.justify;
      default:
        return TextAlign.left;
    }
  }

  /// The bullet/number sits beside its own `EditableText`, so it has to carry
  /// the node's text style itself — otherwise it renders at the default size
  /// and its baseline drifts off the line it labels.
  Widget? _prefixFor(BuildContext context, TextNode node) {
    if (node.blockType == 'listItemTask') {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Checkbox(
          value: node.isChecked,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          // canRequestFocus: false keeps the checkbox from stealing focus
          // (and thus the keyboard) away from the node's text field.
          focusNode: FocusNode(canRequestFocus: false),
          onChanged: (_) => widget.controller.toggleTaskChecked(node.id),
        ),
      );
    }
    final label = switch (node.blockType) {
      'listItemUnordered' => '•',
      'listItemOrdered' =>
        '${_orderedListNumber(widget.controller.document, node.id)}.',
      _ => null,
    };
    if (label == null) return null;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Text(label, style: _styleFor(Theme.of(context), node)),
    );
  }

  /// The number to show for an ordered-list item: 1-based within the
  /// contiguous run of `listItemOrdered` nodes at the same indent — a
  /// deeper indent starts its own run at 1, and any non-matching node
  /// (different block type or shallower indent) breaks the run.
  int _orderedListNumber(MutableDocument document, String nodeId) {
    final index = document.getNodeIndexById(nodeId);
    if (index < 0) return 1;
    final node = document.getNodeAt(index) as TextNode;
    var count = 1;
    for (var i = index - 1; i >= 0; i--) {
      final prev = document.getNodeAt(i);
      if (prev is! TextNode) break;
      if (prev.indent > node.indent) continue;
      if (prev.indent < node.indent) break;
      if (prev.blockType == 'listItemOrdered') {
        count++;
      } else {
        break;
      }
    }
    return count;
  }
}
