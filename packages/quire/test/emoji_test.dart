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
}
