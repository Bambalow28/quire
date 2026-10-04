import 'package:quire_core/quire_core.dart';
import 'package:test/test.dart';

TextNode _p(String id, {int indent = 0, String type = 'paragraph'}) => TextNode(
  id: id,
  text: AttributedText(id),
  metadata: {'blockType': type, if (indent > 0) 'indent': indent},
);

(MutableDocument, DocumentComposer, Editor) _setup(List<DocumentNode> nodes) {
  final doc = MutableDocument(nodes: nodes);
  final composer = DocumentComposer();
  final editor = Editor(doc, composer, requestHandlers: defaultRequestHandlers);
  return (doc, composer, editor);
}

List<String> _ids(MutableDocument d) => [for (final n in d.nodes) n.id];

void main() {
  group('MoveBlockRequest', () {
    test('moves a block down and up past a sibling', () {
      final (doc, _, editor) = _setup([_p('a'), _p('b'), _p('c')]);
      editor.execute([MoveBlockRequest('a', 1)]);
      expect(_ids(doc), ['b', 'a', 'c']);
      editor.execute([MoveBlockRequest('a', -1)]);
      expect(_ids(doc), ['a', 'b', 'c']);
    });

    test('carries nested children with their parent', () {
      final (doc, _, editor) = _setup([
        _p('t', type: 'toggleList'),
        _p('t1', indent: 1),
        _p('t2', indent: 1),
        _p('b'),
      ]);
      editor.execute([MoveBlockRequest('t', 1)]);
      expect(_ids(doc), ['b', 't', 't1', 't2']);
      editor.execute([MoveBlockRequest('b', 1)]);
      expect(_ids(doc), ['t', 't1', 't2', 'b']);
    });

    test('clamps at the ends and never leaves a container', () {
      final (doc, _, editor) = _setup([
        _p('t', type: 'toggleList'),
        _p('t1', indent: 1),
        _p('t2', indent: 1),
        _p('b'),
      ]);
      editor.execute([MoveBlockRequest('t', -3)]);
      expect(_ids(doc), ['t', 't1', 't2', 'b']);
      editor.execute([MoveBlockRequest('t1', -1)]);
      expect(_ids(doc), ['t', 't1', 't2', 'b']);
      editor.execute([MoveBlockRequest('t2', 5)]);
      expect(_ids(doc), ['t', 't1', 't2', 'b']);
      editor.execute([MoveBlockRequest('t2', -1)]);
      expect(_ids(doc), ['t', 't2', 't1', 'b']);
    });

    test('multi-step move and cache refresh', () {
      final (doc, _, editor) = _setup([_p('a'), _p('b'), _p('c'), _p('d')]);
      editor.execute([MoveBlockRequest('a', 3)]);
      expect(_ids(doc), ['b', 'c', 'd', 'a']);
      expect(doc.getNodeIndexById('a'), 3);
      expect(doc.getNodeBefore('a')!.id, 'd');
    });
  });

  group('DuplicateBlockRequest', () {
    test('copies the block with fresh ids and focuses the copy', () {
      final (doc, composer, editor) = _setup([
        _p('t', type: 'toggleList'),
        _p('t1', indent: 1),
        _p('b'),
      ]);
      editor.execute([DuplicateBlockRequest('t')]);
      expect(doc.nodes.length, 5);
      expect(doc.nodes.map((n) => n.id).toSet().length, 5);
      expect((doc.nodes[2] as TextNode).blockType, 'toggleList');
      expect(doc.nodes[3].indent, 1);
      expect(composer.selection!.extent.nodeId, doc.nodes[2].id);
    });

    test('copies a table with fresh nested ids', () {
      final table = TableNode(
        id: 'tbl',
        rows: [
          TableRow(
            cells: [
              TableCell(nodes: [_p('c1')]),
            ],
          ),
        ],
      );
      final (doc, _, editor) = _setup([table]);
      editor.execute([DuplicateBlockRequest('tbl')]);
      final copy = doc.nodes[1] as TableNode;
      expect(copy.id, isNot('tbl'));
      final nested = copy.rows.first.cells.first.nodes.first;
      expect(nested.id, isNot('c1'));
      expect(doc.getNodeById(nested.id), same(nested));
    });
  });

  group('DeleteBlockRequest', () {
    test('removes the block with its children', () {
      final (doc, composer, editor) = _setup([
        _p('a'),
        _p('t', type: 'toggleList'),
        _p('t1', indent: 1),
        _p('b'),
      ]);
      editor.execute([DeleteBlockRequest('t')]);
      expect(_ids(doc), ['a', 'b']);
      expect(composer.selection!.extent.nodeId, 'b');
    });

    test('leaves an empty paragraph when the last block goes', () {
      final (doc, composer, editor) = _setup([_p('a')]);
      editor.execute([DeleteBlockRequest('a')]);
      expect(doc.nodes.length, 1);
      expect((doc.nodes.single as TextNode).text.text, '');
      expect(composer.selection!.extent.nodeId, doc.nodes.single.id);
    });
  });

  group('SetAttributionRequest', () {
    TextNode only(MutableDocument d) => d.nodes.single as TextNode;
    ChangeSelectionRequest sel(int a, int b) => ChangeSelectionRequest(
      DocumentSelection(
        base: DocumentPosition('a', TextNodePosition(a)),
        extent: DocumentPosition('a', TextNodePosition(b)),
      ),
    );

    test('replaces a colour and clears it', () {
      final doc = MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
      );
      final composer = DocumentComposer();
      final editor = Editor(
        doc,
        composer,
        requestHandlers: defaultRequestHandlers,
      );
      editor.execute([
        sel(0, 5),
        SetAttributionRequest('color', {'hex': '#ff0000'}),
      ]);
      editor.execute([
        sel(3, 8),
        SetAttributionRequest('color', {'hex': '#0000ff'}),
      ]);
      final spans = only(doc).text.spans;
      expect(spans.length, 2);
      expect(only(doc).text.attributionsAt(1).single.value['hex'], '#ff0000');
      expect(only(doc).text.attributionsAt(4).single.value['hex'], '#0000ff');
      // Re-applying the same colour keeps it (a toggle would remove it).
      editor.execute([
        sel(3, 8),
        SetAttributionRequest('color', {'hex': '#0000ff'}),
      ]);
      expect(only(doc).text.attributionsAt(4), isNotEmpty);
      editor.execute([sel(0, 11), SetAttributionRequest('color', null)]);
      expect(only(doc).text.spans, isEmpty);
    });

    test('collapsed selection arms the composing attributions', () {
      final doc = MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hi'))],
      );
      final composer = DocumentComposer();
      final editor = Editor(
        doc,
        composer,
        requestHandlers: defaultRequestHandlers,
      );
      editor.execute([
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            DocumentPosition('a', const TextNodePosition(2)),
          ),
        ),
        SetAttributionRequest('backgroundColor', {'hex': '#ffee00'}),
      ]);
      expect(composer.composingAttributions.single.name, 'backgroundColor');
      editor.execute([SetAttributionRequest('backgroundColor', null)]);
      expect(composer.composingAttributions, isEmpty);
    });
  });

  test('SetNodeMetadataRequest sets and removes a key', () {
    final (doc, _, editor) = _setup([_p('a', type: 'code')]);
    editor.execute([SetNodeMetadataRequest('a', 'language', 'dart')]);
    expect(doc.getNodeById('a')!.metadata['language'], 'dart');
    editor.execute([
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(0)),
        ),
      ),
    ]);
    editor.execute([ChangeBlockTypeRequest('paragraph')]);
    expect(doc.getNodeById('a')!.metadata.containsKey('language'), isFalse);
  });
}
