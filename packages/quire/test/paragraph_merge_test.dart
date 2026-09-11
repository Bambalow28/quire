import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

List<String> _texts(QuireEditorController c) =>
    c.document.nodes.whereType<TextNode>().map((n) => n.text.text).toList();

Future<EditableTextState> _pumpFocusStart(
  WidgetTester t,
  QuireEditorController c,
  int fieldIndex,
) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(body: QuireEditor(controller: c)),
    ),
  );
  await t.pumpAndSettle();
  await t.tapAt(
    t.getTopLeft(find.byType(EditableText).at(fieldIndex)) + const Offset(2, 8),
  );
  await t.pumpAndSettle();
  final field = t.state<EditableTextState>(
    find.byType(EditableText).at(fieldIndex),
  );
  // Caret at model offset 0 = field offset 1 (past the sentinel).
  field.userUpdateTextEditingValue(
    field.textEditingValue.copyWith(
      selection: const TextSelection.collapsed(offset: 1),
    ),
    SelectionChangedCause.tap,
  );
  await t.pumpAndSettle();
  return field;
}

/// The soft-keyboard backspace-at-start delta: the field's leading sentinel
/// is deleted, model text otherwise unchanged, caret to field 0.
void _softBackspaceAtStart(EditableTextState field) {
  final v = field.textEditingValue;
  field.updateEditingValue(
    TextEditingValue(
      text: v.text.substring(1),
      selection: const TextSelection.collapsed(offset: 0),
    ),
  );
}

void main() {
  testWidgets('soft-keyboard backspace merges a non-empty paragraph up', (
    t,
  ) async {
    final c = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(id: 'p1', text: AttributedText('one')),
          TextNode(id: 'p2', text: AttributedText('two')),
        ],
      ),
    );
    final field = await _pumpFocusStart(t, c, 1);
    _softBackspaceAtStart(field);
    await t.pumpAndSettle();
    expect(_texts(c), ['onetwo']);
  });

  testWidgets(
    'soft-keyboard backspace on an empty paragraph deletes the image above',
    (t) async {
      final c = QuireEditorController(
        document: MutableDocument(
          nodes: [
            ImageNode(id: 'img', url: '/tmp/x.png'),
            TextNode(id: 'p', text: AttributedText('')),
          ],
        ),
      );
      // The text field is the only EditableText (index 0).
      final field = await _pumpFocusStart(t, c, 0);
      _softBackspaceAtStart(field);
      await t.pumpAndSettle();
      expect(c.document.getNodeById('img'), isNull);
    },
  );

  testWidgets('typing after the sentinel produces clean model text, no ZWSP', (
    t,
  ) async {
    final c = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'p', text: AttributedText(''))],
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireEditor(controller: c)),
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(EditableText).at(0), 'hello');
    await t.pumpAndSettle();
    // Exact equality is the sentinel check: a leaked sentinel would show up
    // as a leading space here. (A `contains` over the JSON can't do that job
    // any more — the sentinel is an ordinary space now.)
    expect((c.document.getNodeById('p')! as TextNode).text.text, 'hello');
  });

  testWidgets('select-all then delete empties the node, does not merge', (
    t,
  ) async {
    final c = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(id: 'p1', text: AttributedText('one')),
          TextNode(id: 'p2', text: AttributedText('two')),
        ],
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireEditor(controller: c)),
      ),
    );
    await t.pumpAndSettle();
    // Clear the whole field (sentinel included) — a full delete, not a merge.
    final field = t.state<EditableTextState>(find.byType(EditableText).at(1));
    field.userUpdateTextEditingValue(
      const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      ),
      SelectionChangedCause.keyboard,
    );
    await t.pumpAndSettle();
    expect(c.document.getNodeById('p2'), isNotNull);
    expect((c.document.getNodeById('p2')! as TextNode).text.text, '');
  });
}
