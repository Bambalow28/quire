import 'dart:convert';
import 'dart:math';

import 'package:quire_core/quire_core.dart';
import 'package:test/test.dart';

Map<String, Object?> _text(String id, String text) => {
  'type': 'text',
  'id': id,
  'text': {'text': text, 'spans': []},
  'metadata': {},
};

void main() {
  test('sound JSON loads with no repairs', () {
    final result = loadDocument({
      'version': 1,
      'nodes': [_text('a', 'hi')],
    });
    expect(result.repairs, isEmpty);
    expect(result.fromNewerVersion, isFalse);
    expect(validateDocument(result.document), isEmpty);
  });

  test('a document with no version (pre-versioning) still loads', () {
    final result = loadDocument({
      'nodes': [_text('a', 'hi')],
    });
    expect(result.repairs, isEmpty);
  });

  test('toJson stamps the schema version', () {
    expect(MutableDocument().toJson()['version'], documentSchemaVersion);
  });

  test('a newer schema version is flagged for read-only handling', () {
    final result = loadDocument({
      'version': documentSchemaVersion + 1,
      'nodes': [_text('a', 'hi')],
    });
    expect(result.fromNewerVersion, isTrue);
  });

  test('an unknown node type round-trips unchanged', () {
    final unknown = {
      'type': 'mermaid',
      'id': 'm1',
      'source': 'graph TD',
      'x': 1,
    };
    final result = loadDocument({
      'nodes': [_text('a', 'hi'), unknown],
    });
    expect(result.document.getNodeById('m1'), isA<UnknownNode>());
    expect(
      jsonEncode(result.document.toJson()['nodes']),
      jsonEncode([_text('a', 'hi'), unknown]),
    );
  });

  test('a malformed known node is kept raw instead of failing the load', () {
    final broken = {'type': 'table', 'id': 't1', 'rows': 'nope'};
    final result = loadDocument({
      'nodes': [_text('a', 'hi'), broken],
    });
    expect(result.document.nodes.length, 2);
    expect(
      jsonEncode(result.document.toJson()['nodes']),
      contains(jsonEncode(broken)),
    );
    expect(result.repairs, isNotEmpty);
  });

  test('duplicate ids are reissued', () {
    final result = loadDocument({
      'nodes': [_text('a', 'one'), _text('a', 'two')],
    });
    expect(validateDocument(result.document), isEmpty);
    expect(result.document.nodes.map((n) => n.id).toSet().length, 2);
  });

  test('spans outside the text are clamped or dropped', () {
    final result = loadDocument({
      'nodes': [
        {
          'type': 'text',
          'id': 'a',
          'text': {
            'text': 'abc',
            'spans': [
              {
                'attribution': {'name': 'bold', 'value': {}},
                'start': -5,
                'end': 99,
              },
              {
                'attribution': {'name': 'italic', 'value': {}},
                'start': 7,
                'end': 9,
              },
            ],
          },
        },
      ],
    });
    expect(validateDocument(result.document), isEmpty);
    final node = result.document.getNodeById('a') as TextNode;
    expect(node.text.spans.single.start, 0);
    expect(node.text.spans.single.end, 3);
  });

  test('empty table cells and empty documents are given a paragraph', () {
    final result = loadDocument({
      'nodes': [
        {
          'type': 'table',
          'id': 't',
          'rows': [
            {
              'cells': [
                {'nodes': [], 'rowSpan': 0, 'colSpan': 1},
              ],
            },
          ],
        },
      ],
    });
    expect(validateDocument(result.document), isEmpty);
    expect(loadDocument({'nodes': []}).document.nodes, isNotEmpty);
    expect(loadDocument(null).document.nodes, isNotEmpty);
    expect(loadDocument('garbage').document.nodes, isNotEmpty);
  });

  test('randomly corrupted JSON never throws and always validates', () {
    final base = jsonEncode({
      'version': 1,
      'nodes': [
        _text('a', 'hello 😀 world'),
        {
          'type': 'table',
          'id': 't',
          'rows': [
            {
              'cells': [
                {
                  'nodes': [_text('c1', 'x')],
                  'rowSpan': 1,
                  'colSpan': 1,
                },
              ],
            },
          ],
        },
        {'type': 'image', 'id': 'i', 'url': 'u', 'altText': null},
      ],
    });
    for (var seed = 0; seed < 300; seed++) {
      final rng = Random(seed);
      final chars = base.split('');
      for (var k = 0; k < 1 + rng.nextInt(6); k++) {
        final at = rng.nextInt(chars.length);
        switch (rng.nextInt(3)) {
          case 0:
            chars.removeAt(at);
          case 1:
            chars[at] = '{[":,0nul'[rng.nextInt(9)];
          default:
            chars.insert(at, '[]{}"1'[rng.nextInt(6)]);
        }
      }
      Object? decoded;
      try {
        decoded = jsonDecode(chars.join());
      } catch (_) {
        continue; // not JSON at all; the caller's decode handles that
      }
      final result = loadDocument(decoded);
      expect(
        validateDocument(result.document),
        isEmpty,
        reason: 'seed $seed: ${chars.join()}',
      );
    }
  });

  test('non-string ids and types never make the load throw', () {
    final result = loadDocument({
      'nodes': [
        {
          'type': 'text',
          'id': 42,
          'text': {'text': 'x', 'spans': []},
        },
        {'type': 7, 'id': 9},
        {'type': 'mystery', 'id': 3.5},
      ],
    });
    expect(result.document.nodes, hasLength(3));
    expect(validateDocument(result.document), isEmpty);
  });
}
