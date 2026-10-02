import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  testWidgets('blocks announce their role to screen readers', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final handle = tester.ensureSemantics();
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'h',
            text: AttributedText('Plans'),
            metadata: {'blockType': 'header2'},
          ),
          TextNode(
            id: 't',
            text: AttributedText('Ship it'),
            metadata: {'blockType': 'listItemTask', 'checked': true},
          ),
          TextNode(
            id: 'b',
            text: AttributedText('milk'),
            metadata: {'blockType': 'listItemUnordered'},
          ),
          ImageNode(id: 'i', url: 'x.png', altText: 'A cat'),
          TableNode(
            id: 'tb',
            rows: [
              TableRow(
                cells: [
                  TableCell(
                    nodes: [TextNode(id: 'c', text: AttributedText('cell'))],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireEditor(controller: controller)),
      ),
    );

    expect(
      find.bySemanticsLabel(RegExp('Table, 1 rows, 1\\s*columns')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('A cat'), findsOneWidget);
    final heading = tester.getSemantics(
      find.byKey(const ValueKey('quire-node-h')),
    );
    expect(heading.hint, 'Heading level 2');
    expect(heading.flagsCollection.isHeader, isTrue);
    final task = tester.getSemantics(find.bySemanticsLabel('Ship it'));
    expect(task.hint, 'Task');
    expect(task.flagsCollection.isChecked.name, 'isTrue');
    expect(
      tester.getSemantics(find.byKey(const ValueKey('quire-node-b'))).hint,
      'Bulleted list item',
    );
    handle.dispose();
  });
}
