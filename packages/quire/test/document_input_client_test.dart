import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

import 'support/ime.dart';

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
  testWidgets('typing a sentence via deltas updates the model', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(0)),
      ),
    );
    controller.requestFocus('a');
    await tester.pump();

    await typeText(tester, 'hello');
    await typeText(tester, ' world');

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      'hello world',
    );
  });

  testWidgets('backspace inside text deletes the previous grapheme', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
      ),
    );
    await _pumpEditor(tester, controller);
    controller.requestFocus('a');
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(5)),
      ),
    );
    await tester.pump();

    await backspace(tester);

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      'hell',
    );
  });

  testWidgets(
    'backspace at start of an empty-sentinel field merges with previous',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('hello')),
            TextNode(id: 'b', text: AttributedText('world')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);
      controller.requestFocus('b');
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('b', const TextNodePosition(0)),
        ),
      );
      await tester.pump();

      await backspace(tester);

      expect(controller.document.nodes.length, 1);
      expect(
        (controller.document.getNodeAt(0) as TextNode).text.text,
        'helloworld',
      );
    },
  );

  testWidgets('Enter (as a newline delta) splits the node', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
      ),
    );
    await _pumpEditor(tester, controller);
    controller.requestFocus('a');
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(5)),
      ),
    );
    await tester.pump();

    await pressEnter(tester);

    expect(controller.document.nodes.length, 2);
    final first = controller.document.getNodeAt(0) as TextNode;
    final second = controller.document.getNodeAt(1) as TextNode;
    expect(first.text.text, 'hello');
    expect(second.text.text, ' world');
  });

  testWidgets(
    'cross-node selection + typed char replaces the whole selection',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('hello')),
            TextNode(id: 'b', text: AttributedText('world')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);
      controller.requestFocus('a');
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(2)),
          extent: DocumentPosition('b', const TextNodePosition(3)),
        ),
      );
      await tester.pump();

      await typeText(tester, 'X');

      expect(controller.document.nodes.length, 1);
      expect((controller.document.getNodeAt(0) as TextNode).text.text, 'heXld');
    },
  );

  testWidgets('unfocus closes the IME connection; requestFocus reopens it', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hi'))],
      ),
    );
    await _pumpEditor(tester, controller);
    controller.requestFocus('a');
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);

    controller.requestFocus('a');
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets(
    'the IME connection stays open when the caret moves between nodes',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('hello')),
            TextNode(id: 'b', text: AttributedText('world')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);
      controller.requestFocus('a');
      await tester.pump();
      final setClientCalls = tester.testTextInput.log
          .where((c) => c.method == 'TextInput.setClient')
          .length;

      controller.requestFocus('b');
      await tester.pump();

      expect(
        tester.testTextInput.log
            .where((c) => c.method == 'TextInput.setClient')
            .length,
        setClientCalls,
      );
      expect(tester.testTextInput.isVisible, isTrue);
    },
  );
}
