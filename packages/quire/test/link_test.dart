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

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();

    expect(launched, ['https://example.com']);
  });
}
