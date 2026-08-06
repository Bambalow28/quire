import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  // A test-only clipboard, matching rich_clipboard_test.dart's setup.
  late String stored;
  setUp(() {
    stored = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            stored = (call.arguments as Map)['text'] as String;
          } else if (call.method == 'Clipboard.getData') {
            return {'text': stored};
          }
          return null;
        });
  });

  test('insertLink at a collapsed caret inserts text carrying the link attribution', () {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello '))],
      ),
    );
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(6)),
      ),
    );

    controller.insertLink(url: 'https://example.com', displayText: 'a link');

    final node = controller.document.getNodeById('a')! as TextNode;
    expect(node.text.text, 'hello a link');
    final attribution = node.text.spans
        .firstWhere((s) => s.attribution.name == 'link')
        .attribution;
    expect(attribution.value['url'], 'https://example.com');
    // The link attribution covers exactly the inserted display text, not
    // the pre-existing "hello " before it.
    expect(node.text.hasAttributionThroughout(attribution, 6, 12), isTrue);
    expect(node.text.attributionsAt(0).contains(attribution), isFalse);
  });

  test('insertLink over a selection replaces the selected text with the link', () {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('click here now'))],
      ),
    );
    controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition('a', const TextNodePosition(6)),
        extent: DocumentPosition('a', const TextNodePosition(10)),
      ),
    );

    controller.insertLink(url: 'https://example.com', displayText: 'HERE');

    final node = controller.document.getNodeById('a')! as TextNode;
    expect(node.text.text, 'click HERE now');
  });

  testWidgets('pasting a bare URL offers a link dialog; confirming inserts a link', (
    tester,
  ) async {
    stored = 'https://example.com/page';
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: QuireEditor(controller: controller))),
    );
    await tester.tap(find.byType(EditableText).first);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    // The dialog is up, prefilled with the pasted URL.
    expect(find.text('Link'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'URL'), findsOneWidget);

    await tester.tap(find.text('Insert'));
    await tester.pumpAndSettle();

    final node = controller.document.getNodeById('a')! as TextNode;
    expect(node.text.text, 'https://example.com/page');
    expect(
      node.text.spans.any((s) => s.attribution.name == 'link'),
      isTrue,
    );
  });

  testWidgets('pasting ordinary text does not show the link dialog', (
    tester,
  ) async {
    stored = 'just some words, not a url';
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: QuireEditor(controller: controller))),
    );
    await tester.tap(find.byType(EditableText).first);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.text('Link'), findsNothing);
    final node = controller.document.getNodeById('a')! as TextNode;
    // Auto-capitalize turns the first letter of the (previously empty)
    // node uppercase — unrelated to link detection, just along for the ride.
    expect(node.text.text, 'Just some words, not a url');
  });

  testWidgets('tapping link text opens it instead of placing the caret there', (
    tester,
  ) async {
    final launched = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          (call) async {
            if (call.method == 'launch' || call.method == 'launchUrl') {
              launched.add((call.arguments as Map)['url'] as String);
              return true;
            }
            if (call.method == 'canLaunch') return true;
            return null;
          },
        );

    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('click here', [
              AttributionSpan(
                const Attribution('link', value: {'url': 'https://example.com'}),
                0,
                10,
              ),
            ]),
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: QuireEditor(controller: controller))),
    );

    // Tap on the actual glyphs, not the field's center — the field spans
    // the full row width, and only the linked text itself should be
    // clickable (see _linkUrlAtGlobalPosition's doc comment).
    await tester.tapAt(tester.getTopLeft(find.byType(EditableText).first) + const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(launched, ['https://example.com']);
  });

  testWidgets('tapping blank space past a linked line does not open it', (
    tester,
  ) async {
    final launched = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          (call) async {
            if (call.method == 'launch' || call.method == 'launchUrl') {
              launched.add((call.arguments as Map)['url'] as String);
              return true;
            }
            if (call.method == 'canLaunch') return true;
            return null;
          },
        );

    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('hi', [
              AttributionSpan(
                const Attribution('link', value: {'url': 'https://example.com'}),
                0,
                2,
              ),
            ]),
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 300, child: QuireEditor(controller: controller)),
        ),
      ),
    );

    // Far to the right of "hi", still well within the field's full-width row.
    final topLeft = tester.getTopLeft(find.byType(EditableText).first);
    await tester.tapAt(topLeft + const Offset(200, 5));
    await tester.pumpAndSettle();

    expect(launched, isEmpty);
  });

  test('deleting a character from a link strips the attribution from the rest of it', () {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('a link here', [
              AttributionSpan(
                const Attribution('link', value: {'url': 'https://example.com'}),
                0,
                6,
              ),
            ]),
          ),
        ],
      ),
    );

    // Backspace the last character of "a link" (offset 6 -> 5).
    controller.replaceText(nodeId: 'a', start: 5, end: 6, insertedText: '');

    final node = controller.document.getNodeById('a')! as TextNode;
    expect(node.text.text, 'a lin here');
    expect(node.text.spans, isEmpty);
  });

  test('deleting from the middle of a link strips it entirely, not just the deleted part', () {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('a link', [
              AttributionSpan(
                const Attribution('link', value: {'url': 'https://example.com'}),
                0,
                6,
              ),
            ]),
          ),
        ],
      ),
    );

    // Delete "lin" out of the middle, leaving "a k" — both surviving
    // fragments must lose the link, not just the removed middle.
    controller.replaceText(nodeId: 'a', start: 2, end: 5, insertedText: '');

    final node = controller.document.getNodeById('a')! as TextNode;
    expect(node.text.text, 'a k');
    expect(node.text.spans, isEmpty);
  });

  test('editing outside a link leaves it intact', () {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText('a link here', [
              AttributionSpan(
                const Attribution('link', value: {'url': 'https://example.com'}),
                0,
                6,
              ),
            ]),
          ),
        ],
      ),
    );

    // Delete a character from " here", after the link — untouched.
    controller.replaceText(nodeId: 'a', start: 10, end: 11, insertedText: '');

    final node = controller.document.getNodeById('a')! as TextNode;
    expect(node.text.text, 'a link her');
    expect(
      node.text.spans.any((s) => s.attribution.name == 'link'),
      isTrue,
    );
  });
}
