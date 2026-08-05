import 'package:flutter/material.dart';
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
  testWidgets('typing a lowercase letter into an empty paragraph capitalizes it', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'h');
    await tester.pump();

    expect((controller.document.getNodeById('a') as TextNode).text.text, 'H');
  });

  testWidgets('typing a second character afterward is not re-capitalized', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'h');
    await tester.pump();
    // The field now shows the capitalized 'H' from the previous keystroke;
    // simulate the next keystroke appending 'e' to that real field content.
    await tester.enterText(find.byType(EditableText).first, 'He');
    await tester.pump();

    expect((controller.document.getNodeById('a') as TextNode).text.text, 'He');
  });

  testWidgets(
    'typing into a node that already has text does not force-capitalize, even at offset 0',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('ello'))],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(0)),
        ),
      );
      await tester.pump();
      // Insert 'h' at offset 0 of a node that already has text: field text
      // becomes the sentinel + 'h' + 'ello' == 'hello' (post-strip).
      await tester.enterText(find.byType(EditableText).first, 'hello');
      await tester.pump();

      expect(
        (controller.document.getNodeById('a') as TextNode).text.text,
        'hello',
      );
    },
  );

  testWidgets('pasting a multi-character string into an empty node only capitalizes the first character', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'hello world');
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      'Hello world',
    );
  });

  testWidgets('a digit as the first character of an empty node is left alone', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, '5 apples');
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      '5 apples',
    );
  });

  testWidgets('an already-uppercase first character is left alone', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'Hello');
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      'Hello',
    );
  });

  testWidgets('the first letter of an empty heading capitalizes', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText(''),
            metadata: {'blockType': 'header1'},
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'title');
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      'Title',
    );
  });

  testWidgets('the first letter of an empty checklist item capitalizes', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText(''),
            metadata: {'blockType': 'listItemTask'},
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'buy milk');
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      'Buy milk',
    );
  });

  testWidgets('a code block does not auto-capitalize its first letter', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText(''),
            metadata: {'blockType': 'code'},
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'print(x)');
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      'print(x)',
    );
  });

  testWidgets('undo removes exactly the capitalized character, redo restores it', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'h');
    await tester.pump();
    expect((controller.document.getNodeById('a') as TextNode).text.text, 'H');

    controller.history.undo();
    await tester.pump();
    expect((controller.document.getNodeById('a') as TextNode).text.text, '');

    controller.history.redo();
    await tester.pump();
    expect((controller.document.getNodeById('a') as TextNode).text.text, 'H');
  });
}
