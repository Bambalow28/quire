import 'package:flutter/material.dart';
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
