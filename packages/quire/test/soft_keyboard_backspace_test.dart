import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

// These simulate the soft-keyboard path: a field's whole text arriving
// through `enterText` (the diff-based controller-change path), never a
// physical key event.

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

      // Only 'p' is a TextNode, so it's the sole EditableText; its field
      // already carries the sentinel from the initial model->field push.
      await tester.enterText(find.byType(EditableText).first, '');
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

      // Index 0 is the table's cell field, index 1 is the trailing
      // paragraph, which already carries the sentinel.
      await tester.enterText(find.byType(EditableText).at(1), '');
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

    await tester.enterText(find.byType(EditableText).at(1), '');
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

      // The field carries the sentinel + typed text, exactly what a soft
      // keyboard would report after typing "hi" at the caret.
      await tester.enterText(find.byType(EditableText).first, '​hi');
      await tester.pump();

      final node = controller.document.getNodeById('a') as TextNode;
      expect(node.text.text, 'hi');
      expect(node.text.text.contains('​'), isFalse);
      final json = controller.document.toJson().toString();
      expect(json.contains('​'), isFalse);
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

    final json = controller.document.toJson().toString();
    expect(json.contains('​'), isFalse);
    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      isEmpty,
    );
  });
}
