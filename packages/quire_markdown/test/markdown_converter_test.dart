import 'package:quire_core/quire_core.dart';
import 'package:quire_markdown/quire_markdown.dart';
import 'package:test/test.dart';

TextNode textNodeAt(MutableDocument doc, int index) =>
    doc.nodes[index] as TextNode;

void main() {
  tableTests();
  group('headings', () {
    test('levels 1-6', () {
      for (var n = 1; n <= 6; n++) {
        final doc = markdownToQuire('${'#' * n} Heading $n');
        expect(textNodeAt(doc, 0).blockType, 'header$n');
        expect(textNodeAt(doc, 0).text.text, 'Heading $n');
      }
    });
  });

  group('paragraphs', () {
    test('plain line', () {
      final doc = markdownToQuire('Hello world');
      expect(doc.nodes, hasLength(1));
      expect(textNodeAt(doc, 0).text.text, 'Hello world');
      expect(textNodeAt(doc, 0).blockType, 'paragraph');
    });

    test('blank lines separate paragraphs, do not create empty nodes', () {
      final doc = markdownToQuire('first\n\nsecond\n\n\nthird');
      expect(doc.nodes, hasLength(3));
      expect(textNodeAt(doc, 0).text.text, 'first');
      expect(textNodeAt(doc, 1).text.text, 'second');
      expect(textNodeAt(doc, 2).text.text, 'third');
    });
  });

  group('inline styles', () {
    test('bold', () {
      final doc = markdownToQuire('a **bold** word');
      final text = textNodeAt(doc, 0).text;
      expect(text.text, 'a bold word');
      expect(text.attributionsAt(2), contains(const Attribution('bold')));
      expect(text.attributionsAt(0), isEmpty);
    });

    test('italic with asterisk and underscore', () {
      final star = markdownToQuire('*it*').nodes[0] as TextNode;
      expect(
        star.text.attributionsAt(0),
        contains(const Attribution('italic')),
      );
      final underscore = markdownToQuire('_it_').nodes[0] as TextNode;
      expect(
        underscore.text.attributionsAt(0),
        contains(const Attribution('italic')),
      );
    });

    test('bold+italic combo', () {
      final doc = markdownToQuire('***both***');
      final text = textNodeAt(doc, 0).text;
      expect(text.text, 'both');
      expect(text.attributionsAt(0), contains(const Attribution('bold')));
      expect(text.attributionsAt(0), contains(const Attribution('italic')));
    });

    test('inline code', () {
      final doc = markdownToQuire('use `code` here');
      final text = textNodeAt(doc, 0).text;
      expect(text.text, 'use code here');
      expect(text.attributionsAt(4), contains(const Attribution('code')));
    });

    test('strikethrough', () {
      final doc = markdownToQuire('~~gone~~');
      final text = textNodeAt(doc, 0).text;
      expect(text.text, 'gone');
      expect(
        text.attributionsAt(0),
        contains(const Attribution('strikethrough')),
      );
    });

    test('link', () {
      final doc = markdownToQuire('[example](https://example.com)');
      final text = textNodeAt(doc, 0).text;
      expect(text.text, 'example');
      expect(
        text.attributionsAt(0),
        contains(Attribution('link', value: {'url': 'https://example.com'})),
      );
    });

    test('bold inside a link', () {
      final doc = markdownToQuire('[**bold link**](https://example.com)');
      final text = textNodeAt(doc, 0).text;
      expect(text.text, 'bold link');
      final attrs = text.attributionsAt(0);
      expect(attrs, contains(const Attribution('bold')));
      expect(
        attrs,
        contains(Attribution('link', value: {'url': 'https://example.com'})),
      );
    });

    test('unterminated marker is kept as literal text, never throws', () {
      expect(() => markdownToQuire('a *dangling bold'), returnsNormally);
      final doc = markdownToQuire('a *dangling bold');
      expect(textNodeAt(doc, 0).text.text, 'a *dangling bold');
    });

    test('intraword underscore is not treated as emphasis', () {
      final doc = markdownToQuire('foo_bar_baz');
      final text = textNodeAt(doc, 0).text;
      expect(text.text, 'foo_bar_baz');
      expect(text.attributionsAt(4), isEmpty);
    });

    test('space-flanked underscore still italicizes', () {
      final doc = markdownToQuire('text _emphasis_ text');
      final text = textNodeAt(doc, 0).text;
      expect(text.text, 'text emphasis text');
      expect(text.attributionsAt(5), contains(const Attribution('italic')));
    });

    test('link text with one level of nested brackets', () {
      final doc = markdownToQuire('[a [b] c](url)');
      final text = textNodeAt(doc, 0).text;
      expect(text.text, 'a [b] c');
      expect(
        text.attributionsAt(0),
        contains(Attribution('link', value: {'url': 'url'})),
      );
    });
  });

  group('lists', () {
    test('bullet list with - and *', () {
      final dash = markdownToQuire('- one').nodes[0] as TextNode;
      expect(dash.blockType, 'listItemUnordered');
      expect(dash.text.text, 'one');
      final star = markdownToQuire('* two').nodes[0] as TextNode;
      expect(star.blockType, 'listItemUnordered');
    });

    test('ordered list', () {
      final doc = markdownToQuire('1. first\n2. second');
      expect(textNodeAt(doc, 0).blockType, 'listItemOrdered');
      expect(textNodeAt(doc, 0).text.text, 'first');
      expect(textNodeAt(doc, 1).text.text, 'second');
    });

    test('task list checked and unchecked', () {
      final checked = markdownToQuire('- [x] done').nodes[0] as TextNode;
      expect(checked.blockType, 'listItemTask');
      expect(checked.isChecked, isTrue);
      expect(checked.text.text, 'done');

      final unchecked = markdownToQuire('- [ ] todo').nodes[0] as TextNode;
      expect(unchecked.blockType, 'listItemTask');
      expect(unchecked.isChecked, isFalse);
    });

    test('indented list item sets indent metadata', () {
      final doc = markdownToQuire('  - nested');
      expect(textNodeAt(doc, 0).indent, 1);
    });
  });

  group('blockquote and code block', () {
    test('blockquote line', () {
      final doc = markdownToQuire('> quoted text');
      expect(textNodeAt(doc, 0).blockType, 'blockquote');
      expect(textNodeAt(doc, 0).text.text, 'quoted text');
    });

    test('fenced code block, content not inline-parsed', () {
      final doc = markdownToQuire('```\nlet x = *not italic*;\n```');
      expect(doc.nodes, hasLength(1));
      expect(textNodeAt(doc, 0).blockType, 'code');
      expect(textNodeAt(doc, 0).text.text, 'let x = *not italic*;');
      expect(textNodeAt(doc, 0).text.spans, isEmpty);
    });

    test('fenced code block with language tag', () {
      final doc = markdownToQuire('```dart\nvoid main() {}\n```');
      expect(textNodeAt(doc, 0).blockType, 'code');
      expect(textNodeAt(doc, 0).text.text, 'void main() {}');
    });
  });

  group('horizontal rule', () {
    test('--- becomes a HorizontalRuleNode', () {
      final doc = markdownToQuire('above\n---\nbelow');
      expect(doc.nodes, hasLength(3));
      expect(doc.nodes[1], isA<HorizontalRuleNode>());
    });
  });

  group('image export', () {
    test('ImageNode renders as markdown image syntax', () {
      final doc = MutableDocument(
        nodes: [
          ImageNode(
            id: 'a',
            url: 'https://example.com/pic.png',
            altText: 'a photo',
          ),
        ],
      );
      final markdown = quireToMarkdown(doc);
      expect(markdown, '![a photo](https://example.com/pic.png)');
    });

    test('ImageNode without alt text renders empty alt', () {
      final doc = MutableDocument(
        nodes: [ImageNode(id: 'a', url: 'https://example.com/pic.png')],
      );
      final markdown = quireToMarkdown(doc);
      expect(markdown, '![](https://example.com/pic.png)');
    });
  });

  group('robustness', () {
    test('empty markdown produces one empty paragraph', () {
      final doc = markdownToQuire('');
      expect(doc.nodes, hasLength(1));
      expect(textNodeAt(doc, 0).text.text, '');
      expect(textNodeAt(doc, 0).blockType, 'paragraph');
    });

    test('markdownToQuireOrNull never throws', () {
      expect(markdownToQuireOrNull('# ok'), isNotNull);
    });
  });

  group('round trip: Quire -> Markdown -> Quire', () {
    MutableDocument roundTrip(MutableDocument doc) =>
        markdownToQuire(quireToMarkdown(doc));

    test('headings', () {
      final doc = MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('Title'),
            metadata: {'blockType': 'header2'},
          ),
        ],
      );
      final result = roundTrip(doc);
      expect(textNodeAt(result, 0).blockType, 'header2');
      expect(textNodeAt(result, 0).text.text, 'Title');
    });

    test('bold and italic', () {
      final doc = MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('bold and italic', [
              const AttributionSpan(Attribution('bold'), 0, 4),
              const AttributionSpan(Attribution('italic'), 9, 15),
            ]),
          ),
        ],
      );
      final result = roundTrip(doc);
      final text = textNodeAt(result, 0).text;
      expect(text.text, 'bold and italic');
      expect(text.attributionsAt(0), contains(const Attribution('bold')));
      expect(text.attributionsAt(9), contains(const Attribution('italic')));
    });

    test('bullet and ordered lists', () {
      final doc = MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('bullet'),
            metadata: {'blockType': 'listItemUnordered'},
          ),
          TextNode(
            id: 'b',
            text: AttributedText('ordered'),
            metadata: {'blockType': 'listItemOrdered'},
          ),
        ],
      );
      final result = roundTrip(doc);
      expect(textNodeAt(result, 0).blockType, 'listItemUnordered');
      expect(textNodeAt(result, 0).text.text, 'bullet');
      expect(textNodeAt(result, 1).blockType, 'listItemOrdered');
      expect(textNodeAt(result, 1).text.text, 'ordered');
    });

    test('blockquote', () {
      final doc = MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('quoted'),
            metadata: {'blockType': 'blockquote'},
          ),
        ],
      );
      final result = roundTrip(doc);
      expect(textNodeAt(result, 0).blockType, 'blockquote');
      expect(textNodeAt(result, 0).text.text, 'quoted');
    });

    test('code block', () {
      final doc = MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('a = 1;'),
            metadata: {'blockType': 'code'},
          ),
        ],
      );
      final result = roundTrip(doc);
      expect(textNodeAt(result, 0).blockType, 'code');
      expect(textNodeAt(result, 0).text.text, 'a = 1;');
    });

    test('link', () {
      final doc = MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('click here', [
              AttributionSpan(
                Attribution('link', value: {'url': 'https://example.com'}),
                0,
                10,
              ),
            ]),
          ),
        ],
      );
      final result = roundTrip(doc);
      final text = textNodeAt(result, 0).text;
      expect(text.text, 'click here');
      expect(
        text.attributionsAt(0),
        contains(Attribution('link', value: {'url': 'https://example.com'})),
      );
    });

    test('horizontal rule', () {
      final doc = MutableDocument(
        nodes: [
          TextNode(id: 'a', text: AttributedText('above')),
          HorizontalRuleNode(id: 'b'),
          TextNode(id: 'c', text: AttributedText('below')),
        ],
      );
      final result = roundTrip(doc);
      expect(result.nodes, hasLength(3));
      expect(result.nodes[1], isA<HorizontalRuleNode>());
      expect(textNodeAt(result, 0).text.text, 'above');
      expect(textNodeAt(result, 2).text.text, 'below');
    });
  });
}

void tableTests() {
  group('GFM tables', () {
    const md =
        '| Name | Qty |\n| --- | ---: |\n| Apple | 3 |\n| **Pear** | 5 |';

    test('import builds a TableNode', () {
      final table = markdownToQuire(md).nodes.single as TableNode;
      expect(table.gridSize, (3, 2));
      final cell = table.cellAt(2, 0)!.nodes.single as TextNode;
      expect(cell.text.text, 'Pear');
      expect(cell.text.spans, isNotEmpty);
    });

    test('export writes the same table back', () {
      expect(quireToMarkdown(markdownToQuire(md)), contains('| Apple | 3 |'));
      expect(
        quireToMarkdown(markdownToQuire(quireToMarkdown(markdownToQuire(md)))),
        quireToMarkdown(markdownToQuire(md)),
      );
    });

    test('escaped pipes stay in the cell', () {
      final table =
          markdownToQuire('| a |\n| --- |\n| x \\| y |').nodes.single
              as TableNode;
      expect((table.cellAt(1, 0)!.nodes.single as TextNode).text.text, 'x | y');
    });

    test('ragged rows are padded to the header width', () {
      final table =
          markdownToQuire('| a | b |\n| - | - |\n| only |').nodes.single
              as TableNode;
      expect(table.gridSize, (2, 2));
    });

    test('a pipe line without a delimiter row is a paragraph', () {
      final doc = markdownToQuire('a | b\nplain');
      expect(doc.nodes.whereType<TableNode>(), isEmpty);
    });

    test('a multi-paragraph cell round-trips through <br>', () {
      final table =
          markdownToQuire('| a |\n| - |\n| one<br>two |').nodes.single
              as TableNode;
      expect(table.cellAt(1, 0)!.nodes, hasLength(2));
      expect(
        quireToMarkdown(MutableDocument(nodes: [table])),
        contains('one<br>two'),
      );
    });

    test('merged cells export flat', () {
      final table = TableNode(
        id: 't',
        rows: [
          TableRow(
            cells: [
              TableCell(
                nodes: [TextNode(id: 'x', text: AttributedText('wide'))],
                colSpan: 2,
              ),
            ],
          ),
        ],
      );
      expect(
        quireToMarkdown(MutableDocument(nodes: [table])).split('\n').first,
        '| wide |  |',
      );
    });
  });

  group('code language and note links', () {
    test('a fence language round-trips', () {
      final doc = markdownToQuire('```dart\nvar x = 1;\n```');
      final node = textNodeAt(doc, 0);
      expect(node.blockType, 'code');
      expect(node.metadata['language'], 'dart');
      expect(quireToMarkdown(doc), '```dart\nvar x = 1;\n```');
    });

    test('a bare fence has no language', () {
      final node = textNodeAt(markdownToQuire('```\nx\n```'), 0);
      expect(node.metadata.containsKey('language'), isFalse);
    });

    test('a note link round-trips as a quire-note link', () {
      final doc = markdownToQuire('see [Groceries](quire-note:n1) now');
      final spans = textNodeAt(doc, 0).text.spans;
      expect(spans.single.attribution.name, 'noteLink');
      expect(spans.single.attribution.value['id'], 'n1');
      expect(quireToMarkdown(doc), 'see [Groceries](quire-note:n1) now');
    });
  });
}
