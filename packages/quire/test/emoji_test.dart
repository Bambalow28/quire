import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    'snaps forward, past the emoji, instead of splitting its surrogate pair',
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
          DocumentPosition('a', const TextNodePosition(5)),
        ),
        reason:
            'field offset 5 (model 4, mid-emoji) is how a real iOS field '
            'reports "after the emoji" — even for a tap well past the end of '
            'the line, which never reports the full-length offset 6 — so it '
            'snaps forward, past the emoji, not back in front of it',
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
    'a soft-keyboard backspace after tapping past the end of a line that '
    'ends in an emoji removes the emoji, not the space in front of it',
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
      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();

      // What a real iOS field reports for a tap anywhere past the end of the
      // line: field offset 5 — between the emoji's two surrogates — never the
      // full-length 6.
      tester
          .widget<EditableText>(find.byType(EditableText).first)
          .controller
          .selection = const TextSelection.collapsed(
        offset: 5,
      );
      await tester.pump();

      // The soft keyboard deletes from ITS copy of the text, at ITS caret.
      final platform = tester.testTextInput.editingState!;
      final text = platform['text'] as String;
      final caret = platform['selectionBase'] as int;
      final deleted = text.substring(0, caret - 1) + text.substring(caret);
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: deleted,
          selection: TextSelection.collapsed(offset: caret - 1),
        ),
      );
      await tester.pump();

      final node = controller.document.getNodeById('a')! as TextNode;
      expect(node.text.text, 'hi ');
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
      final fieldController = tester
          .widget<EditableText>(find.byType(EditableText).first)
          .controller;

      // No pump between the tap and the injected race below: quire's own
      // `_placeCaret` already ran synchronously as part of dispatching the
      // pointer-up event, and its correction (see the pointer-up handler's
      // plain-tap branch in quire_editor.dart) is scheduled for the *next*
      // frame — this is the window where EditableText's own internal tap
      // recognizer, which resolves the gesture arena asynchronously rather
      // than synchronously with quire's, can still race in and overwrite
      // the field's local selection with its own (potentially mid-emoji)
      // offset.
      await tester.tap(find.byType(EditableText).first);
      final resolved = fieldController.selection;

      // Simulate that race: EditableText's own recognizer landing a raw,
      // un-snapped offset that splits the emoji's surrogate pair. Left
      // uncorrected, a Backspace right after this would only remove half
      // the emoji instead of the whole thing.
      fieldController.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();

      // The scheduled re-snap should have corrected the race back to
      // exactly what quire's own tap handling resolved, before Backspace is
      // ever pressed.
      expect(fieldController.selection, resolved);

      // Whatever the tap actually resolved to, move it explicitly to right
      // after the emoji — this asserts the *outcome* Backspace should
      // produce from there, independent of exactly where a default tap on
      // this render box happens to land.
      final endOffset = fieldController.text.length;
      fieldController.selection = TextSelection.collapsed(offset: endOffset);
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('a', TextNodePosition(endOffset - 1)),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
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
    'inserting an emoji from the panel leaves a ghost caret where the next '
    'insert will land, since the panel deliberately keeps real focus away',
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

      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('quire-ghost-caret')),
        findsNothing,
        reason:
            'the native cursor is already showing while the field has real focus',
      );

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
      // from `RenderEditable` here. Painting that stale rect immediately,
      // then correcting it once layout catches up, is exactly the visible
      // "appears before the emoji, jumps to after it" bug this guards
      // against; see `_scheduleGhostCaretMeasurement`'s doc comment.
      expect(
        find.byKey(const ValueKey('quire-ghost-caret')),
        findsNothing,
        reason:
            'the rect is deferred to a post-frame measurement, not painted '
            'from this frame\'s (still stale) RenderEditable geometry',
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('quire-ghost-caret')),
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
      // `requestFocus` (no software keyboard to animate back up first) —
      // the same `requestFocus`-driven path a real device takes, without
      // this test needing to fake a keyboard-rise animation to get there.
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
      // exact transition the bug report described as breaking backspace,
      // as opposed to leaving the panel open the whole time.
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.close));
      // One pump: `_maybeRequestFocus` grants real focus and schedules its
      // own re-sync for the *next* frame.
      await tester.pump();

      // Simulate the race `_maybeRequestFocus`'s post-frame re-sync exists
      // to correct: on a real device, gaining real focus here runs through
      // EditableText's own internal focus-change handling and/or a platform
      // IME echo, either of which can overwrite the field's local selection
      // with something that has no idea where the model's grapheme-safe
      // caret actually is — a plain widget test's synthetic focus grant
      // doesn't reproduce that echo on its own, so it's injected directly.
      final fieldController = tester
          .widget<EditableText>(find.byType(EditableText).first)
          .controller;
      fieldController.selection = TextSelection.collapsed(
        offset: fieldController.text.length - 1,
      );
      // The scheduled re-sync should correct this back before Backspace is
      // ever pressed.
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      final node = controller.document.getNodeById('a')! as TextNode;
      expect(node.text.text, 'hi ');

      debugDefaultTargetPlatformOverride = null;
    },
  );
}
