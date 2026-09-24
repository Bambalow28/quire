import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

// A bare URL token followed by a space gets auto-linked. Same
// two-keystroke shape as the markdown shortcut tests — the trailing space
// has to arrive as its own pure single-character insert to trigger it.

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

Future<void> _typeThenSpace(WidgetTester tester, String textBeforeSpace) async {
  final field = find.byType(EditableText).first;
  await tester.enterText(field, textBeforeSpace);
  await tester.pump();
  await tester.enterText(field, '$textBeforeSpace ');
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('a bare https URL followed by a space gets linked', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _typeThenSpace(tester, 'https://example.com');

    final node = controller.document.getNodeById('a') as TextNode;
    expect(node.text.text, 'https://example.com ');
    final link = node.text.spans.singleWhere(
      (s) => s.attribution.name == 'link',
    );
    expect(link.start, 0);
    expect(link.end, 'https://example.com'.length);
    expect(link.attribution.value['url'], 'https://example.com');
  });

  testWidgets('a "www." URL gets an https:// prefix', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _typeThenSpace(tester, 'www.example.com');

    final node = controller.document.getNodeById('a') as TextNode;
    final link = node.text.spans.singleWhere(
      (s) => s.attribution.name == 'link',
    );
    expect(link.attribution.value['url'], 'https://www.example.com');
  });

  testWidgets('trailing sentence punctuation is not linked', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _typeThenSpace(tester, 'see https://example.com,');

    final node = controller.document.getNodeById('a') as TextNode;
    final link = node.text.spans.singleWhere(
      (s) => s.attribution.name == 'link',
    );
    expect(link.end, node.text.text.indexOf(','));
  });

  testWidgets('a URL inside a code block is not linked', (tester) async {
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

    await _typeThenSpace(tester, 'https://example.com');

    final node = controller.document.getNodeById('a') as TextNode;
    expect(node.text.spans.where((s) => s.attribution.name == 'link'), isEmpty);
  });
}
