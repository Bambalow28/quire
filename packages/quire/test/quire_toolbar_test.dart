import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  testWidgets('the image button is absent when onPickImage is null', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireToolbar(controller: controller)),
      ),
    );

    expect(find.byIcon(Icons.image_outlined), findsNothing);
  });

  testWidgets(
    'the image button inserts a node when onPickImage returns a path',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
        ),
      );
      controller.focusNode('a');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuireToolbar(
              controller: controller,
              onPickImage: () async => '/tmp/picked.png',
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.image_outlined));
      await tester.pumpAndSettle();

      final inserted = controller.document.nodes
          .whereType<ImageNode>()
          .toList();
      expect(inserted, hasLength(1));
      expect(inserted.first.url, '/tmp/picked.png');
    },
  );

  testWidgets('the strikethrough button toggles the attribution', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
      ),
    );
    controller.composer.selection = DocumentSelection(
      base: DocumentPosition('a', const TextNodePosition(0)),
      extent: DocumentPosition('a', const TextNodePosition(5)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireToolbar(controller: controller)),
      ),
    );

    await tester.tap(find.byIcon(Icons.strikethrough_s));
    await tester.pump();

    final text = (controller.document.getNodeById('a') as TextNode).text;
    expect(
      text.hasAttributionThroughout(const Attribution('strikethrough'), 0, 5),
      isTrue,
    );
  });
}
