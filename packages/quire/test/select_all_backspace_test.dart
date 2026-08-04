import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

// Bug repro: Select All (the touch-context-menu path, which calls
// `controller.selectAll()`) followed by a SOFT-KEYBOARD backspace — arriving
// as a text diff through the focused field's own NodeTextController, never a
// key event — should delete the whole document. See quire_editor.dart
// `_onControllerChanged`'s cross-node branch and `replaceSelectionWithText`.

Future<void> _pumpEditor(
  WidgetTester tester,
  QuireEditorController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: QuireEditor(controller: controller))),
  );
}

void main() {
  testWidgets(
    'a selection-only report from the focused field (text unchanged) while '
    'a multi-node selection is active must not collapse composer.selection '
    'to that field\'s own stale local caret',
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

      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      expect(controller.focusedNodeId, 'a');

      controller.selectAll();
      await tester.pump();
      final preSelection = controller.composer.selection!;
      expect(preSelection.base.nodeId, isNot(preSelection.extent.nodeId));

      // The focused field's OWN controller reports a selection-only change
      // (text unchanged) — e.g. iOS repositioning the field's local caret,
      // or any spurious selection notification from the platform.
      final fieldController = tester
          .widget<EditableText>(find.byType(EditableText).first)
          .controller;
      fieldController.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();

      final postSelection = controller.composer.selection;
      expect(postSelection, isNotNull);
      expect(
        postSelection!.base.nodeId,
        isNot(postSelection.extent.nodeId),
        reason:
            'a stale local selection-only report from one field collapsed '
            'the document-wide selection',
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

      // Focus lands in node 'a', the way a real tap-then-select-all would.
      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      expect(controller.focusedNodeId, 'a');

      controller.selectAll();
      await tester.pump();

      // Selection must span the whole document before the delete arrives.
      final preDeleteSelection = controller.composer.selection;
      expect(preDeleteSelection, isNotNull);
      expect(
        preDeleteSelection!.base.nodeId,
        isNot(preDeleteSelection.extent.nodeId),
        reason: 'composer.selection collapsed before the backspace arrived',
      );

      // Focus (and thus which field the soft keyboard talks to) is still
      // 'a' — selectAll() never moves it.
      expect(controller.focusedNodeId, 'a');

      // The platform reports the focused field's local caret before the
      // actual delete arrives (see the test above) — reproduces the exact
      // sequence a real device hits.
      final fieldController = tester
          .widget<EditableText>(find.byType(EditableText).first)
          .controller;
      fieldController.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();

      // Soft-keyboard backspace: the OS edits the focused field's own text
      // directly, one character shorter, with no key event at all.
      await tester.enterText(find.byType(EditableText).first, 'on');
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

      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      controller.selectAll();
      await tester.pump();

      await tester.enterText(find.byType(EditableText).first, 'X');
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      final remaining = controller.document.nodes.single as TextNode;
      expect(remaining.text.text, 'X');
    },
  );

  testWidgets(
    'select-all then a HARDWARE-keyboard backspace also deletes the whole '
    'document',
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

      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      controller.selectAll();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      final remaining = controller.document.nodes.single as TextNode;
      expect(remaining.text.text, isEmpty);
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

      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      controller.selectAll();
      await tester.pump();

      final preDeleteSelection = controller.composer.selection;
      expect(preDeleteSelection, isNotNull);
      expect(
        preDeleteSelection!.base.nodeId,
        isNot(preDeleteSelection.extent.nodeId),
      );

      await tester.enterText(find.byType(EditableText).first, 'on');
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      final remaining = controller.document.nodes.single as TextNode;
      expect(remaining.text.text, isEmpty);
    },
  );
}
