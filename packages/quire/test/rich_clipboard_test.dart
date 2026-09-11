import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

const _bold = Attribution('bold');
const _italic = Attribution('italic');

void main() {
  // A test-only clipboard: flutter_test doesn't wire up a real platform
  // clipboard, so Clipboard.setData/getData round-trip through this instead.
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

  testWidgets('same-app rich copy+paste preserves bold/italic', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('bold and italic', [
              AttributionSpan(_bold, 0, 4),
              AttributionSpan(_italic, 9, 15),
            ]),
          ),
          TextNode(id: 'b', text: AttributedText('')),
        ],
      ),
    );

    controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition('a', const TextNodePosition(0)),
        extent: DocumentPosition('a', const TextNodePosition(16)),
      ),
    );
    await controller.copySelection();

    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('b', const TextNodePosition(0)),
      ),
    );
    await controller.pasteClipboard();

    final pasted = controller.document.getNodeById('b')! as TextNode;
    expect(pasted.text.text, 'bold and italic');
    expect(pasted.text.hasAttributionThroughout(_bold, 0, 4), isTrue);
    expect(pasted.text.hasAttributionThroughout(_italic, 9, 15), isTrue);
    expect(pasted.text.hasAttributionThroughout(_bold, 4, 9), isFalse);
  });

  testWidgets(
    'rich copy+paste across multiple blockTypes preserves each node\'s type',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'a',
              text: AttributedText('a heading'),
              metadata: {'blockType': 'header1'},
            ),
            TextNode(
              id: 'b',
              text: AttributedText('a list item'),
              metadata: {'blockType': 'listItemUnordered'},
            ),
            TextNode(id: 'target', text: AttributedText('landing zone')),
          ],
        ),
      );

      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(0)),
          extent: DocumentPosition('b', const TextNodePosition(11)),
        ),
      );
      await controller.copySelection();

      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('target', const TextNodePosition(7)),
        ),
      );
      await controller.pasteClipboard();

      final nodes = controller.document.nodesInDocumentOrder.toList();
      // Sources 'a'/'b' are untouched (copy duplicates, doesn't move); the
      // 'target' node absorbs the left prefix under the first pasted node's
      // block type, and a new node carries the last pasted node's block
      // type plus the split-off tail.
      expect((nodes[2] as TextNode).blockType, 'header1');
      expect((nodes[2] as TextNode).text.text, 'landinga heading');
      expect((nodes[3] as TextNode).blockType, 'listItemUnordered');
      expect((nodes[3] as TextNode).text.text, 'a list item zone');
    },
  );

  testWidgets(
    'external-clipboard-changed-since-copy falls back to plain text',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'a',
              text: AttributedText('bold text', [
                AttributionSpan(_bold, 0, 4),
              ]),
            ),
            TextNode(id: 'b', text: AttributedText('')),
          ],
        ),
      );

      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(0)),
          extent: DocumentPosition('a', const TextNodePosition(9)),
        ),
      );
      await controller.copySelection();

      // Something else copied outside Quire since — the OS clipboard no
      // longer matches the internal clipboard's plain-text snapshot.
      stored = 'from another app';

      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('b', const TextNodePosition(0)),
        ),
      );
      await controller.pasteClipboard();

      final pasted = controller.document.getNodeById('b')! as TextNode;
      expect(pasted.text.text, 'from another app');
      expect(pasted.text.spans, isEmpty);
    },
  );
}
