import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

import 'support/ime.dart';

void main() {
  testWidgets('backspacing back to the end of a bold run keeps typing bold', (
    tester,
  ) async {
    const bold = Attribution('bold');
    final c = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('hi bold', [AttributionSpan(bold, 3, 7)]),
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireEditor(controller: c)),
      ),
    );
    await tester.tap(find.byType(QuireEditor));
    await tester.pumpAndSettle();
    c.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(7)),
      ),
    );
    await tester.pump();

    await typeText(tester, ' ');
    await backspace(tester);
    await typeText(tester, 'Y');
    await tester.pump();

    final text = (c.document.getNodeById('a') as TextNode).text;
    expect(text.text, 'hi boldY');
    expect(text.hasAttributionThroughout(bold, 3, 8), isTrue);
  });

  Future<(QuireEditorController, WidgetTester)> boldLine(
    WidgetTester tester,
  ) async {
    const bold = Attribution('bold');
    final c = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('hi bold', [AttributionSpan(bold, 3, 7)]),
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireEditor(controller: c)),
      ),
    );
    await tester.tap(find.byType(QuireEditor));
    await tester.pumpAndSettle();
    c.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(7)),
      ),
    );
    await tester.pump();
    return (c, tester);
  }

  testWidgets('a new line starts plain', (tester) async {
    final (c, _) = await boldLine(tester);
    await pressEnter(tester);
    await typeText(tester, 'Z');
    await tester.pump();
    final second = c.document.nodes[1] as TextNode;
    expect(second.text.text, contains('Z'));
    expect(second.text.spans, isEmpty);
  });

  testWidgets('a double space drops the style', (tester) async {
    final (c, _) = await boldLine(tester);
    for (final ch in [' ', ' ', 'Z']) {
      await typeText(tester, ch);
    }
    await tester.pump();
    final text = (c.document.getNodeById('a') as TextNode).text;
    expect(text.text, 'hi bold  Z');
    expect(
      text.hasAttributionThroughout(const Attribution('bold'), 3, 8),
      isTrue,
    );
    expect(text.attributionsAt(9), isEmpty);
    expect(text.attributionsAt(8), isEmpty);
  });
}
