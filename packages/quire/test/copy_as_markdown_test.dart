import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<String?> copyFrom(QuireEditorController c) async {
    String? written;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            written = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    c.changeSelection(
      DocumentSelection(
        base: DocumentPosition('h', const TextNodePosition(0)),
        extent: DocumentPosition('b', const TextNodePosition(4)),
      ),
    );
    await c.copySelection();
    return written;
  }

  MutableDocument doc() => MutableDocument(
    nodes: [
      TextNode(
        id: 'h',
        text: AttributedText('Title'),
        metadata: {'blockType': 'header1'},
      ),
      TextNode(
        id: 'b',
        text: AttributedText('bold', [
          AttributionSpan(const Attribution('bold'), 0, 4),
        ]),
      ),
    ],
  );

  test('copy is plain text by default', () async {
    expect(
      await copyFrom(QuireEditorController(document: doc())),
      'Title\nbold',
    );
  });

  test('copyAsMarkdown writes Markdown to the clipboard', () async {
    final text = await copyFrom(
      QuireEditorController(document: doc(), copyAsMarkdown: true),
    );
    expect(text, contains('# Title'));
    expect(text, contains('**bold**'));
  });

  test('a fragment inside one block copies as plain text', () async {
    final c = QuireEditorController(document: doc(), copyAsMarkdown: true);
    String? written;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            written = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    c.changeSelection(
      DocumentSelection(
        base: DocumentPosition('h', const TextNodePosition(1)),
        extent: DocumentPosition('h', const TextNodePosition(4)),
      ),
    );
    await c.copySelection();
    expect(written, 'itl');
  });
}
