import 'package:quire_core/quire_core.dart';
import 'package:test/test.dart';

void main() {
  late MutableDocument doc;
  late DocumentComposer composer;
  late Editor editor;

  setUp(() {
    doc = MutableDocument(
      nodes: [
        TextNode(
          id: 'toggle',
          text: AttributedText('Details'),
          metadata: {'blockType': 'toggleList'},
        ),
        TextNode(
          id: 'inner',
          text: AttributedText('inside'),
          metadata: {'indent': 1},
        ),
      ],
    );
    composer = DocumentComposer();
    editor = Editor(doc, composer, requestHandlers: defaultRequestHandlers);
  });

  test('an image inserted inside a toggle takes its depth', () {
    editor.execute([
      InsertNodeRequest(
        ImageNode(id: 'img', url: 'x.png'),
        afterNodeId: 'inner',
      ),
    ]);
    expect(doc.getNodeById('img')!.indent, 1);
    final trailing = doc.getNodeAfter('img') as TextNode;
    expect(trailing.indent, 1, reason: 'caret paragraph stays in the toggle');
  });

  test('a table inserted inside a toggle takes its depth', () {
    editor.execute([InsertTableRequest(afterNodeId: 'inner')]);
    final table = doc.nodes.whereType<TableNode>().single;
    expect(table.indent, 1);
    expect(validateDocument(doc, composer.selection), isEmpty);
  });

  test('depth survives a JSON round trip', () {
    editor.execute([
      InsertNodeRequest(
        ImageNode(id: 'img', url: 'x'),
        afterNodeId: 'inner',
      ),
    ]);
    final back = loadDocument(doc.toJson()).document;
    expect(back.getNodeById('img')!.indent, 1);
  });

  test('a block after a plain nested list item stays at depth 0', () {
    doc = MutableDocument(
      nodes: [
        TextNode(
          id: 'a',
          text: AttributedText('a'),
          metadata: {'blockType': 'listItemUnordered'},
        ),
        TextNode(
          id: 'b',
          text: AttributedText('b'),
          metadata: {'blockType': 'listItemUnordered', 'indent': 1},
        ),
      ],
    );
    editor = Editor(doc, composer, requestHandlers: defaultRequestHandlers);
    editor.execute([
      InsertNodeRequest(
        ImageNode(id: 'img', url: 'x'),
        afterNodeId: 'b',
      ),
    ]);
    expect(doc.getNodeById('img')!.indent, 0);
  });

  test('a block inserted after a toggle title nests inside it', () {
    editor.execute([
      InsertNodeRequest(
        ImageNode(id: 'img', url: 'x'),
        afterNodeId: 'toggle',
      ),
    ]);
    expect(doc.getNodeById('img')!.indent, 1);
  });
}
