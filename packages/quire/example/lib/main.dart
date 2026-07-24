import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:quire/quire.dart';

void main() => runApp(const QuireExampleApp());

MutableDocument _seedDocument() => MutableDocument(
  nodes: [
    TextNode(
      id: 'heading',
      text: AttributedText('Welcome to Quire'),
      metadata: {'blockType': 'header1'},
    ),
    TextNode(
      id: 'p1',
      text: AttributedText('A paragraph with bold, italic and both at once.', [
        const AttributionSpan(Attribution('bold'), 17, 21),
        const AttributionSpan(Attribution('italic'), 23, 29),
        const AttributionSpan(Attribution('bold'), 34, 38),
        const AttributionSpan(Attribution('italic'), 34, 38),
      ]),
      metadata: {'blockType': 'paragraph'},
    ),
    TextNode(
      id: 'h2',
      text: AttributedText('Blocks'),
      metadata: {'blockType': 'header2'},
    ),
    TextNode(
      id: 'quote',
      text: AttributedText('A blockquote renders with a rule down its left.'),
      metadata: {'blockType': 'blockquote'},
    ),
    TextNode(
      id: 'list1',
      text: AttributedText('First bullet'),
      metadata: {'blockType': 'listItemUnordered'},
    ),
    TextNode(
      id: 'list2',
      text: AttributedText('Second bullet, indented'),
      metadata: {'blockType': 'listItemUnordered', 'indent': 1},
    ),
    TextNode(
      id: 'ol1',
      text: AttributedText('Numbered one'),
      metadata: {'blockType': 'listItemOrdered'},
    ),
    TextNode(
      id: 'ol2',
      text: AttributedText('Numbered two'),
      metadata: {'blockType': 'listItemOrdered'},
    ),
    TextNode(
      id: 'code',
      text: AttributedText('final editor = QuireEditor();'),
      metadata: {'blockType': 'code'},
    ),
    HorizontalRuleNode(id: 'hr'),
    TextNode(
      id: 'h3',
      text: AttributedText('Tables'),
      metadata: {'blockType': 'header2'},
    ),
    TableNode(
      id: 'table1',
      rows: [
        TableRow(
          cells: [
            TableCell(
              nodes: [
                TextNode(id: 't1_r0c0', text: AttributedText('Merged header')),
              ],
              colSpan: 2,
            ),
          ],
        ),
        TableRow(
          cells: [
            TableCell(
              nodes: [TextNode(id: 't1_r1c0', text: AttributedText('A1'))],
            ),
            TableCell(
              nodes: [TextNode(id: 't1_r1c1', text: AttributedText('B1'))],
            ),
          ],
        ),
      ],
    ),
    TableNode(
      id: 'wide',
      rows: [
        for (var r = 0; r < 2; r++)
          TableRow(
            cells: [
              for (var c = 0; c < 6; c++)
                TableCell(
                  nodes: [
                    TextNode(
                      id: 'w_${r}_$c',
                      text: AttributedText('R${r + 1}C${c + 1}'),
                    ),
                  ],
                ),
            ],
          ),
      ],
    ),
    TextNode(
      id: 'p3',
      text: AttributedText('Tap in and start typing.'),
      metadata: {'blockType': 'paragraph'},
    ),
  ],
);

class QuireExampleApp extends StatefulWidget {
  const QuireExampleApp({super.key});

  @override
  State<QuireExampleApp> createState() => _QuireExampleAppState();
}

class _QuireExampleAppState extends State<QuireExampleApp> {
  late final QuireEditorController _controller = QuireEditorController(
    document: _seedDocument(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Quire example',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    home: Scaffold(
      appBar: AppBar(
        title: const Text('Quire'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: QuireToolbar(controller: _controller),
        ),
      ),
      body: QuireEditor(controller: _controller),
    ),
  );
}
