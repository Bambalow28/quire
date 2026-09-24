import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ime.dart';

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
    'a selection-only delta landing mid-emoji (as a tap can, via raw '
    'hit-testing) snaps forward, past the emoji, instead of splitting its '
    'surrogate pair',
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
      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();

      // Model text "Hi 😀": H=0 i=1 ' '=2 😀=3..5. IME/field offsets add 1
      // for the leading sentinel (see document_input_client.dart).
      await moveSelection(tester, const TextSelection.collapsed(offset: 5));
      expect(
        controller.composer.selection,
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(5)),
        ),
        reason:
            'field offset 5 (model 4, mid-emoji) is how a real iOS field '
            'reports "after the emoji" — even for a tap well past the end of '
            'the line, which never reports the full-length offset 6 — so it '
            'snaps forward, past the emoji, not back in front of it',
      );

      await moveSelection(tester, const TextSelection.collapsed(offset: 6));
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
    'a soft-keyboard backspace after the caret lands mid-emoji removes the '
    'emoji, not the space in front of it',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'a',
              text: AttributedText('hi 😀', [
                const AttributionSpan(Attribution('largeEmoji'), 3, 5),
              ]),
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuireEditor(controller: controller)),
        ),
      );
      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();

      // What a real iOS field reports for a tap anywhere past the end of the
      // line: field offset 5 — between the emoji's two surrogates — never
      // the full-length 6.
      await moveSelection(tester, const TextSelection.collapsed(offset: 5));

      await backspace(tester);
      await tester.pump();

      final node = controller.document.getNodeById('a')! as TextNode;
      expect(node.text.text, 'hi ');
    },
  );

  testWidgets(
    'backspacing right after a picked emoji removes the whole emoji',
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

      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      await typeText(tester, 'Hi ');

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
      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();

      await backspace(tester);
      await tester.pump();

      final node = controller.document.getNodeById('a')! as TextNode;
      expect(node.text.text, 'Hi ');
    },
  );

  testWidgets('a soft-keyboard delete that only removes half the emoji (a lone '
      'surrogate left behind) still clears the whole emoji', (tester) async {
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
    await tester.tap(findNode('a'));
    await tester.pumpAndSettle();

    // A real device has been observed to report the platform's own
    // soft-keyboard delete as clipping only the emoji's trailing low
    // surrogate — one UTF-16 code unit — rather than the whole 2-unit
    // character; `backspace()` sends exactly that (one code unit back from
    // the caret), and `document_input_client.dart`'s grapheme expansion
    // must still recover the whole emoji from it.
    await backspace(tester);
    await tester.pump();

    final node = controller.document.getNodeById('a')! as TextNode;
    expect(node.text.text, 'Hi ');
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

  testWidgets(
    'the emoji panel\'s own Backspace button removes the just-picked emoji '
    '— it replaces the keyboard while open, so there is no other backspace '
    'to press',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.reset);
      // The picker's recent-emoji lookup goes through the shared_preferences
      // plugin channel — unmocked, that Future never resolves, so the panel
      // stays stuck on its loading indicator forever and the Backspace
      // button never appears.
      SharedPreferences.setMockInitialValues({});

      // The emoji ("😀", 2 UTF-16 code units) already carries the same
      // 'largeEmoji' attribution `insertEmoji` would give it — set up this
      // way, rather than picking it through the panel mid-test, so the
      // picker's `Config` (rebuilt fresh on every parent rebuild — see
      // `_emojiPickerConfig`) stays referentially stable once built. A
      // changed `Config` makes `EmojiPickerState.didUpdateWidget` drop
      // `_loaded` and reload its emoji data asynchronously, which the
      // widget-test pump loop has no reliable way to wait out.
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'a',
              text: AttributedText('hi 😀', [
                const AttributionSpan(Attribution('largeEmoji'), 3, 5),
              ]),
            ),
          ],
        ),
      );
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(5)),
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

      await tester.tap(find.byTooltip('Backspace'));
      await tester.pump();

      final node = controller.document.getNodeById('a')! as TextNode;
      expect(node.text.text, 'hi ');
    },
  );

  testWidgets(
    'inserting an emoji from the panel leaves a caret overlay where the '
    'next insert will land, since the panel deliberately keeps real focus '
    'away',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('Hi '))],
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

      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Emoji').first);
      await tester.pumpAndSettle();

      final picker = tester.widget<EmojiPicker>(find.byType(EmojiPicker));
      picker.onEmojiSelected!(null, const Emoji('😀', 'grinning face'));
      await tester.pump();
      // Nothing paints on this very first pump — not even at the stale
      // (pre-insert) position `_caretRectAt` would compute if read straight
      // from the render object here. Painting that stale rect immediately,
      // then correcting it once layout catches up, is exactly the visible
      // "appears before the emoji, jumps to after it" bug this guards
      // against; see `_scheduleCaretMeasurement`'s doc comment.
      expect(
        find.byKey(const ValueKey('quire-caret')),
        findsNothing,
        reason:
            'the rect is deferred to a post-frame measurement, not painted '
            'from this frame\'s (still stale) layout geometry',
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('quire-caret')),
        findsOneWidget,
        reason:
            'no field has real focus once the panel is open, so nothing '
            'shows where the next insert will land without this',
      );
    },
  );

  testWidgets(
    'backspace still removes the whole emoji after the panel closes and '
    'reopens, not just while it stays open',
    (tester) async {
      // Desktop: closing the panel hands focus back immediately via
      // `requestFocus` (no software keyboard to animate back up first), and
      // exercises the physical-key backspace path (see the `isDesktop`
      // branch in quire_editor.dart's `_shortcutBindings`).
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      // Pre-populated with the same 'largeEmoji' attribution `insertEmoji`
      // gives it (see the "own Backspace button" test above for why this
      // sidesteps the emoji picker's own async reload).
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'a',
              text: AttributedText('hi 😀', [
                const AttributionSpan(Attribution('largeEmoji'), 3, 5),
              ]),
            ),
          ],
        ),
      );
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(5)),
        ),
      );
      controller.focusNode('a');
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

      // Open the panel (drops real focus) then close it (hands real focus
      // back via `QuireEditorController.requestFocus`, not a tap) — the
      // exact transition the original bug report described as breaking
      // backspace, as opposed to leaving the panel open the whole time.
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      final node = controller.document.getNodeById('a')! as TextNode;
      expect(node.text.text, 'hi ');

      debugDefaultTargetPlatformOverride = null;
    },
  );
}
