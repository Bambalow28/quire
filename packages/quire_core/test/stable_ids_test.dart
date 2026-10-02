import 'dart:math';

import 'package:quire_core/quire_core.dart';
import 'package:test/test.dart';

// Sync merges per node, so a node's id has to outlive every edit that does not
// delete the node.

List<String> _ids(MutableDocument d) =>
    d.nodesInDocumentOrder.map((n) => n.id).toList();

void main() {
  late MutableDocument doc;
  late DocumentComposer composer;
  late Editor editor;

  setUp(() {
    doc = MutableDocument(
      nodes: [
        for (var i = 0; i < 4; i++)
          TextNode(id: 'n$i', text: AttributedText('line number $i')),
      ],
    );
    composer = DocumentComposer();
    editor = Editor(
      doc,
      composer,
      requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
    );
  });

  DocumentSelection caret(String id, int offset) => DocumentSelection.collapsed(
    DocumentPosition(id, TextNodePosition(offset)),
  );

  test('formatting and typing never change or drop an existing id', () {
    final before = _ids(doc);
    final rng = Random(3);
    for (var i = 0; i < 200; i++) {
      final id = 'n${rng.nextInt(4)}';
      final len = (doc.getNodeById(id) as TextNode).text.text.length;
      final at = rng.nextInt(len + 1);
      final kind = rng.nextInt(5);
      editor.execute([
        ChangeSelectionRequest(caret(id, at)),
        switch (kind) {
          0 => InsertTextRequest(
            DocumentPosition(id, TextNodePosition(at)),
            'x',
          ),
          1 => ChangeBlockTypeRequest('header1'),
          2 => ChangeIndentRequest(1),
          3 => ToggleTaskCheckedRequest(id),
          _ => ToggleAttributionRequest(const Attribution('bold')),
        },
      ]);
      // A trailing paragraph may be appended after a block that needs one;
      // what matters is that no existing id changes or disappears.
      expect(
        _ids(doc),
        containsAllInOrder(before),
        reason: 'step $i kind $kind on $id at $at',
      );
    }
  });

  test('splitting a line keeps the original id on the first half', () {
    editor.execute([
      ChangeSelectionRequest(caret('n1', 4)),
      InsertNewlineRequest(),
    ]);
    final ids = _ids(doc);
    expect(ids.take(2), ['n0', 'n1']);
    expect(ids, hasLength(5));
    expect((doc.getNodeById('n1') as TextNode).text.text, 'line');
  });

  test('merging a line keeps the earlier id', () {
    editor.execute([
      ChangeSelectionRequest(caret('n2', 0)),
      MergeWithPreviousNodeRequest('n2'),
    ]);
    expect(doc.getNodeById('n1'), isNotNull);
    expect(doc.getNodeById('n2'), isNull);
  });

  test('undo and redo bring back the very same ids', () {
    final history = EditHistory(editor);
    final before = _ids(doc);
    history.execute([
      ChangeSelectionRequest(caret('n1', 4)),
      InsertNewlineRequest(),
    ]);
    final after = _ids(doc);
    history.undo();
    expect(_ids(doc), before);
    history.redo();
    expect(_ids(doc), after);
  });

  test('ids survive a JSON round trip', () {
    expect(_ids(loadDocument(doc.toJson()).document), _ids(doc));
  });
}
