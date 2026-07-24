import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  test('inserting an image at the end of a document adds a trailing '
      'empty paragraph with the caret in it', () {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
      ),
    );
    controller.requestFocus('a');
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(5)),
      ),
    );

    controller.insertImage('/no/such/file.png');

    final nodes = controller.document.nodes;
    expect(nodes.length, 3);
    expect(nodes[1], isA<ImageNode>());
    final trailing = nodes[2] as TextNode;
    expect(trailing.text.text, isEmpty);
    expect(
      controller.composer.selection,
      DocumentSelection.collapsed(
        DocumentPosition(trailing.id, const TextNodePosition(0)),
      ),
    );
  });

  test('inserting an image before an existing paragraph does not add a '
      'second one', () {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(id: 'a', text: AttributedText('hello')),
          TextNode(id: 'b', text: AttributedText('world')),
        ],
      ),
    );
    controller.requestFocus('a');
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(5)),
      ),
    );

    controller.insertImage('/no/such/file.png');

    final nodes = controller.document.nodes;
    expect(nodes.length, 3);
    expect(nodes.map((n) => n.id), ['a', nodes[1].id, 'b']);
    expect(
      controller.composer.selection,
      DocumentSelection.collapsed(
        DocumentPosition('b', const TextNodePosition(0)),
      ),
    );
  });

  test('inserting a table at the end of a document adds a trailing '
      'empty paragraph, with the caret landing in the first cell', () {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
      ),
    );
    controller.requestFocus('a');
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(5)),
      ),
    );

    controller.insertTable(rows: 2, columns: 2);

    final nodes = controller.document.nodes;
    expect(nodes.length, 3);
    final table = nodes[1] as TableNode;
    final trailing = nodes[2] as TextNode;
    expect(trailing.text.text, isEmpty);

    final firstCellNode = table.rows.first.cells.first.nodes.first;
    expect(
      controller.composer.selection,
      DocumentSelection.collapsed(
        DocumentPosition(firstCellNode.id, const TextNodePosition(0)),
      ),
    );
  });
}
