import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

TextNode _n(String id, String text, [Map<String, Object?> meta = const {}]) =>
    TextNode(id: id, text: AttributedText(text), metadata: {...meta});

QuireEditorController _controller(List<TextNode> nodes) =>
    QuireEditorController(document: MutableDocument(nodes: nodes));

void _caret(QuireEditorController c, String id, int offset) =>
    c.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition(id, TextNodePosition(offset)),
      ),
    );

List<TextNode> _nodes(QuireEditorController c) =>
    c.document.nodesInDocumentOrder.cast<TextNode>().toList();

void main() {
  test('Tab on a numbered item under another item nests it as a bullet', () {
    final c = _controller([
      _n('a', 'one', {'blockType': 'listItemOrdered'}),
      _n('b', 'two', {'blockType': 'listItemOrdered'}),
    ]);
    _caret(c, 'b', 1);
    c.indentWithTab();
    final b = _nodes(c)[1];
    expect(b.blockType, 'listItemUnordered');
    expect(b.indent, 1);
    c.indentWithTab(outdent: true);
    expect(_nodes(c)[1].indent, 0);
  });

  test('Tab on the first numbered item only indents it', () {
    final c = _controller([
      _n('a', 'one', {'blockType': 'listItemOrdered'}),
    ]);
    _caret(c, 'a', 0);
    c.indentWithTab();
    expect(_nodes(c)[0].blockType, 'listItemOrdered');
    expect(_nodes(c)[0].indent, 1);
  });

  test('Tab on a paragraph indents it', () {
    final c = _controller([_n('a', 'text')]);
    _caret(c, 'a', 2);
    c.indentWithTab();
    expect(_nodes(c)[0].indent, 1);
    expect(_nodes(c)[0].text.text, 'text');
  });

  test('Tab indents every selected block', () {
    final c = _controller([_n('a', 'x'), _n('b', 'y'), _n('c', 'z')]);
    c.changeSelection(
      DocumentSelection(
        base: DocumentPosition('a', const TextNodePosition(0)),
        extent: DocumentPosition('b', const TextNodePosition(1)),
      ),
    );
    c.indentWithTab();
    expect(_nodes(c).map((n) => n.indent), [1, 1, 0]);
  });

  test('Tab on a callout title carries its content along', () {
    final c = _controller([
      _n('t', 'Title', {'blockType': 'callout'}),
      _n('k', 'kid', {'indent': 1}),
    ]);
    _caret(c, 't', 0);
    c.indentWithTab();
    expect(_nodes(c).map((n) => n.indent), [1, 2]);
  });

  test('Tab in a code block types two spaces', () {
    final c = _controller([
      _n('a', 'x', {'blockType': 'code'}),
    ]);
    _caret(c, 'a', 1);
    c.indentWithTab();
    expect(_nodes(c)[0].text.text, 'x  ');
    expect(_nodes(c)[0].indent, 0);
  });

  testWidgets('a bullet under a number is pushed in; a plain bullet is not', (
    tester,
  ) async {
    final c = _controller([
      _n('a', 'one', {'blockType': 'listItemOrdered'}),
      _n('b', 'two', {'blockType': 'listItemUnordered', 'indent': 1}),
      _n('c', 'plain', {'blockType': 'listItemUnordered'}),
      _n('d', 'nested', {'blockType': 'listItemUnordered', 'indent': 1}),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireEditor(controller: c)),
      ),
    );
    double x(String t) =>
        tester.getTopLeft(find.text(t, findRichText: true)).dx;
    // Same 24px of indent each, but only the one under a number gets the
    // wider gutter.
    expect(x('two'), greaterThan(x('nested')));
    expect(x('nested') - x('plain'), 24);
  });

  group('Backspace peels one layer at a time', () {
    test('an emptied nested bullet loses its marker, then its indent', () {
      final c = _controller([
        _n('a', 'one', {'blockType': 'listItemOrdered'}),
        _n('b', '', {'blockType': 'listItemUnordered', 'indent': 1}),
      ]);
      _caret(c, 'b', 0);
      c.backspaceAtCaret();
      expect(_nodes(c)[1].blockType, 'paragraph');
      expect(_nodes(c)[1].indent, 1);
      c.backspaceAtCaret();
      expect(_nodes(c)[1].indent, 0);
      expect(_nodes(c).length, 2);
      c.backspaceAtCaret();
      expect(_nodes(c).length, 1);
    });

    test(
      'backspace before the word of an indented line removes the indent',
      () {
        final c = _controller([
          _n('a', 'one'),
          _n('b', 'word', {'indent': 2}),
        ]);
        _caret(c, 'b', 0);
        c.backspaceAtCaret();
        expect(_nodes(c)[1].indent, 1);
        expect(_nodes(c)[1].text.text, 'word');
      },
    );

    test('a non-empty nested bullet outdents but stays a bullet', () {
      final c = _controller([
        _n('a', 'one', {'blockType': 'listItemUnordered'}),
        _n('b', 'two', {'blockType': 'listItemUnordered', 'indent': 1}),
      ]);
      _caret(c, 'b', 0);
      c.backspaceAtCaret();
      expect(_nodes(c)[1].blockType, 'listItemUnordered');
      expect(_nodes(c)[1].indent, 0);
    });

    test('backspace after a character still just deletes it', () {
      final c = _controller([
        _n('a', 'one'),
        _n('b', 'word', {'indent': 1}),
      ]);
      _caret(c, 'b', 4);
      c.backspaceAtCaret();
      expect(_nodes(c)[1].text.text, 'wor');
      expect(_nodes(c)[1].indent, 1);
    });
  });
}
