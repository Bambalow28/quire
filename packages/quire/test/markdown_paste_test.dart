import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

// Pasting text from outside the app (no in-app rich nodes for
// it) converts it via quire_markdown when it looks like Markdown, and
// pastes it literally otherwise.

void main() {
  // Same test-only clipboard shim as rich_clipboard_test.dart: flutter_test
  // has no real platform clipboard, so Clipboard.setData/getData round-trip
  // through this instead.
  late String stored;
  setUp(() {
    stored = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            stored = (call.arguments as Map)['text'] as String;
          } else if (call.method == 'Clipboard.getData') {
            return {'text': stored};
          }
          return null;
        });
  });

  testWidgets('a markdown bullet list pastes as list-item nodes', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    stored = '- one\n- two';

    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(0)),
      ),
    );
    await controller.pasteClipboard();

    final nodes = controller.document.nodesInDocumentOrder
        .toList()
        .cast<TextNode>();
    expect(nodes.every((n) => n.blockType == 'listItemUnordered'), isTrue);
    expect(nodes.map((n) => n.text.text), ['one', 'two']);
  });

  testWidgets('a one-line "**bold** text" markdown paste lands inline in the '
      'current paragraph', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('Note: '))],
      ),
    );
    stored = '**bold** text';

    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(6)),
      ),
    );
    await controller.pasteClipboard();

    final node = controller.document.getNodeById('a')! as TextNode;
    expect(node.blockType, 'paragraph');
    expect(node.text.text, 'Note: bold text');
    expect(
      node.text.hasAttributionThroughout(const Attribution('bold'), 6, 10),
      isTrue,
    );
  });

  testWidgets('plain prose with no markup pastes unchanged', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    stored = 'Just some plain prose, nothing special here.';

    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(0)),
      ),
    );
    await controller.pasteClipboard();

    final node = controller.document.getNodeById('a')! as TextNode;
    expect(node.blockType, 'paragraph');
    expect(node.text.text, 'Just some plain prose, nothing special here.');
    expect(node.text.spans, isEmpty);
  });

  testWidgets('a markdown table pastes as a table, text around it kept', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    stored = '- before\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\n- after';
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(0)),
      ),
    );
    await controller.pasteClipboard();

    final doc = controller.document;
    final tables = doc.nodes.whereType<TableNode>().toList();
    expect(tables, hasLength(1));
    expect(tables.single.gridSize, (2, 2));
    final texts = doc.nodes.whereType<TextNode>().map((n) => n.text.text);
    expect(texts, containsAll(['before', 'after']));
    expect(validateDocument(doc, controller.composer.selection), isEmpty);
  });

  testWidgets('a pasted table lands between the two halves of the caret line', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('foobar'))],
      ),
    );
    stored = '| a |\n| - |\n| 1 |';
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(3)),
      ),
    );
    await controller.pasteClipboard();

    final order = controller.document.nodes
        .map((n) => n is TextNode ? n.text.text : n.type)
        .where((t) => t.isNotEmpty)
        .toList();
    expect(order, ['foo', 'table', 'bar']);
  });
}
