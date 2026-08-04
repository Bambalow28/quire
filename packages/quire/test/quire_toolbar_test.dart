import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  /// Everything but bold/italic/underline and text size now lives behind the
  /// bar's `+` button, so these tests open that panel first.
  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
  }

  /// The panel scrolls, so a row may be off-screen when it is tapped.
  Future<void> tapOption(WidgetTester tester, IconData icon) async {
    await tester.scrollUntilVisible(find.byIcon(icon), 100);
    // scrollUntilVisible stops at the edge, where the card's clip can still
    // cover the row — this brings it fully inside.
    await tester.ensureVisible(find.byIcon(icon));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(icon));
    await tester.pumpAndSettle();
  }

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

    await openPanel(tester);

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

      await openPanel(tester);
      await tapOption(tester, Icons.image_outlined);

      final inserted = controller.document.nodes
          .whereType<ImageNode>()
          .toList();
      expect(inserted, hasLength(1));
      expect(inserted.first.url, '/tmp/picked.png');
    },
  );

  /// Pressing a lit block button reverts to a plain paragraph, so every one
  /// of them is its own off switch.
  for (final (icon, blockType) in const [
    (Icons.format_list_bulleted, 'listItemUnordered'),
    (Icons.format_list_numbered, 'listItemOrdered'),
    (Icons.checklist, 'listItemTask'),
  ]) {
    testWidgets('$blockType applies on first press and reverts on second', (
      tester,
    ) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
        ),
      );
      controller.focusNode('a');
      controller.composer.selection = DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(0)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuireToolbar(controller: controller)),
        ),
      );
      TextNode node() => controller.document.getNodeById('a') as TextNode;

      await openPanel(tester);
      await tapOption(tester, icon);
      expect(node().blockType, blockType);

      await tapOption(tester, icon);
      expect(node().blockType, 'paragraph');
    });
  }

  testWidgets('alignment buttons apply and reflect the focused node', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
      ),
    );
    controller.focusNode('a');
    controller.composer.selection = DocumentSelection.collapsed(
      DocumentPosition('a', const TextNodePosition(0)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireToolbar(controller: controller)),
      ),
    );
    TextNode node() => controller.document.getNodeById('a') as TextNode;

    await openPanel(tester);
    expect(node().textAlign, 'left');

    await tapOption(tester, Icons.format_align_center);
    expect(node().textAlign, 'center');

    await tapOption(tester, Icons.format_align_right);
    expect(node().textAlign, 'right');

    await tapOption(tester, Icons.format_align_justify);
    expect(node().textAlign, 'justify');

    // The IconButton's own `isSelected` (not a checkmark, like `_OptionRow`)
    // is what shows the active alignment here.
    final justifyButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.format_align_justify),
    );
    expect(justifyButton.isSelected, isTrue);
  });

  testWidgets('line spacing steps up and down and stops at the ends', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
      ),
    );
    controller.focusNode('a');
    controller.composer.selection = DocumentSelection.collapsed(
      DocumentPosition('a', const TextNodePosition(0)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireToolbar(controller: controller)),
      ),
    );
    TextNode node() => controller.document.getNodeById('a') as TextNode;

    await openPanel(tester);
    expect(node().lineSpacing, 1.15); // default is the first increase

    await tapOption(tester, Icons.unfold_less);
    expect(node().lineSpacing, 1.0);
    // Already at the bottom step — decreasing further is a no-op.
    await tapOption(tester, Icons.unfold_less);
    expect(node().lineSpacing, 1.0);

    await tapOption(tester, Icons.unfold_more);
    expect(node().lineSpacing, 1.15);
    await tapOption(tester, Icons.unfold_more);
    expect(node().lineSpacing, 1.5);
    await tapOption(tester, Icons.unfold_more);
    expect(node().lineSpacing, 2.0);
    // Already at the top step — increasing further is a no-op.
    await tapOption(tester, Icons.unfold_more);
    expect(node().lineSpacing, 2.0);

    await tapOption(tester, Icons.unfold_less);
    expect(node().lineSpacing, 1.5);
  });

  testWidgets('reverting a checklist item drops its checked state', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('hello'),
            metadata: const {'blockType': 'listItemTask', 'checked': true},
          ),
        ],
      ),
    );
    controller.focusNode('a');
    controller.composer.selection = DocumentSelection.collapsed(
      DocumentPosition('a', const TextNodePosition(0)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireToolbar(controller: controller)),
      ),
    );
    TextNode node() => controller.document.getNodeById('a') as TextNode;

    await openPanel(tester);
    await tapOption(tester, Icons.checklist);
    expect(node().blockType, 'paragraph');

    // Back to a task item: unchecked, not carrying the old tick.
    await tapOption(tester, Icons.checklist);
    expect(node().blockType, 'listItemTask');
    expect(node().isChecked, isFalse);
  });

  testWidgets('the image button inserts again, never toggles off', (
    tester,
  ) async {
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

    await openPanel(tester);
    for (var i = 0; i < 2; i++) {
      await tapOption(tester, Icons.image_outlined);
    }
    expect(controller.document.nodes.whereType<ImageNode>(), hasLength(2));
  });

  testWidgets('the table button inserts again, never toggles off', (
    tester,
  ) async {
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

    await openPanel(tester);
    for (var i = 0; i < 2; i++) {
      await tapOption(tester, Icons.table_chart_outlined);
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
    }
    expect(controller.document.nodes.whereType<TableNode>(), hasLength(2));
  });

  group('text size menu', () {
    Future<QuireEditorController> pumpWithCaret(WidgetTester tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
        ),
      );
      controller.focusNode('a');
      controller.composer.selection = DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(0)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuireToolbar(controller: controller)),
        ),
      );
      return controller;
    }

    testWidgets('shows the caret block size and applies the picked one', (
      tester,
    ) async {
      final controller = await pumpWithCaret(tester);
      // Body is the resting state, and its size is what the pill reports.
      expect(find.text('16'), findsOneWidget);

      await tester.tap(find.text('16'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Title'));
      await tester.pumpAndSettle();

      final node = controller.document.getNodeById('a') as TextNode;
      expect(node.blockType, 'header1');
      expect(find.text('32'), findsOneWidget);
    });

    testWidgets('reaches header3, which no toolbar button ever did', (
      tester,
    ) async {
      final controller = await pumpWithCaret(tester);

      await tester.tap(find.text('16'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Subheading'));
      await tester.pumpAndSettle();

      expect(
        (controller.document.getNodeById('a') as TextNode).blockType,
        'header3',
      );
    });

    testWidgets('picking the active size again leaves it alone', (
      tester,
    ) async {
      final controller = await pumpWithCaret(tester);
      controller.applyBlockType('header1');
      await tester.pump();

      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text('32'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Title'));
        await tester.pumpAndSettle();
      }

      // Unlike the list buttons, a menu pick names a state — it never
      // toggles back to Body.
      expect(
        (controller.document.getNodeById('a') as TextNode).blockType,
        'header1',
      );
    });

    testWidgets('opening the menu does not drop the keyboard', (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
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
      final editorFocus = FocusManager.instance.primaryFocus!;
      expect(editorFocus.hasFocus, isTrue);

      await tester.tap(find.text('16'));
      await tester.pumpAndSettle();

      // The menu route takes primary focus only if it asks for it — this one
      // shouldn't have, so the editor's field is still the one that has it.
      expect(editorFocus.hasFocus, isTrue);
    });

    testWidgets(
      'the custom size row nudges the pill by 1pt in place, without closing '
      'the menu, and sets an explicit fontSize attribution',
      (tester) async {
        final controller = await pumpWithCaret(tester);

        await tester.tap(find.text('16'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('customSizeIncrement')));
        await tester.pumpAndSettle();

        // The menu is still open — both the toolbar pill and the row's own
        // number now read the new value, and the +/- buttons are still
        // there to keep nudging. Before the fix, the increment handler
        // popped the menu, so only one "17" (the pill) would remain and
        // customSizeDecrement would already be gone.
        expect(find.text('17'), findsNWidgets(2));
        expect(find.byKey(const Key('customSizeDecrement')), findsOneWidget);
        expect(
          controller.composer.composingAttributions,
          contains(const Attribution('fontSize', value: {'size': 17.0})),
        );

        // Keep nudging without ever reopening the menu.
        await tester.tap(find.byKey(const Key('customSizeIncrement')));
        await tester.pumpAndSettle();
        expect(find.text('18'), findsNWidgets(2));

        await tester.tap(find.byKey(const Key('customSizeDecrement')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('customSizeDecrement')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('customSizeDecrement')));
        await tester.pumpAndSettle();

        // Menu is still open at the end of all this.
        expect(find.text('15'), findsNWidgets(2));
        expect(find.byKey(const Key('customSizeIncrement')), findsOneWidget);
      },
    );

    testWidgets(
      'picking a named step still closes the menu, leaving one pill behind',
      (tester) async {
        final controller = await pumpWithCaret(tester);

        await tester.tap(find.text('16'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('customSizeIncrement')));
        await tester.pumpAndSettle();
        expect(find.text('17'), findsNWidgets(2));

        await tester.tap(find.text('Title'));
        await tester.pumpAndSettle();

        expect(
          (controller.document.getNodeById('a') as TextNode).blockType,
          'header1',
        );
        // The menu is gone now — only the pill remains. The composing
        // fontSize attribution (a collapsed-selection thing) outlives the
        // block-type change, so the pill still reads the explicit 17
        // rather than header1's own 32 — the custom row and its
        // customSizeIncrement key are gone with the menu, which is the
        // part this test is actually checking.
        expect(find.text('17'), findsOneWidget);
        expect(find.byKey(const Key('customSizeIncrement')), findsNothing);
      },
    );

    testWidgets('the custom size dialog applies an exact typed value', (
      tester,
    ) async {
      final controller = await pumpWithCaret(tester);

      await tester.tap(find.text('16'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('customSizeValue')));
      await tester.pumpAndSettle();

      // The dialog opened on top of the still-open menu, not instead of it.
      await tester.enterText(find.byType(TextField), '48');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // Menu still open behind the (now-closed) dialog: pill + row both '48'.
      expect(find.text('48'), findsNWidgets(2));
      expect(
        controller.composer.composingAttributions,
        contains(const Attribution('fontSize', value: {'size': 48.0})),
      );
    });

    testWidgets('the custom size dialog clamps outside the 8-72 range', (
      tester,
    ) async {
      final controller = await pumpWithCaret(tester);

      await tester.tap(find.text('16'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('customSizeValue')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '999');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.text('72'), findsNWidgets(2));
      expect(
        controller.composer.composingAttributions,
        contains(const Attribution('fontSize', value: {'size': 72.0})),
      );
    });

    testWidgets(
      'the checkmark moves to Custom when an explicit size is active, and '
      'off every named step',
      (tester) async {
        await pumpWithCaret(tester);

        await tester.tap(find.text('16'));
        await tester.pumpAndSettle();

        // Resting state: Body (the current block) is checked, Custom is not.
        expect(
          find.descendant(
            of: find.widgetWithText(PopupMenuItem<String>, 'Custom'),
            matching: find.byIcon(Icons.check),
          ),
          findsNothing,
        );

        await tester.tap(find.byKey(const Key('customSizeIncrement')));
        await tester.pumpAndSettle();

        // Custom is now checked...
        expect(
          find.descendant(
            of: find.widgetWithText(PopupMenuItem<String>, 'Custom'),
            matching: find.byIcon(Icons.check),
          ),
          findsOneWidget,
        );
        // ...and exactly one row is checked overall (the four named steps
        // plus Custom): no double-tick, no orphaned tick left on Body.
        expect(find.byIcon(Icons.check), findsOneWidget);
      },
    );

    testWidgets(
      'a mixed-size selection degrades to the block default rather than '
      'crashing or picking one side',
      (tester) async {
        final controller = QuireEditorController(
          document: MutableDocument(
            nodes: [
              TextNode(
                id: 'a',
                text: AttributedText('hello world', [
                  const AttributionSpan(
                    Attribution('fontSize', value: {'size': 20.0}),
                    0,
                    5,
                  ),
                  const AttributionSpan(
                    Attribution('fontSize', value: {'size': 40.0}),
                    5,
                    11,
                  ),
                ]),
              ),
            ],
          ),
        );
        controller.focusNode('a');
        controller.composer.selection = const DocumentSelection(
          base: DocumentPosition('a', TextNodePosition(0)),
          extent: DocumentPosition('a', TextNodePosition(11)),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: QuireToolbar(controller: controller)),
          ),
        );

        expect(tester.takeException(), isNull);
        // Neither of the two explicit sizes wins — the pill falls back to
        // the block type's own default (Body = 16).
        expect(find.text('16'), findsOneWidget);
      },
    );

    testWidgets(
      'with the keyboard up, the menu opens above the button instead of '
      'behind it',
      (tester) async {
        // showMenu lays out against the full (un-inset) screen — a keyboard
        // this tall used to leave nowhere for a menu opening "under" the
        // button to actually render. The toolbar needs to actually sit at
        // the bottom (as it does in a real host) for that to bite, hence the
        // Expanded space above it rather than pumpWithCaret's bare Scaffold.
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.reset);

        final controller = QuireEditorController(
          document: MutableDocument(
            nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
          ),
        );
        controller.focusNode('a');
        controller.composer.selection = DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(0)),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const Expanded(child: SizedBox()),
                  QuireToolbar(controller: controller),
                ],
              ),
            ),
          ),
        );

        final buttonTop = tester.getTopLeft(find.text('16')).dy;
        await tester.tap(find.text('16'));
        await tester.pumpAndSettle();

        // Every item sits above the button that opened them, not below —
        // "under" would put them in the keyboard's own sliver of screen.
        for (final label in ['Title', 'Heading', 'Subheading', 'Body']) {
          expect(
            tester.getBottomLeft(find.text(label)).dy,
            lessThan(buttonTop),
          );
        }

        await tester.tap(find.text('Title'));
        await tester.pumpAndSettle();
        expect(
          (controller.document.getNodeById('a') as TextNode).blockType,
          'header1',
        );
      },
    );
  });

  testWidgets('the bar fits a narrow phone without scrolling sideways', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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

    // An overflowing Row throws during paint; getting here means it fit.
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsNothing);
  });

  testWidgets('the + button swaps the keyboard for the labelled options', (
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

    expect(find.text('Bullet list'), findsNothing);

    await openPanel(tester);
    expect(find.text('Bullet list'), findsOneWidget);

    // Pressing it again puts the keyboard back.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Bullet list'), findsNothing);
  });

  testWidgets('the panel takes exactly the height the keyboard gives up', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);

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

    double panelHeight() => tester
        .getSize(
          find
              .ancestor(
                of: find.byType(ListView),
                matching: find.byType(SizedBox),
              )
              .first,
        )
        .height;

    // Opening with the keyboard still up: nothing yet, so the bar holds still.
    await openPanel(tester);
    expect(panelHeight(), 0);

    // Keyboard half gone, then fully gone — the panel makes up the difference.
    tester.view.viewInsets = const FakeViewPadding(bottom: 150);
    await tester.pumpAndSettle();
    expect(panelHeight(), 150);

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(panelHeight(), 300);

    // The keyboard coming back (something took focus) closes the panel.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(find.text('Bullet list'), findsNothing);
  });

  testWidgets('closing the panel refocuses a host field, not just the editor', (
    tester,
  ) async {
    // The toolbar has no editor node focused (nothing was ever typed in),
    // only a host TextField — a note's title, say — the way it would be
    // the first time a toolbar is opened on a note whose title isn't
    // autofocused.
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
      ),
    );
    final titleFocus = FocusNode();
    addTearDown(titleFocus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(focusNode: titleFocus),
              QuireToolbar(controller: controller),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(titleFocus.hasFocus, isTrue);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(titleFocus.hasFocus, isFalse);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(titleFocus.hasFocus, isTrue);
  });

  testWidgets('the button flips to + the instant close is pressed', (
    tester,
  ) async {
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
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    // One frame only — the keyboard hasn't started rising back yet, so the
    // panel is still full height, but the button should already read +.
    await tester.pump();
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.text('Bullet list'), findsOneWidget);
  });
}
