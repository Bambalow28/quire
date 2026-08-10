import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  test(
    'deleteEmojiBefore removes the whole emoji grapheme, not one code unit',
    () {
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
      controller.insertEmoji('😀');

      final node = controller.document.getNodeById('a')! as TextNode;
      expect(node.text.text, 'hi 😀');
      expect(controller.isEmojiBefore('a', node.text.text.length), isTrue);

      controller.deleteEmojiBefore('a', node.text.text.length);

      final after = controller.document.getNodeById('a')! as TextNode;
      expect(after.text.text, 'hi ');
    },
  );

  testWidgets(
    'a field selection landing mid-emoji (as a tap can, via raw hit-testing) '
    'snaps to the nearer edge instead of splitting its surrogate pair',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('Hi 😀'))],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuireEditor(controller: controller)),
        ),
      );
      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();

      // Model text "Hi 😀": H=0 i=1 ' '=2 😀=3..5. Field offsets add 1 for
      // the leading sentinel (see quire_editor.dart's `_toField`/`_toModel`).
      final fieldController = tester
          .widget<EditableText>(find.byType(EditableText).first)
          .controller;

      fieldController.selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();
      expect(
        controller.composer.selection,
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(3)),
        ),
        reason: 'field offset 5 (model 4, mid-emoji) snaps to the near edge',
      );

      fieldController.selection = const TextSelection.collapsed(offset: 6);
      await tester.pump();
      expect(
        controller.composer.selection,
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(5)),
        ),
        reason: 'field offset 6 (model 5, also mid-emoji) snaps the other way',
      );
    },
  );

  testWidgets(
    'backspacing right after a picked emoji removes the whole emoji, even '
    'when the caret got there via a tap instead of typing',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText(''))],
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

      await tester.enterText(find.byType(EditableText).first, 'Hi ');
      await tester.pump();

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Emoji').first);
      await tester.pumpAndSettle();

      final picker = tester.widget<EmojiPicker>(find.byType(EmojiPicker));
      picker.onEmojiSelected!(null, const Emoji('😀', 'grinning face'));
      await tester.pump();

      // The panel stays open after picking (see insertEmoji's doc comment),
      // so tapping back into the field is how focus normally returns.
      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      final fieldController = tester
          .widget<EditableText>(find.byType(EditableText).first)
          .controller;
      fieldController.selection = const TextSelection.collapsed(offset: 6);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      final node = controller.document.getNodeById('a')! as TextNode;
      expect(node.text.text, 'Hi ');
    },
  );

  testWidgets(
    'a soft-keyboard delete that only removes half the emoji (a lone '
    'surrogate left behind) still clears the whole emoji',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('Hi 😀'))],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuireEditor(controller: controller)),
        ),
      );
      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();

      // Field text is the sentinel + "Hi 😀" (see quire_editor.dart's
      // `_fieldTextFor`). Simulate the platform's own soft-keyboard delete
      // clipping only the emoji's trailing low surrogate — as observed on a
      // real device — rather than the whole 2-unit character, leaving a
      // dangling high surrogate the model must still recover from.
      final fieldController = tester
          .widget<EditableText>(find.byType(EditableText).first)
          .controller;
      final fieldText = fieldController.text;
      final partiallyDeleted = fieldText.substring(0, fieldText.length - 1);
      fieldController.value = TextEditingValue(
        text: partiallyDeleted,
        selection: TextSelection.collapsed(offset: partiallyDeleted.length),
      );
      await tester.pump();

      final node = controller.document.getNodeById('a')! as TextNode;
      expect(node.text.text, 'Hi ');
    },
  );

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
