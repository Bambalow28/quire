import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  test('a multi-line paste over a selection undoes in one step', () {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
      ),
    );
    final before = controller.document.toJson();
    controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition('a', const TextNodePosition(0)),
        extent: DocumentPosition('a', const TextNodePosition(5)),
      ),
    );

    controller.replaceSelectionWithText(
      'one\ntwo\nthree',
      requestFocusAfter: false,
    );
    expect(controller.document.nodes, hasLength(3));

    controller.undo();
    expect(controller.document.toJson(), before);
    expect(controller.canUndo, isFalse);
  });
}
