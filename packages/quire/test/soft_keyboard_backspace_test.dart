import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

import 'support/ime.dart';

// These simulate the soft-keyboard path: a delta the platform sends for the
// focused node, never a physical key event.

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
    'emptying the field over an empty paragraph below an image deletes '
    'the image and leaves the paragraph',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            ImageNode(id: 'img', url: '/no/such/file.png'),
            TextNode(id: 'p', text: AttributedText('')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(findNode('p'));
      await tester.pumpAndSettle();
      // Backspace at offset 0 of an already-empty paragraph — the sentinel
      // is all there is to delete.
      await backspace(tester);
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      expect(controller.document.getNodeById('img'), isNull);
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
    'emptying the field over an empty paragraph below a table deletes '
    'the table and leaves the paragraph',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TableNode(
              id: 't',
              rows: [
                TableRow(
                  cells: [
                    TableCell(
                      nodes: [TextNode(id: 'c', text: AttributedText('x'))],
                    ),
                  ],
                ),
              ],
            ),
            TextNode(id: 'p', text: AttributedText('')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(findNode('p'));
      await tester.pumpAndSettle();
      await backspace(tester);
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      expect(controller.document.getNodeById('t'), isNull);
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

  testWidgets('emptying the field over an empty paragraph merges it into the '
      'previous paragraph', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(id: 'a', text: AttributedText('hello')),
          TextNode(id: 'b', text: AttributedText('')),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(findNode('b'));
    await tester.pumpAndSettle();
    await backspace(tester);
    await tester.pump();

    expect(controller.document.nodes.length, 1);
    expect(controller.document.getNodeById('b'), isNull);
    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      'hello',
    );
    expect(
      controller.composer.selection,
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(5)),
      ),
    );
  });

  testWidgets(
    'typing into an empty paragraph produces exactly the typed text, no '
    'sentinel anywhere',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText(''))],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      await typeText(tester, 'hi');
      await tester.pump();

      // Exact equality is the sentinel check: a leaked sentinel would show
      // up as a leading space here.
      final node = controller.document.getNodeById('a') as TextNode;
      expect(node.text.text, 'hi');
    },
  );

  testWidgets("toJson of an untouched empty node contains no sentinel", (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      isEmpty,
    );
  });
}
