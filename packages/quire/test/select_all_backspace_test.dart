import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

import 'support/ime.dart';

// Bug repro (pre-rewrite): Select All (the touch-context-menu path, which
// calls `controller.selectAll()`) followed by a SOFT-KEYBOARD backspace —
// arriving as a text diff through the focused field's own
// NodeTextController, never a key event — needed to delete the whole
// document, and a stale selection-only report from that same field's local
// caret could not be allowed to collapse the real, cross-node
// `composer.selection`. There is no per-node field/local selection any
// more — `DocumentInputClient` reads `composer.selection` directly and
// ignores selection-only deltas entirely while in cross-node mode (see
// `document_input_client.dart`'s `_applySelectionOnly`) — so this now
// exercises the same end-to-end behaviour through the real delta path.

Future<void> _pumpEditor(
  WidgetTester tester,
  QuireEditorController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: QuireEditor(controller: controller)),
    ),
  );
}

void main() {
  testWidgets(
    'a selection-only delta while a multi-node selection is active must not '
    'collapse composer.selection to a single-node caret',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('one')),
            TextNode(
              id: 'b',
              text: AttributedText('two'),
              metadata: {'blockType': 'listItemTask'},
            ),
            TextNode(id: 'c', text: AttributedText('three')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      expect(controller.focusedNodeId, 'a');

      controller.selectAll();
      await tester.pump();
      final preSelection = controller.composer.selection!;
      expect(preSelection.base.nodeId, isNot(preSelection.extent.nodeId));

      // A selection-only report while in cross-node mode — e.g. iOS
      // repositioning the placeholder's own caret, or any spurious
      // selection notification from the platform.
      await moveSelection(tester, const TextSelection.collapsed(offset: 1));

      final postSelection = controller.composer.selection;
      expect(postSelection, isNotNull);
      expect(
        postSelection!.base.nodeId,
        isNot(postSelection.extent.nodeId),
        reason:
            'a stale selection-only delta collapsed the document-wide '
            'selection',
      );
    },
  );

  testWidgets(
    'select-all then a soft-keyboard backspace deletes the whole document, '
    'even with a checklist item (non-paragraph block type) in the middle',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('one')),
            TextNode(
              id: 'b',
              text: AttributedText('two'),
              metadata: {'blockType': 'listItemTask'},
            ),
            TextNode(id: 'c', text: AttributedText('three')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      expect(controller.focusedNodeId, 'a');

      controller.selectAll();
      await tester.pump();

      final preDeleteSelection = controller.composer.selection;
      expect(preDeleteSelection, isNotNull);
      expect(
        preDeleteSelection!.base.nodeId,
        isNot(preDeleteSelection.extent.nodeId),
        reason: 'composer.selection collapsed before the backspace arrived',
      );
      expect(controller.focusedNodeId, 'a');

      await backspace(tester);
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      final remaining = controller.document.nodes.single as TextNode;
      expect(remaining.text.text, isEmpty);
      expect(
        controller.composer.selection,
        DocumentSelection.collapsed(
          DocumentPosition(remaining.id, const TextNodePosition(0)),
        ),
      );
    },
  );

  testWidgets(
    'select-all then typing a character (soft keyboard) replaces the whole '
    'document with that character',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('one')),
            TextNode(
              id: 'b',
              text: AttributedText('two'),
              metadata: {'blockType': 'listItemTask'},
            ),
            TextNode(id: 'c', text: AttributedText('three')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      controller.selectAll();
      await tester.pump();

      await typeText(tester, 'X');
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      final remaining = controller.document.nodes.single as TextNode;
      expect(remaining.text.text, 'X');
    },
  );

  testWidgets(
    'select-all then a HARDWARE-keyboard backspace (desktop) also deletes '
    'the whole document',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('one')),
            TextNode(
              id: 'b',
              text: AttributedText('two'),
              metadata: {'blockType': 'listItemTask'},
            ),
            TextNode(id: 'c', text: AttributedText('three')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      controller.selectAll();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      final remaining = controller.document.nodes.single as TextNode;
      expect(remaining.text.text, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'select-all over a document with a HorizontalRuleNode and a TableNode '
    'in the middle deletes everything without crashing',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('one')),
            HorizontalRuleNode(id: 'hr'),
            TableNode(
              id: 't',
              rows: [
                TableRow(
                  cells: [
                    TableCell(
                      nodes: [TextNode(id: 'cell', text: AttributedText('x'))],
                    ),
                  ],
                ),
              ],
            ),
            TextNode(id: 'c', text: AttributedText('three')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      controller.selectAll();
      await tester.pump();

      final preDeleteSelection = controller.composer.selection;
      expect(preDeleteSelection, isNotNull);
      expect(
        preDeleteSelection!.base.nodeId,
        isNot(preDeleteSelection.extent.nodeId),
      );

      await backspace(tester);
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      final remaining = controller.document.nodes.single as TextNode;
      expect(remaining.text.text, isEmpty);
    },
  );
}
