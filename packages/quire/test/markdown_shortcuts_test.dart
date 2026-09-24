import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

// Typing a markdown prefix + space converts the paragraph. These
// drive the field the way the soft keyboard does — a whole new field text
// via `enterText`, diffed by the controller-change path in quire_editor.dart
// — since that's the one hook both hardware and soft-keyboard typing share.
// The trigger only fires on the keystroke that types the *trailing space*
// as a pure single-character insert, so tests that want it to fire type the
// prefix and the space as two separate `enterText` calls, exactly like a
// real keystroke-by-keystroke session would produce.

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

/// Types [textBeforeSpace], then types a trailing space as its own
/// keystroke — the only shape that triggers a markdown/auto-link shortcut.
Future<void> _typeThenSpace(
  WidgetTester tester,
  String textBeforeSpace, {
  String suffix = '',
}) async {
  final field = find.byType(EditableText).first;
  await tester.enterText(field, textBeforeSpace + suffix);
  await tester.pump();
  await tester.enterText(field, '$textBeforeSpace $suffix');
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('"- " converts to a bullet list, and Undo restores the '
      'literal text', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _typeThenSpace(tester, '-');

    final node = controller.document.getNodeById('a') as TextNode;
    expect(node.blockType, 'listItemUnordered');
    expect(node.text.text, isEmpty);
    expect(
      controller.composer.selection,
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(0)),
      ),
    );

    // One Undo undoes the conversion, restoring the literal "- ".
    controller.undo();
    final restored = controller.document.getNodeById('a') as TextNode;
    expect(restored.blockType, 'paragraph');
    expect(restored.text.text, '- ');
  });

  testWidgets('"1. " converts to a numbered list', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _typeThenSpace(tester, '1.');

    final node = controller.document.getNodeById('a') as TextNode;
    expect(node.blockType, 'listItemOrdered');
    expect(node.text.text, isEmpty);
  });

  testWidgets('"[] " converts to an unchecked task', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _typeThenSpace(tester, '[]');

    final node = controller.document.getNodeById('a') as TextNode;
    expect(node.blockType, 'listItemTask');
    expect(node.isChecked, isFalse);
  });

  testWidgets('"[x] " converts to a checked task', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _typeThenSpace(tester, '[x]');

    final node = controller.document.getNodeById('a') as TextNode;
    expect(node.blockType, 'listItemTask');
    expect(node.isChecked, isTrue);
  });

  testWidgets('"# " converts to header1, and text after the caret is kept', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('Title'))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _typeThenSpace(tester, '#', suffix: 'Title');

    final node = controller.document.getNodeById('a') as TextNode;
    expect(node.blockType, 'header1');
    expect(node.text.text, 'Title');
  });

  testWidgets('"### " converts to header3', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _typeThenSpace(tester, '###');

    final node = controller.document.getNodeById('a') as TextNode;
    expect(node.blockType, 'header3');
  });

  testWidgets('"> " converts to a blockquote', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _typeThenSpace(tester, '>');

    final node = controller.document.getNodeById('a') as TextNode;
    expect(node.blockType, 'blockquote');
  });

  testWidgets('a prefix typed mid-text does not convert', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('foo-'))],
      ),
    );
    await _pumpEditor(tester, controller);

    // "-" isn't at the very start of the node, so the trailing space
    // doesn't complete a shortcut prefix.
    await _typeThenSpace(tester, 'foo-');

    final node = controller.document.getNodeById('a') as TextNode;
    expect(node.blockType, 'paragraph');
    expect(node.text.text, 'foo- ');
  });

  testWidgets('typing in a non-paragraph block does not convert', (
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

    await _typeThenSpace(tester, '-');

    final node = controller.document.getNodeById('a') as TextNode;
    expect(node.blockType, 'header1');
    expect(node.text.text, '- ');
  });

  testWidgets('"---" as the whole node, then a space, becomes a rule', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _typeThenSpace(tester, '---');

    final nodes = controller.document.nodesInDocumentOrder.toList();
    expect(nodes.whereType<HorizontalRuleNode>(), hasLength(1));
    // A trailing paragraph is parked for the caret, same as insertImage.
    expect(nodes.last, isA<TextNode>());
  });

  testWidgets('iOS smart-dash "—-" then a space also becomes a rule', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _typeThenSpace(tester, '—-');

    expect(
      controller.document.nodesInDocumentOrder.whereType<HorizontalRuleNode>(),
      hasLength(1),
    );
  });

  test('a pasted "---" line followed by more lines keeps all its text', () {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(0)),
      ),
    );
    controller.replaceSelectionWithText('---\nfoo', requestFocusAfter: false);
    final texts = controller.document.nodes
        .whereType<TextNode>()
        .map((n) => n.text.text)
        .toList();
    expect(texts, ['---', 'foo']);
  });
}
