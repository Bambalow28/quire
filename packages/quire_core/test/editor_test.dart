import 'package:quire_core/quire_core.dart';
import 'package:test/test.dart';

TextNode _para(String id, String text, {Map<String, Object?>? metadata}) =>
    TextNode(id: id, text: AttributedText(text), metadata: metadata);

Editor _editor(
  MutableDocument doc,
  DocumentComposer composer, {
  List<EditReaction> reactions = const [],
}) => Editor(
  doc,
  composer,
  requestHandlers: defaultRequestHandlers,
  reactions: reactions,
);

void main() {
  test('InsertTextRequest inserts text and moves the caret', () {
    final doc = MutableDocument(nodes: [_para('a', 'hello')]);
    final composer = DocumentComposer();
    final editor = _editor(doc, composer);

    editor.execute([
      InsertTextRequest(
        DocumentPosition('a', const TextNodePosition(5)),
        ' world',
      ),
    ]);

    expect((doc.getNodeById('a') as TextNode).text.text, 'hello world');
    expect(composer.selection!.extent.nodePosition, const TextNodePosition(11));
  });

  test('DeleteSelectionRequest deletes within a single node', () {
    final doc = MutableDocument(nodes: [_para('a', 'hello world')]);
    final composer = DocumentComposer(
      selection: DocumentSelection(
        base: DocumentPosition('a', const TextNodePosition(5)),
        extent: DocumentPosition('a', const TextNodePosition(11)),
      ),
    );
    final editor = _editor(doc, composer);

    editor.execute([DeleteSelectionRequest()]);

    expect((doc.getNodeById('a') as TextNode).text.text, 'hello');
    expect(composer.selection!.extent.nodePosition, const TextNodePosition(5));
  });

  test('DeleteSelectionRequest merges across multiple nodes', () {
    final doc = MutableDocument(
      nodes: [
        _para('a', 'hello world'),
        _para('b', 'middle node'),
        _para('c', 'goodbye moon'),
      ],
    );
    final composer = DocumentComposer(
      selection: DocumentSelection(
        base: DocumentPosition(
          'a',
          const TextNodePosition(6),
        ), // after "hello "
        extent: DocumentPosition(
          'c',
          const TextNodePosition(8),
        ), // after "goodbye "
      ),
    );
    final editor = _editor(doc, composer);

    editor.execute([DeleteSelectionRequest()]);

    expect(doc.nodes.length, 1);
    expect((doc.getNodeById('a') as TextNode).text.text, 'hello moon');
    expect(doc.getNodeById('b'), isNull);
    expect(doc.getNodeById('c'), isNull);
    expect(
      composer.selection!.extent,
      DocumentPosition('a', const TextNodePosition(6)),
    );
  });

  test('InsertNewlineRequest splits a node and carries metadata', () {
    final doc = MutableDocument(
      nodes: [
        _para(
          'a',
          'hello world',
          metadata: {'blockType': 'listItemUnordered', 'indent': 1},
        ),
      ],
    );
    final composer = DocumentComposer(
      selection: DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(5)),
      ),
    );
    final editor = _editor(doc, composer);

    editor.execute([InsertNewlineRequest()]);

    expect(doc.nodes.length, 2);
    final first = doc.getNodeAt(0) as TextNode;
    final second = doc.getNodeAt(1) as TextNode;
    expect(first.text.text, 'hello');
    expect(second.text.text, ' world');
    expect(second.blockType, 'listItemUnordered');
    expect(second.indent, 1);
    expect(composer.selection!.extent.nodeId, second.id);
  });

  test('InsertNewlineRequest demotes a heading split to paragraph', () {
    final doc = MutableDocument(
      nodes: [
        _para('a', 'hello world', metadata: {'blockType': 'header1'}),
      ],
    );
    final composer = DocumentComposer(
      selection: DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(5)),
      ),
    );
    final editor = _editor(doc, composer);

    editor.execute([InsertNewlineRequest()]);

    final first = doc.getNodeAt(0) as TextNode;
    final second = doc.getNodeAt(1) as TextNode;
    expect(first.blockType, 'header1');
    expect(second.blockType, 'paragraph');
  });

  test('ToggleAttributionRequest over an expanded multi-node selection', () {
    const bold = Attribution('bold');
    final doc = MutableDocument(
      nodes: [_para('a', 'hello world'), _para('b', 'goodbye moon')],
    );
    final composer = DocumentComposer(
      selection: DocumentSelection(
        base: DocumentPosition('a', const TextNodePosition(6)),
        extent: DocumentPosition('b', const TextNodePosition(7)),
      ),
    );
    final editor = _editor(doc, composer);

    editor.execute([ToggleAttributionRequest(bold)]);

    final a = doc.getNodeById('a') as TextNode;
    final b = doc.getNodeById('b') as TextNode;
    expect(a.text.hasAttributionThroughout(bold, 6, 11), isTrue);
    expect(b.text.hasAttributionThroughout(bold, 0, 7), isTrue);

    // Toggling again over the same (now fully-bold) range removes it.
    editor.execute([ToggleAttributionRequest(bold)]);
    expect(a.text.attributionsAt(6), isEmpty);
    expect(b.text.attributionsAt(0), isEmpty);
  });

  test(
    'ToggleAttributionRequest on a collapsed selection arms composingAttributions',
    () {
      const bold = Attribution('bold');
      final doc = MutableDocument(nodes: [_para('a', 'hello')]);
      final composer = DocumentComposer(
        selection: DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(2)),
        ),
      );
      final editor = _editor(doc, composer);

      editor.execute([ToggleAttributionRequest(bold)]);
      expect(composer.composingAttributions, {bold});

      editor.execute([ToggleAttributionRequest(bold)]);
      expect(composer.composingAttributions, isEmpty);
    },
  );

  test(
    'ChangeBlockTypeRequest and ChangeIndentRequest apply across the selection',
    () {
      final doc = MutableDocument(nodes: [_para('a', 'x'), _para('b', 'y')]);
      final composer = DocumentComposer(
        selection: DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(0)),
          extent: DocumentPosition('b', const TextNodePosition(1)),
        ),
      );
      final editor = _editor(doc, composer);

      editor.execute([ChangeBlockTypeRequest('header2')]);
      expect((doc.getNodeById('a') as TextNode).blockType, 'header2');
      expect((doc.getNodeById('b') as TextNode).blockType, 'header2');

      editor.execute([ChangeIndentRequest(3)]);
      expect((doc.getNodeById('a') as TextNode).indent, 3);
      editor.execute([ChangeIndentRequest(10)]);
      expect((doc.getNodeById('a') as TextNode).indent, 8); // clamped
      editor.execute([ChangeIndentRequest(-100)]);
      expect((doc.getNodeById('a') as TextNode).indent, 0); // clamped
    },
  );

  test(
    'ChangeTextAlignRequest applies across the selection and undo restores it',
    () {
      final doc = MutableDocument(nodes: [_para('a', 'x'), _para('b', 'y')]);
      final composer = DocumentComposer(
        selection: DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(0)),
          extent: DocumentPosition('b', const TextNodePosition(1)),
        ),
      );
      final editor = Editor(
        doc,
        composer,
        requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
      );
      final history = EditHistory(editor);

      expect((doc.getNodeById('a') as TextNode).textAlign, 'left');

      history.execute([ChangeTextAlignRequest('center')]);
      expect((doc.getNodeById('a') as TextNode).textAlign, 'center');
      expect((doc.getNodeById('b') as TextNode).textAlign, 'center');

      history.undo();
      expect((doc.getNodeById('a') as TextNode).textAlign, 'left');
      expect((doc.getNodeById('b') as TextNode).textAlign, 'left');
    },
  );

  test(
    'ChangeLineSpacingRequest applies, clamps, and undo restores it',
    () {
      final doc = MutableDocument(nodes: [_para('a', 'x')]);
      final composer = DocumentComposer(
        selection: DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(0)),
        ),
      );
      final editor = Editor(
        doc,
        composer,
        requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
      );
      final history = EditHistory(editor);

      expect((doc.getNodeById('a') as TextNode).lineSpacing, 1.0);

      history.execute([ChangeLineSpacingRequest(1.5)]);
      expect((doc.getNodeById('a') as TextNode).lineSpacing, 1.5);

      editor.execute([ChangeLineSpacingRequest(10.0)]);
      expect((doc.getNodeById('a') as TextNode).lineSpacing, 2.5); // clamped
      editor.execute([ChangeLineSpacingRequest(-1.0)]);
      expect((doc.getNodeById('a') as TextNode).lineSpacing, 1.0); // clamped

      history.undo();
      expect((doc.getNodeById('a') as TextNode).lineSpacing, 1.0);
    },
  );

  test(
    'DeleteSelectionRequest nulls the selection when deleting the sole '
    '(non-text) node in the document',
    () {
      final doc = MutableDocument(nodes: [HorizontalRuleNode(id: 'hr')]);
      final composer = DocumentComposer(
        selection: const DocumentSelection(
          base: DocumentPosition('hr', UpstreamDownstreamNodePosition.upstream()),
          extent: DocumentPosition(
            'hr',
            UpstreamDownstreamNodePosition.downstream(),
          ),
        ),
      );
      final editor = _editor(doc, composer);

      editor.execute([DeleteSelectionRequest()]);

      expect(doc.nodes, isEmpty);
      expect(composer.selection, isNull);
    },
  );

  test(
    'DeleteSelectionRequest nulls the selection when deleting a selection '
    'spanning the entire document across two non-text nodes',
    () {
      final doc = MutableDocument(
        nodes: [HorizontalRuleNode(id: 'a'), HorizontalRuleNode(id: 'b')],
      );
      final composer = DocumentComposer(
        selection: const DocumentSelection(
          base: DocumentPosition('a', UpstreamDownstreamNodePosition.upstream()),
          extent: DocumentPosition(
            'b',
            UpstreamDownstreamNodePosition.downstream(),
          ),
        ),
      );
      final editor = _editor(doc, composer);

      editor.execute([DeleteSelectionRequest()]);

      expect(doc.nodes, isEmpty);
      expect(composer.selection, isNull);
    },
  );

  test('InsertNodeRequest and DeleteNodeRequest', () {
    final doc = MutableDocument(nodes: [_para('a', 'x')]);
    final composer = DocumentComposer();
    final editor = _editor(doc, composer);

    editor.execute([
      InsertNodeRequest(HorizontalRuleNode(id: 'hr'), afterNodeId: 'a'),
    ]);
    expect(doc.nodes.map((n) => n.id).take(2), ['a', 'hr']);
    // A non-text block gets a trailing empty paragraph so there's somewhere
    // to type next, with the caret landing in it.
    expect(doc.nodes.length, 3);
    final trailing = doc.nodes.last as TextNode;
    expect(trailing.text.text, isEmpty);
    expect(
      composer.selection,
      DocumentSelection.collapsed(
        DocumentPosition(trailing.id, const TextNodePosition(0)),
      ),
    );

    editor.execute([DeleteNodeRequest('hr')]);
    expect(doc.getNodeById('hr'), isNull);
  });

  test(
    'reactions can enqueue more requests, and listeners fire once with the full change list',
    () {
      final doc = MutableDocument(nodes: [_para('a', 'hello')]);
      final composer = DocumentComposer();

      // A reaction that appends "!" once, right after any insertion.
      final reaction = _ExclaimReaction();
      final editor = _editor(doc, composer, reactions: [reaction]);

      var notifyCount = 0;
      List<EditEvent>? lastEvents;
      editor.addListener(
        _CallbackListener((events) {
          notifyCount++;
          lastEvents = events;
        }),
      );

      editor.execute([
        InsertTextRequest(
          DocumentPosition('a', const TextNodePosition(5)),
          ' world',
        ),
      ]);

      expect(notifyCount, 1);
      expect((doc.getNodeById('a') as TextNode).text.text, 'hello world!');
      expect(lastEvents!.whereType<DocumentEdited>().length, 2);
    },
  );

  test('a command throwing leaves the Editor usable for the next execute', () {
    final doc = MutableDocument(nodes: [_para('a', 'hello')]);
    final composer = DocumentComposer();
    final editor = Editor(
      doc,
      composer,
      requestHandlers: [
        (request) => request is _ThrowingRequest ? _ThrowingCommand() : null,
        ...defaultRequestHandlers,
      ],
    );

    expect(
      () => editor.execute([_ThrowingRequest()]),
      throwsA(isA<Exception>()),
    );

    // The editor must still work: no wedged batch/reaction-depth state.
    editor.execute([
      InsertTextRequest(DocumentPosition('a', const TextNodePosition(5)), '!'),
    ]);
    expect((doc.getNodeById('a') as TextNode).text.text, 'hello!');
  });

  test('a request with no matching handler throws a StateError', () {
    final doc = MutableDocument(nodes: [_para('a', 'hello')]);
    final editor = _editor(doc, DocumentComposer());
    expect(
      () => editor.execute([_UnhandledRequest()]),
      throwsA(isA<StateError>()),
    );
  });

  test('ToggleAttributionRequest on a collapsed selection emits an event', () {
    const bold = Attribution('bold');
    final doc = MutableDocument(nodes: [_para('a', 'hello')]);
    final composer = DocumentComposer(
      selection: DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(2)),
      ),
    );
    final editor = _editor(doc, composer);

    List<EditEvent>? events;
    editor.addListener(_CallbackListener((e) => events = e));

    editor.execute([ToggleAttributionRequest(bold)]);
    expect(events, isNotNull);
    expect(events!.whereType<ComposingAttributionsChanged>(), isNotEmpty);
  });

  test(
    'moving the caret arms/disarms composingAttributions from surrounding text',
    () {
      const bold = Attribution('bold');
      final doc = MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('bold plain', [AttributionSpan(bold, 0, 4)]),
          ),
        ],
      );
      final composer = DocumentComposer();
      final editor = _editor(doc, composer);

      // Caret lands inside the bold run: bold should arm.
      editor.execute([
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            DocumentPosition('a', const TextNodePosition(2)),
          ),
        ),
      ]);
      expect(composer.composingAttributions, {bold});

      // Caret moves into plain text: bold should clear.
      editor.execute([
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            DocumentPosition('a', const TextNodePosition(7)),
          ),
        ),
      ]);
      expect(composer.composingAttributions, isEmpty);
    },
  );

  test(
    'InsertTextRequest with null attributions uses composingAttributions',
    () {
      const bold = Attribution('bold');
      final doc = MutableDocument(nodes: [_para('a', 'hello')]);
      final composer = DocumentComposer()..composingAttributions = {bold};
      final editor = _editor(doc, composer);

      editor.execute([
        InsertTextRequest(
          DocumentPosition('a', const TextNodePosition(5)),
          '!',
        ),
      ]);

      final text = (doc.getNodeById('a') as TextNode).text;
      expect(text.attributionsAt(5), {bold});
    },
  );

  test('MergeWithPreviousNodeRequest joins two text nodes at the seam', () {
    final doc = MutableDocument(
      nodes: [_para('a', 'hello '), _para('b', 'world')],
    );
    final composer = DocumentComposer();
    final editor = _editor(doc, composer);

    editor.execute([MergeWithPreviousNodeRequest('b')]);

    expect(doc.nodes.length, 1);
    expect((doc.getNodeById('a') as TextNode).text.text, 'hello world');
    expect(doc.getNodeById('b'), isNull);
    expect(
      composer.selection!.extent,
      DocumentPosition('a', const TextNodePosition(6)),
    );
  });

  test('MergeWithPreviousNodeRequest deletes a non-text previous node', () {
    final doc = MutableDocument(
      nodes: [
        HorizontalRuleNode(id: 'a'),
        _para('b', 'world'),
      ],
    );
    final composer = DocumentComposer();
    final editor = _editor(doc, composer);

    editor.execute([MergeWithPreviousNodeRequest('b')]);

    expect(doc.nodes.length, 1);
    expect(doc.getNodeById('a'), isNull);
    expect((doc.getNodeById('b') as TextNode).text.text, 'world');
    expect(
      composer.selection!.extent,
      DocumentPosition('b', const TextNodePosition(0)),
    );
  });

  test(
    'MergeWithPreviousNodeRequest is a no-op on a plain first paragraph',
    () {
      final doc = MutableDocument(nodes: [_para('a', 'hello')]);
      final composer = DocumentComposer();
      final editor = _editor(doc, composer);

      editor.execute([MergeWithPreviousNodeRequest('a')]);

      expect(doc.nodes.length, 1);
      expect((doc.getNodeById('a') as TextNode).blockType, 'paragraph');
    },
  );

  test('MergeWithPreviousNodeRequest on the first node drops its block type '
      'instead of merging, since there is nothing to merge into', () {
    final doc = MutableDocument(
      nodes: [
        _para(
          'a',
          'buy milk',
          metadata: {'blockType': 'listItemTask', 'checked': true},
        ),
      ],
    );
    final composer = DocumentComposer();
    final editor = _editor(doc, composer);

    editor.execute([MergeWithPreviousNodeRequest('a')]);

    final node = doc.getNodeById('a') as TextNode;
    expect(node.blockType, 'paragraph');
    // Same rule ChangeBlockTypeRequest already follows: leaving a task
    // item drops the tick rather than letting it reappear silently.
    expect(node.isChecked, isFalse);
    expect(node.text.text, 'buy milk'); // text itself is untouched
  });

  test('MergeWithPreviousNodeRequest on an indented first node dedents once, '
      'and only drops the block type once indent reaches zero', () {
    final doc = MutableDocument(
      nodes: [
        _para(
          'a',
          'nested',
          metadata: {'blockType': 'listItemUnordered', 'indent': 2},
        ),
      ],
    );
    final composer = DocumentComposer();
    final editor = _editor(doc, composer);

    editor.execute([MergeWithPreviousNodeRequest('a')]);
    var node = doc.getNodeById('a') as TextNode;
    expect(node.indent, 1);
    expect(node.blockType, 'listItemUnordered'); // one step at a time

    editor.execute([MergeWithPreviousNodeRequest('a')]);
    node = doc.getNodeById('a') as TextNode;
    expect(node.indent, 0);
    expect(node.blockType, 'listItemUnordered');

    editor.execute([MergeWithPreviousNodeRequest('a')]);
    node = doc.getNodeById('a') as TextNode;
    expect(node.indent, 0);
    expect(node.blockType, 'paragraph');
  });

  test('ToggleTaskCheckedRequest flips checked and undo restores it', () {
    final doc = MutableDocument(
      nodes: [
        _para('a', 'buy milk', metadata: {'blockType': 'listItemTask'}),
      ],
    );
    final composer = DocumentComposer();
    final editor = Editor(
      doc,
      composer,
      requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
    );
    final history = EditHistory(editor);

    expect((doc.getNodeById('a') as TextNode).isChecked, isFalse);

    history.execute([ToggleTaskCheckedRequest('a')]);
    expect((doc.getNodeById('a') as TextNode).isChecked, isTrue);

    history.undo();
    expect((doc.getNodeById('a') as TextNode).isChecked, isFalse);
  });

  test('Enter after a checked task item produces an unchecked one', () {
    final doc = MutableDocument(
      nodes: [
        _para(
          'a',
          'buy milk',
          metadata: {'blockType': 'listItemTask', 'checked': true},
        ),
      ],
    );
    final composer = DocumentComposer(
      selection: DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(8)),
      ),
    );
    final editor = _editor(doc, composer);

    editor.execute([InsertNewlineRequest()]);

    final second = doc.getNodeAt(1) as TextNode;
    expect(second.blockType, 'listItemTask');
    expect(second.isChecked, isFalse);
  });
}

class _ThrowingRequest extends EditRequest {}

class _ThrowingCommand extends EditCommand {
  @override
  void execute(EditContext context, CommandExecutor executor) {
    throw Exception('boom');
  }
}

class _UnhandledRequest extends EditRequest {}

class _ExclaimReaction implements EditReaction {
  var _fired = false;

  @override
  void react(EditContext context, Editor editor, List<EditEvent> events) {
    if (_fired) return;
    final hasInsert = events.whereType<DocumentEdited>().isNotEmpty;
    if (!hasInsert) return;
    _fired = true;
    final node = context.document.first as TextNode;
    editor.execute([
      InsertTextRequest(
        DocumentPosition(node.id, TextNodePosition(node.text.text.length)),
        '!',
      ),
    ]);
  }
}

class _CallbackListener implements EditListener {
  _CallbackListener(this.callback);
  final void Function(List<EditEvent>) callback;

  @override
  void onEdit(List<EditEvent> events) => callback(events);
}
