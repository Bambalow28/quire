import 'package:quire_core/quire_core.dart';
import 'package:test/test.dart';

TextNode _para(String id, String text) =>
    TextNode(id: id, text: AttributedText(text));

void main() {
  test(
    'scripted sequence: undo returns to initial state, redo returns to final state',
    () {
      final doc = MutableDocument(nodes: [_para('a', 'Hello')]);
      final composer = DocumentComposer(
        selection: DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(5)),
        ),
      );
      final editor = Editor(
        doc,
        composer,
        requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
      );
      final history = EditHistory(editor);

      final initialSnapshot = doc.toJson();
      const bold = Attribution('bold');

      void run(List<EditRequest> requests) => history.execute(requests);

      // Type " world" one character at a time (contiguous single-char inserts
      // should coalesce into a single undo step, not 6).
      var offset = 5;
      for (final ch in ' world'.split('')) {
        run([
          InsertTextRequest(
            DocumentPosition('a', TextNodePosition(offset)),
            ch,
          ),
        ]);
        offset++;
      }
      expect(history.undoCount, 1);

      run([InsertNewlineRequest()]);

      final secondNodeId = doc.getNodeAt(1).id;
      run([
        InsertTextRequest(
          DocumentPosition(secondNodeId, const TextNodePosition(0)),
          'Second paragraph',
        ),
      ]);

      run([ChangeBlockTypeRequest('header1')]);

      run([
        ChangeSelectionRequest(
          DocumentSelection(
            base: DocumentPosition('a', const TextNodePosition(0)),
            extent: DocumentPosition('a', const TextNodePosition(5)),
          ),
        ),
      ]);
      run([ToggleAttributionRequest(bold)]);

      run([ChangeIndentRequest(2)]);

      run([
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            DocumentPosition('a', const TextNodePosition(11)),
          ),
        ),
      ]);
      run([
        InsertTextRequest(
          DocumentPosition('a', const TextNodePosition(11)),
          '!',
        ),
      ]);
      run([
        InsertTextRequest(
          DocumentPosition('a', const TextNodePosition(12)),
          '!',
        ),
      ]);
      run([
        InsertTextRequest(
          DocumentPosition('a', const TextNodePosition(13)),
          '!',
        ),
      ]);

      run([
        ChangeSelectionRequest(
          DocumentSelection(
            base: DocumentPosition('a', const TextNodePosition(11)),
            extent: DocumentPosition('a', const TextNodePosition(14)),
          ),
        ),
      ]);
      run([DeleteSelectionRequest()]);

      run([
        InsertNodeRequest(
          HorizontalRuleNode(id: 'hr'),
          afterNodeId: secondNodeId,
        ),
      ]);

      run([
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            DocumentPosition(secondNodeId, const TextNodePosition(0)),
          ),
        ),
      ]);
      run([InsertNewlineRequest()]);

      final thirdNodeId = doc.getNodeAt(2).id;
      run([
        InsertTextRequest(
          DocumentPosition(thirdNodeId, const TextNodePosition(0)),
          'x',
        ),
      ]);
      run([
        InsertTextRequest(
          DocumentPosition(thirdNodeId, const TextNodePosition(1)),
          'y',
        ),
      ]);

      run([DeleteNodeRequest('hr')]);

      run([ChangeIndentRequest(-1)]);

      final finalSnapshot = doc.toJson();
      expect(finalSnapshot, isNot(equals(initialSnapshot)));

      // Typing coalescing: 6 + 3 + 2 = 11 single-char keystrokes went in, but
      // across the whole script there are far fewer undo steps than requests.
      const totalRequests = 25;
      expect(history.undoCount, lessThan(totalRequests));
      expect(history.canUndo, isTrue);

      var undoSteps = 0;
      while (history.canUndo) {
        history.undo();
        undoSteps++;
      }
      expect(undoSteps, lessThan(totalRequests));
      expect(doc.toJson(), equals(initialSnapshot));

      var redoSteps = 0;
      while (history.canRedo) {
        history.redo();
        redoSteps++;
      }
      expect(redoSteps, undoSteps);
      expect(doc.toJson(), equals(finalSnapshot));
    },
  );

  test(
    'a selection change landing back at the same offset, submitted directly '
    'through the editor (bypassing history.execute), breaks the typing streak',
    () {
      final doc = MutableDocument(nodes: [_para('a', 'Hello')]);
      final composer = DocumentComposer();
      final editor = Editor(
        doc,
        composer,
        requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
      );
      final history = EditHistory(editor);

      history.execute([
        InsertTextRequest(
          DocumentPosition('a', const TextNodePosition(5)),
          'X',
        ),
      ]);
      expect((doc.getNodeById('a') as TextNode).text.text, 'HelloX');

      // Bypasses history.execute entirely — as e.g. pure caret-movement UI
      // code might, since it isn't undo-worthy on its own — landing right
      // back at the offset the next keystroke would continue from.
      editor.execute([
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            DocumentPosition('a', const TextNodePosition(6)),
          ),
        ),
      ]);

      history.execute([
        InsertTextRequest(
          DocumentPosition('a', const TextNodePosition(6)),
          'Y',
        ),
      ]);
      expect((doc.getNodeById('a') as TextNode).text.text, 'HelloXY');

      // The two inserts must not have coalesced: undoing once only removes
      // the second character.
      history.undo();
      expect((doc.getNodeById('a') as TextNode).text.text, 'HelloX');
    },
  );

  test('EditHistory.execute records automatically, no manual record step', () {
    final doc = MutableDocument(nodes: [_para('a', 'Hello')]);
    final composer = DocumentComposer();
    final editor = Editor(
      doc,
      composer,
      requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
    );
    final history = EditHistory(editor);

    expect(history.canUndo, isFalse);
    history.execute([
      InsertTextRequest(DocumentPosition('a', const TextNodePosition(5)), '!'),
    ]);
    expect((doc.getNodeById('a') as TextNode).text.text, 'Hello!');
    expect(history.canUndo, isTrue);

    history.undo();
    expect((doc.getNodeById('a') as TextNode).text.text, 'Hello');
  });

  test('a transaction is one undo step', () {
    final doc = MutableDocument(nodes: [_para('a', 'Hello')]);
    final composer = DocumentComposer(
      selection: DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(5)),
      ),
    );
    final editor = Editor(
      doc,
      composer,
      requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
    );
    final history = EditHistory(editor);
    final before = doc.toJson();

    history.transaction(() {
      history.execute([
        InsertTextRequest(
          DocumentPosition('a', const TextNodePosition(5)),
          ' one',
        ),
      ]);
      history.execute([InsertNewlineRequest()]);
      history.execute([InsertTextRequest(composer.selection!.extent, 'two')]);
    });

    expect(doc.nodes, hasLength(2));
    expect(history.undoCount, 1);
    history.undo();
    expect(doc.toJson(), before);
  });

  test('document order cache follows inserts and deletes', () {
    final doc = MutableDocument(nodes: [_para('a', 'A'), _para('c', 'C')]);
    expect(doc.getNodeIndexById('c'), 1);
    doc.insertNodeAfter('a', _para('b', 'B'));
    expect(doc.getNodeIndexById('c'), 2);
    expect(doc.getNodeAt(1).id, 'b');
    doc.deleteNode('a');
    expect(doc.getNodeIndexById('a'), -1);
    expect(doc.getNodeIndexById('c'), 1);
  });
}
