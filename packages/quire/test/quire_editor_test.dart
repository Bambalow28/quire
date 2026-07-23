import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

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
  testWidgets('typing into a paragraph updates the model\'s AttributedText', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'hello world');
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      'hello world',
    );
  });

  testWidgets('pressing Enter splits into two nodes and moves focus', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(5)),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.document.nodes.length, 2);
    final first = controller.document.getNodeAt(0) as TextNode;
    final second = controller.document.getNodeAt(1) as TextNode;
    expect(first.text.text, 'hello');
    expect(second.text.text, ' world');
    expect(controller.focusedNodeId, second.id);
    expect(
      controller.composer.selection,
      DocumentSelection.collapsed(
        DocumentPosition(second.id, const TextNodePosition(0)),
      ),
    );
  });

  testWidgets(
    'backspace at offset 0 merges back into one node with the text intact',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('hello ')),
            TextNode(id: 'b', text: AttributedText('world')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(find.byType(EditableText).at(1));
      await tester.pumpAndSettle();
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('b', const TextNodePosition(0)),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      expect(
        (controller.document.getNodeById('a') as TextNode).text.text,
        'hello world',
      );
      expect(controller.document.getNodeById('b'), isNull);
    },
  );

  testWidgets(
    'a "\\n" arriving through the controller splits the node (soft-keyboard Enter)',
    (tester) async {
      // A soft keyboard's Return key never emits a key event — it lands as
      // a literal "\n" inside the field's text, exactly like `enterText`
      // simulates here.
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).first, 'hello\n world');
      await tester.pump();

      expect(controller.document.nodes.length, 2);
      final first = controller.document.getNodeAt(0) as TextNode;
      final second = controller.document.getNodeAt(1) as TextNode;
      expect(first.text.text, 'hello');
      expect(second.text.text, ' world');
    },
  );

  testWidgets('typing over a bold selection keeps the replacement bold', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('hello world', [
              const AttributionSpan(Attribution('bold'), 0, 5),
            ]),
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition('a', const TextNodePosition(0)),
        extent: DocumentPosition('a', const TextNodePosition(5)),
      ),
    );
    await tester.pump();

    // Replace the bold "hello" with "howdy" in one shot (as `enterText`
    // does for the currently-focused field).
    await tester.enterText(find.byType(EditableText).first, 'howdy world');
    await tester.pump();

    final text = (controller.document.getNodeById('a') as TextNode).text;
    expect(text.text, 'howdy world');
    expect(
      text.hasAttributionThroughout(const Attribution('bold'), 0, 5),
      isTrue,
    );
  });

  testWidgets('toggling bold over a selection puts a bold span in the model', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition('a', const TextNodePosition(0)),
        extent: DocumentPosition('a', const TextNodePosition(5)),
      ),
    );
    await tester.pump();

    controller.toggleBold();
    await tester.pump();

    final text = (controller.document.getNodeById('a') as TextNode).text;
    expect(
      text.hasAttributionThroughout(const Attribution('bold'), 0, 5),
      isTrue,
    );
  });

  testWidgets('undo after a few edits restores the original document JSON', (
    tester,
  ) async {
    final doc = MutableDocument(
      nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
    );
    final originalJson = doc.toJson();
    final controller = QuireEditorController(document: doc);
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'hello world');
    await tester.pump();
    await tester.enterText(find.byType(EditableText).first, 'hello world!!');
    await tester.pump();

    controller.undo();
    controller.undo();
    await tester.pump();

    expect(controller.document.toJson(), originalJson);
  });
}
