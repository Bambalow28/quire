import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  testWidgets(
    'the Emoji option opens a picker; picking one inserts it at the caret',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hi '))],
        ),
      );
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(3)),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(child: QuireEditor(controller: controller)),
                QuireToolbar(controller: controller),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Emoji').first);
      await tester.pumpAndSettle();

      final picker = tester.widget<EmojiPicker>(find.byType(EmojiPicker));
      picker.onEmojiSelected!(null, const Emoji('😀', 'grinning face'));

      final node = controller.document.getNodeById('a')! as TextNode;
      expect(node.text.text, 'hi 😀');
    },
  );

  testWidgets('picking an emoji tags it with a largeEmoji attribution', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(0)),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: QuireEditor(controller: controller)),
              QuireToolbar(controller: controller),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Emoji').first);
    await tester.pumpAndSettle();

    final picker = tester.widget<EmojiPicker>(find.byType(EmojiPicker));
    picker.onEmojiSelected!(null, const Emoji('😀', 'grinning face'));

    final node = controller.document.getNodeById('a')! as TextNode;
    expect(
      node.text.hasAttributionThroughout(
        const Attribution('largeEmoji'),
        0,
        node.text.text.length,
      ),
      isTrue,
    );
  });

  testWidgets(
    'pressing the emoji panel\'s close button returns to the keyboard, not the options list',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.reset);

      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
        ),
      );
      controller.focusNode('a');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuireToolbar(controller: controller)),
        ),
      );

      await tester.tap(find.byIcon(Icons.add));
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Emoji').first);
      await tester.pumpAndSettle();
      expect(find.byType(EmojiPicker), findsOneWidget);

      await tester.tap(find.byTooltip('Close emoji picker'));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();

      // Closed all the way — no options list and no emoji picker left
      // behind, the keyboard slot is what's showing again.
      expect(find.byType(EmojiPicker), findsNothing);
      expect(find.text('Bullet list'), findsNothing);
    },
  );
}
