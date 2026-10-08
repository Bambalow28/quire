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
}
