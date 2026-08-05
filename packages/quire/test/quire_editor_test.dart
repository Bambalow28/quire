import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

Future<void> _pumpEditor(
  WidgetTester tester,
  QuireEditorController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: QuireEditor(controller: controller)),
    ),
  );
}

void main() {
  testWidgets('typing into a paragraph updates the model\'s AttributedText', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'hello world');
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      'hello world',
    );
  });

  testWidgets('pressing Enter splits into two nodes and moves focus', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(5)),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.document.nodes.length, 2);
    final first = controller.document.getNodeAt(0) as TextNode;
    final second = controller.document.getNodeAt(1) as TextNode;
    expect(first.text.text, 'hello');
    expect(second.text.text, ' world');
    expect(controller.focusedNodeId, second.id);
    expect(
      controller.composer.selection,
      DocumentSelection.collapsed(
        DocumentPosition(second.id, const TextNodePosition(0)),
      ),
    );
  });

  testWidgets(
    'backspace at offset 0 merges back into one node with the text intact',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('hello ')),
            TextNode(id: 'b', text: AttributedText('world')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(find.byType(EditableText).at(1));
      await tester.pumpAndSettle();
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('b', const TextNodePosition(0)),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      expect(
        (controller.document.getNodeById('a') as TextNode).text.text,
        'hello world',
      );
      expect(controller.document.getNodeById('b'), isNull);
    },
  );

  testWidgets(
    'a "\\n" arriving through the controller splits the node (soft-keyboard Enter)',
    (tester) async {
      // A soft keyboard's Return key never emits a key event — it lands as
      // a literal "\n" inside the field's text, exactly like `enterText`
      // simulates here.
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).first, 'hello\n world');
      await tester.pump();

      expect(controller.document.nodes.length, 2);
      final first = controller.document.getNodeAt(0) as TextNode;
      final second = controller.document.getNodeAt(1) as TextNode;
      expect(first.text.text, 'hello');
      expect(second.text.text, ' world');
    },
  );

  testWidgets('typing over a bold selection keeps the replacement bold', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('hello world', [
              const AttributionSpan(Attribution('bold'), 0, 5),
            ]),
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition('a', const TextNodePosition(0)),
        extent: DocumentPosition('a', const TextNodePosition(5)),
      ),
    );
    await tester.pump();

    // Replace the bold "hello" with "howdy" in one shot (as `enterText`
    // does for the currently-focused field).
    await tester.enterText(find.byType(EditableText).first, 'howdy world');
    await tester.pump();

    final text = (controller.document.getNodeById('a') as TextNode).text;
    expect(text.text, 'howdy world');
    expect(
      text.hasAttributionThroughout(const Attribution('bold'), 0, 5),
      isTrue,
    );
  });

  testWidgets('toggling bold over a selection puts a bold span in the model', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition('a', const TextNodePosition(0)),
        extent: DocumentPosition('a', const TextNodePosition(5)),
      ),
    );
    await tester.pump();

    controller.toggleBold();
    await tester.pump();

    final text = (controller.document.getNodeById('a') as TextNode).text;
    expect(
      text.hasAttributionThroughout(const Attribution('bold'), 0, 5),
      isTrue,
    );
  });

  testWidgets('undo after a few edits restores the original document JSON', (
    tester,
  ) async {
    final doc = MutableDocument(
      nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
    );
    final originalJson = doc.toJson();
    final controller = QuireEditorController(document: doc);
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'hello world');
    await tester.pump();
    await tester.enterText(find.byType(EditableText).first, 'hello world!!');
    await tester.pump();

    controller.undo();
    controller.undo();
    await tester.pump();

    expect(controller.document.toJson(), originalJson);
  });

  testWidgets('tapping below the last node focuses it with the caret at end', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(id: 'a', text: AttributedText('hello')),
          TextNode(id: 'b', text: AttributedText('world')),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: QuireEditor(controller: controller),
          ),
        ),
      ),
    );

    // Tap far below where the two short text nodes render.
    await tester.tapAt(const Offset(200, 500));
    await tester.pump();

    expect(controller.focusedNodeId, 'b');
    expect(
      controller.composer.selection,
      DocumentSelection.collapsed(
        DocumentPosition('b', const TextNodePosition(5)),
      ),
    );
  });

  testWidgets('the placeholder shows on an empty document and hides once '
      'there is text', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuireEditor(
            controller: controller,
            placeholder: 'Start writing…',
          ),
        ),
      ),
    );

    expect(find.text('Start writing…'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).first, 'hi');
    await tester.pump();

    expect(find.text('Start writing…'), findsNothing);
  });

  testWidgets('the placeholder hides once the field is focused', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuireEditor(
            controller: controller,
            placeholder: 'Start writing…',
          ),
        ),
      ),
    );
    expect(find.text('Start writing…'), findsOneWidget);

    await tester.tap(find.byType(EditableText).first);
    await tester.pump();

    expect(find.text('Start writing…'), findsNothing);
  });

  testWidgets(
    'the placeholder does not show over an empty checklist item — it is '
    'content the user created, not an empty document',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'a',
              text: AttributedText(''),
              metadata: {'blockType': 'listItemTask'},
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuireEditor(
              controller: controller,
              placeholder: 'Start writing…',
            ),
          ),
        ),
      );

      expect(find.text('Start writing…'), findsNothing);
    },
  );

  testWidgets('a task item renders a checkbox and tapping toggles the model', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('buy milk'),
            metadata: {'blockType': 'listItemTask'},
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    expect(find.byType(Checkbox), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).isChecked,
      isTrue,
    );
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
  });

  testWidgets('tapping the checkbox does not steal focus from the text field', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('buy milk'),
            metadata: {'blockType': 'listItemTask'},
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    expect(controller.focusedNodeId, 'a');

    await tester.tap(find.byType(Checkbox));
    await tester.pump();

    expect(controller.focusedNodeId, 'a');
  });

  testWidgets('a checked task item renders struck through', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('buy milk'),
            metadata: {'blockType': 'listItemTask', 'checked': true},
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    final field = tester.widget<EditableText>(find.byType(EditableText).first);
    expect(field.style.decoration, TextDecoration.lineThrough);
  });

  testWidgets(
    'an ImageNode with a filesystem path builds an Image with a FileImage provider',
    (tester) async {
      // No real file is written to disk — the assertion is about which
      // ImageProvider the non-http branch picks, not decode/paint, so a
      // path that merely fails to parse as http(s) is enough.
      const path = '/Users/someone/Documents/notesync/images/photo.png';
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [ImageNode(id: 'img', url: path)],
        ),
      );
      await _pumpEditor(tester, controller);

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<FileImage>());
      expect((image.image as FileImage).file.path, path);
    },
  );

  testWidgets(
    'an ImageNode with a bad filesystem path shows the placeholder instead of throwing',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [ImageNode(id: 'img', url: '/no/such/file/quire_missing.png')],
        ),
      );
      // A real failed decode of a nonexistent file never settles inside the
      // sandboxed test runner (dart:io file reads don't resolve here), so
      // rather than waiting on that, drive the widget's own errorBuilder
      // directly — the same callback Flutter invokes on a real decode
      // failure — and assert it paints the placeholder instead of throwing.
      await _pumpEditor(tester, controller);
      final image = tester.widget<Image>(find.byType(Image));
      final placeholder = image.errorBuilder!(
        tester.element(find.byType(Image)),
        Exception('simulated decode failure'),
        null,
      );
      await tester.pumpWidget(MaterialApp(home: placeholder));

      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    },
  );

  // The fussy one. On an item that wraps, the checkbox must sit beside the
  // FIRST line — not centred against the whole paragraph — and its mark
  // must be centred on that line rather than hung from its top.
  testWidgets('the checkbox centres on the first line of a wrapped item', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: QuireEditor(
              controller: QuireEditorController(
                document: MutableDocument(
                  nodes: [
                    TextNode(
                      id: 'a',
                      text: AttributedText(
                        'a checklist item long enough to wrap onto '
                        'several separate lines in a narrow column',
                      ),
                      metadata: const {'blockType': 'listItemTask'},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final box = tester.getRect(find.byType(Checkbox));
    final field = tester.getRect(find.byType(EditableText));
    // Actually wrapping is the whole premise of this test.
    expect(field.height, greaterThan(box.height * 2));

    final renderEditable = tester.renderObject<RenderBox>(
      find.byType(EditableText),
    );
    final lineHeight = renderEditable.getMaxIntrinsicHeight(double.infinity);
    final firstLineCentre = field.top + lineHeight / 2;

    expect(
      box.center.dy,
      closeTo(firstLineCentre, 1.5),
      reason:
          'checkbox centre ${box.center.dy} vs first line '
          'centre $firstLineCentre',
    );
  });
}
