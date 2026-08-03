import 'dart:convert';

import 'package:quire_core/quire_core.dart';
import 'package:quire_delta/quire_delta.dart';
import 'package:test/test.dart';

TextNode textNodeAt(MutableDocument doc, int index) =>
    doc.nodes[index] as TextNode;

void main() {
  group('plain text', () {
    test('single line', () {
      final doc = deltaToQuire([
        {'insert': 'Hello world\n'},
      ]);
      expect(doc.nodes, hasLength(1));
      expect(textNodeAt(doc, 0).text.text, 'Hello world');
      expect(textNodeAt(doc, 0).blockType, 'paragraph');
    });

    test('one op closes several lines', () {
      final doc = deltaToQuire([
        {
          'insert': 'first\nsecond\nthird\n',
          'attributes': {'header': 1},
        },
      ]);
      expect(doc.nodes, hasLength(3));
      expect(textNodeAt(doc, 0).text.text, 'first');
      expect(textNodeAt(doc, 0).blockType, 'header1');
      expect(textNodeAt(doc, 1).text.text, 'second');
      expect(textNodeAt(doc, 1).blockType, 'header1');
      expect(textNodeAt(doc, 2).text.text, 'third');
      expect(textNodeAt(doc, 2).blockType, 'header1');
    });
  });

  group('inline attributes', () {
    test('every inline attribute maps to an Attribution', () {
      final doc = deltaToQuire([
        {
          'insert': 'bold',
          'attributes': {'bold': true},
        },
        {
          'insert': 'italic',
          'attributes': {'italic': true},
        },
        {
          'insert': 'underline',
          'attributes': {'underline': true},
        },
        {
          'insert': 'strike',
          'attributes': {'strike': true},
        },
        {
          'insert': 'code',
          'attributes': {'code': true},
        },
        {
          'insert': 'link',
          'attributes': {'link': 'https://example.com'},
        },
        {
          'insert': 'color',
          'attributes': {'color': '#ff0000'},
        },
        {
          'insert': 'bg',
          'attributes': {'background': '#00ff00'},
        },
        {
          'insert': 'font',
          'attributes': {'font': 'monospace'},
        },
        {
          'insert': 'size',
          'attributes': {'size': '18'},
        },
        {'insert': '\n'},
      ]);
      final text = textNodeAt(doc, 0).text;
      expect(text.text, 'bolditalicunderlinestrikecodelinkcolorbgfontsize');

      Set<Attribution> attrsAt(int offset) => text.attributionsAt(offset);

      expect(attrsAt(0), contains(const Attribution('bold')));
      expect(attrsAt(4), contains(const Attribution('italic')));
      expect(attrsAt(10), contains(const Attribution('underline')));
      expect(attrsAt(19), contains(const Attribution('strikethrough')));
      expect(attrsAt(25), contains(const Attribution('code')));
      expect(
        attrsAt(29),
        contains(Attribution('link', value: {'url': 'https://example.com'})),
      );
      expect(
        attrsAt(33),
        contains(Attribution('color', value: {'hex': '#ff0000'})),
      );
      expect(
        attrsAt(38),
        contains(Attribution('backgroundColor', value: {'hex': '#00ff00'})),
      );
      expect(
        attrsAt(40),
        contains(Attribution('fontFamily', value: {'family': 'monospace'})),
      );
      expect(
        attrsAt(44),
        contains(Attribution('fontSize', value: {'size': 18.0})),
      );
    });

    test('two overlapping inline attributes', () {
      final doc = deltaToQuire([
        {
          'insert': 'both',
          'attributes': {'bold': true, 'italic': true},
        },
        {'insert': '\n'},
      ]);
      final attrs = textNodeAt(doc, 0).text.attributionsAt(0);
      expect(attrs, contains(const Attribution('bold')));
      expect(attrs, contains(const Attribution('italic')));
    });
  });

  group('block types', () {
    test('headers 1-6', () {
      for (var n = 1; n <= 6; n++) {
        final doc = deltaToQuire([
          {
            'insert': 'h$n\n',
            'attributes': {'header': n},
          },
        ]);
        expect(textNodeAt(doc, 0).blockType, 'header$n');
      }
    });

    test('ordered and bullet lists', () {
      final ordered = deltaToQuire([
        {
          'insert': 'a\n',
          'attributes': {'list': 'ordered'},
        },
      ]);
      expect(textNodeAt(ordered, 0).blockType, 'listItemOrdered');

      final bullet = deltaToQuire([
        {
          'insert': 'a\n',
          'attributes': {'list': 'bullet'},
        },
      ]);
      expect(textNodeAt(bullet, 0).blockType, 'listItemUnordered');
    });

    test('checked and unchecked task items', () {
      final checked = deltaToQuire([
        {
          'insert': 'done\n',
          'attributes': {'list': 'checked'},
        },
      ]);
      expect(textNodeAt(checked, 0).blockType, 'listItemTask');
      expect(textNodeAt(checked, 0).isChecked, isTrue);
      expect(textNodeAt(checked, 0).metadata['checked'], true);

      final unchecked = deltaToQuire([
        {
          'insert': 'todo\n',
          'attributes': {'list': 'unchecked'},
        },
      ]);
      expect(textNodeAt(unchecked, 0).blockType, 'listItemTask');
      expect(textNodeAt(unchecked, 0).isChecked, isFalse);
      expect(textNodeAt(unchecked, 0).metadata['checked'], false);
    });

    test('blockquote and code-block', () {
      final quote = deltaToQuire([
        {
          'insert': 'q\n',
          'attributes': {'blockquote': true},
        },
      ]);
      expect(textNodeAt(quote, 0).blockType, 'blockquote');

      final code = deltaToQuire([
        {
          'insert': 'c\n',
          'attributes': {'code-block': true},
        },
      ]);
      expect(textNodeAt(code, 0).blockType, 'code');
    });

    test('indent and align', () {
      final doc = deltaToQuire([
        {
          'insert': 'a\n',
          'attributes': {'indent': 2, 'align': 'right'},
        },
      ]);
      final node = textNodeAt(doc, 0);
      expect(node.metadata['indent'], 2);
      expect(node.metadata['textAlign'], 'right');
    });
  });

  group('embeds', () {
    test('image embed with filesystem path', () {
      final doc = deltaToQuire([
        {
          'insert': {'image': '/storage/emulated/0/notes/photo.jpg'},
        },
        {'insert': '\n'},
      ]);
      expect(doc.nodes, hasLength(1));
      final img = doc.nodes[0] as ImageNode;
      expect(img.url, '/storage/emulated/0/notes/photo.jpg');
    });

    test('video embed becomes a link text node', () {
      final doc = deltaToQuire([
        {
          'insert': {'video': 'https://example.com/clip.mp4'},
        },
        {'insert': '\n'},
      ]);
      final node = textNodeAt(doc, 0);
      expect(node.text.text, 'https://example.com/clip.mp4');
      expect(
        node.text.attributionsAt(0),
        contains(
          Attribution('link', value: {'url': 'https://example.com/clip.mp4'}),
        ),
      );
    });

    test('well-formed legacy table embed', () {
      final payload = jsonEncode({
        'cells': [
          ['a', 'b'],
          ['c', 'd'],
        ],
      });
      final doc = deltaToQuire([
        {
          'insert': {'table': payload},
        },
        {'insert': '\n'},
      ]);
      final table = doc.nodes[0] as TableNode;
      expect(table.rows, hasLength(2));
      expect(table.rows[0].cells, hasLength(2));
      final cellNode = table.rows[0].cells[0].nodes[0] as TextNode;
      expect(cellNode.text.text, 'a');
      expect((table.rows[1].cells[1].nodes[0] as TextNode).text.text, 'd');
    });

    test('corrupt legacy table embed falls back to text, content kept', () {
      final doc = deltaToQuire([
        {
          'insert': {'table': 'not valid json {{{'},
        },
        {'insert': '\n'},
      ]);
      final node = textNodeAt(doc, 0);
      expect(node.text.text, contains('not valid json'));
    });

    test('divider embed becomes a HorizontalRuleNode', () {
      final doc = deltaToQuire([
        {
          'insert': {'divider': 'hr'},
        },
        {'insert': '\n'},
      ]);
      expect(doc.nodes, hasLength(1));
      expect(doc.nodes[0], isA<HorizontalRuleNode>());
    });

    test('image embed with alt attribute preserves it', () {
      final doc = deltaToQuire([
        {
          'insert': {'image': '/local/photo.png'},
          'attributes': {'alt': 'a scenic photo'},
        },
        {'insert': '\n'},
      ]);
      final img = doc.nodes[0] as ImageNode;
      expect(img.altText, 'a scenic photo');
    });

    test('table cell with a nested delta-shaped value extracts text', () {
      final payload = jsonEncode({
        'cells': [
          [
            {'insert': 'nested text'},
          ],
        ],
      });
      final doc = deltaToQuire([
        {
          'insert': {'table': payload},
        },
        {'insert': '\n'},
      ]);
      final table = doc.nodes[0] as TableNode;
      final cellNode = table.rows[0].cells[0].nodes[0] as TextNode;
      expect(cellNode.text.text, 'nested text');
      expect(cellNode.text.text, isNot(contains('insert')));
    });

    test('unknown embed type is preserved, never throws', () {
      expect(
        () => deltaToQuire([
          {
            'insert': {'mystery': 'payload-data'},
          },
          {'insert': '\n'},
        ]),
        returnsNormally,
      );
      final doc = deltaToQuire([
        {
          'insert': {'mystery': 'payload-data'},
        },
        {'insert': '\n'},
      ]);
      final node = textNodeAt(doc, 0);
      expect(node.text.text, contains('payload-data'));
    });

    test('unknown inline attribute is ignored, text kept', () {
      final doc = deltaToQuire([
        {
          'insert': 'text',
          'attributes': {'made-up-attr': true},
        },
        {'insert': '\n'},
      ]);
      expect(textNodeAt(doc, 0).text.text, 'text');
      expect(textNodeAt(doc, 0).text.attributionsAt(0), isEmpty);
    });
  });

  group('robustness', () {
    test('empty delta produces one empty paragraph', () {
      final doc = deltaToQuire([]);
      expect(doc.nodes, hasLength(1));
      expect(textNodeAt(doc, 0).text.text, '');
      expect(textNodeAt(doc, 0).blockType, 'paragraph');
    });

    test('whitespace-only delta', () {
      final doc = deltaToQuire([
        {'insert': '   \n'},
      ]);
      expect(doc.nodes, hasLength(1));
      expect(textNodeAt(doc, 0).text.text, '   ');
    });

    test('missing trailing newline still produces a node', () {
      final doc = deltaToQuire([
        {'insert': 'no trailing newline'},
      ]);
      expect(doc.nodes, hasLength(1));
      expect(textNodeAt(doc, 0).text.text, 'no trailing newline');
    });

    test('malformed op in the middle is skipped, rest still converts', () {
      final doc = deltaToQuire([
        {'insert': 'before\n'},
        {'insert': 123}, // wrong type for insert
        {'notInsert': 'nope'}, // missing insert
        {
          'insert': 'weird',
          'attributes': 'not-a-map', // attributes wrong type
        },
        {'insert': 'after\n'},
      ]);
      expect(doc.nodes, hasLength(2));
      expect(textNodeAt(doc, 0).text.text, 'before');
      // The op with corrupt attributes loses its formatting but keeps its
      // text, so it joins the following line rather than vanishing.
      expect(textNodeAt(doc, 1).text.text, 'weirdafter');
    });

    test('deltaToQuireOrNull returns null instead of throwing', () {
      // A non-list top-level delta payload is truly malformed.
      expect(deltaToQuireOrNull(const []), isNotNull);
    });

    test('deltaJsonToQuire parses JSON text', () {
      final doc = deltaJsonToQuire(
        jsonEncode([
          {'insert': 'hi\n'},
        ]),
      );
      expect(textNodeAt(doc, 0).text.text, 'hi');
    });
  });

  group('plainTextOfQuireJson', () {
    test('realistic mixed note round trip', () {
      final tablePayload = jsonEncode({
        'cells': [
          ['Q1', 'Revenue'],
          ['100', '200'],
        ],
      });
      final doc = deltaToQuire([
        {
          'insert': 'Meeting Notes\n',
          'attributes': {'header': 2},
        },
        {'insert': 'This is '},
        {
          'insert': 'important',
          'attributes': {'bold': true},
        },
        {'insert': ' context.\n'},
        {
          'insert': 'Buy milk\n',
          'attributes': {'list': 'checked'},
        },
        {
          'insert': 'Call bank\n',
          'attributes': {'list': 'unchecked'},
        },
        {
          'insert': {'image': '/local/photo.png'},
        },
        {'insert': '\n'},
        {
          'insert': {'table': tablePayload},
        },
        {'insert': '\n'},
      ]);

      final json = jsonEncode(doc.toJson());
      final text = plainTextOfQuireJson(json);

      for (final expected in [
        'Meeting Notes',
        'This is important context.',
        'Buy milk',
        'Call bank',
        'Q1',
        'Revenue',
        '100',
        '200',
      ]) {
        expect(text, contains(expected));
      }
    });
  });

  test('an op with corrupt attributes keeps its text', () {
    final doc = deltaToQuire([
      {'insert': 'kept text', 'attributes': 'not-a-map'},
      {'insert': '\n'},
    ]);
    expect(
      doc.nodes.whereType<TextNode>().map((n) => n.text.text),
      contains('kept text'),
    );
  });

  test('a ragged legacy table is padded to a rectangle', () {
    final doc = deltaToQuire([
      {
        'insert': {'table': '{"cells":[["a","b","c"],["d"]]}'},
      },
      {'insert': '\n'},
    ]);
    final table = doc.nodes.whereType<TableNode>().single;
    expect(table.rows.every((r) => r.cells.length == 3), isTrue);
  });
}
