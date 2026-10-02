@Tags(['golden'])
library;

import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

MutableDocument _doc() {
  TextNode t(String id, String text, [Map<String, Object?>? meta]) =>
      TextNode(id: id, text: AttributedText(text), metadata: meta);
  return MutableDocument(
    nodes: [
      t('h1', 'Heading one', {'blockType': 'header1'}),
      t('h2', 'Heading two', {'blockType': 'header2'}),
      t('p', 'A plain paragraph of text.'),
      t('ul', 'Bullet item', {'blockType': 'listItemUnordered'}),
      t('ol', 'Numbered item', {'blockType': 'listItemOrdered'}),
      t('todo', 'Open task', {'blockType': 'listItemTask'}),
      t('done', 'Done task', {'blockType': 'listItemTask', 'checked': true}),
      t('q', 'A quotation', {'blockType': 'blockquote'}),
      t('code', 'final x = 1;', {'blockType': 'code'}),
      t('callout', 'Heads up', {'blockType': 'callout'}),
      t('inner', 'inside the callout', {'indent': 1}),
      TableNode(
        id: 'tb',
        rows: [
          for (var r = 0; r < 2; r++)
            TableRow(
              cells: [
                for (var c = 0; c < 2; c++)
                  TableCell(nodes: [t('c$r$c', 'r$r c$c')]),
              ],
            ),
        ],
      ),
    ],
  );
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('block rendering, ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(600, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: QuireEditor(
              controller: QuireEditorController(document: _doc()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/blocks_${brightness.name}.png'),
      );
    });
  }
}
