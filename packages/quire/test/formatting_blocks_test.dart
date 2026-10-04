import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';
import 'package:quire/src/syntax_highlight.dart';

import 'support/ime.dart';

TextNode _p(String id, [String? text, Map<String, Object?>? meta]) =>
    TextNode(id: id, text: AttributedText(text ?? id), metadata: meta);

QuireEditorController _controller(
  List<DocumentNode> nodes, {
  QuireNoteLinks? links,
}) => QuireEditorController(
  document: MutableDocument(nodes: nodes),
  noteLinks: links,
);

Future<void> _pump(
  WidgetTester tester,
  QuireEditorController controller, {
  bool blockHandles = false,
  bool toolbar = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: QuireEditor(
                controller: controller,
                blockHandles: blockHandles,
              ),
            ),
            if (toolbar) QuireToolbar(controller: controller),
          ],
        ),
      ),
    ),
  );
}

TextNode _node(QuireEditorController c, String id) =>
    c.document.getNodeById(id) as TextNode;

List<String> _ids(QuireEditorController c) => [
  for (final n in c.document.nodes) n.id,
];

void _select(QuireEditorController c, String id, int a, [int? b]) =>
    c.changeSelection(
      DocumentSelection(
        base: DocumentPosition(id, TextNodePosition(a)),
        extent: DocumentPosition(id, TextNodePosition(b ?? a)),
      ),
    );

void main() {
  group('colour, highlight and inline code', () {
    test('setTextColor / setHighlight apply, report, and undo', () {
      final c = _controller([_p('a', 'hello world')]);
      _select(c, 'a', 0, 5);
      c.setTextColor('#D44C47');
      c.setHighlight('#4DCB912F');
      expect(c.activeTextColor, '#D44C47');
      expect(c.activeHighlight, '#4DCB912F');
      expect(
        _node(c, 'a').text.attributionsAt(2).map((a) => a.name),
        containsAll(['color', 'backgroundColor']),
      );
      expect(_node(c, 'a').text.attributionsAt(7), isEmpty);

      c.setTextColor('#337EA9'); // replaces, doesn't stack
      expect(
        _node(
          c,
          'a',
        ).text.spans.where((s) => s.attribution.name == 'color').length,
        1,
      );
      c.setTextColor(null);
      expect(c.activeTextColor, isNull);

      c.undo();
      expect(c.activeTextColor, '#337EA9');
    });

    test('a collapsed caret arms the colour for what is typed next', () {
      final c = _controller([_p('a', 'hi')]);
      _select(c, 'a', 2);
      c.setTextColor('#448361');
      c.replaceText(nodeId: 'a', start: 2, end: 2, insertedText: '!');
      expect(
        _node(c, 'a').text.attributionsAt(2).single.value['hex'],
        '#448361',
      );
    });

    test('toggleCode wraps the selection and toggles off', () {
      final c = _controller([_p('a', 'run it')]);
      _select(c, 'a', 0, 3);
      c.toggleCode();
      expect(_node(c, 'a').text.attributionsAt(1).map((a) => a.name), ['code']);
      c.toggleCode();
      expect(_node(c, 'a').text.spans, isEmpty);
    });

    testWidgets('typing the closing backtick turns `x` into inline code', (
      tester,
    ) async {
      final c = _controller([_p('a', '')]);
      await _pump(tester, c);
      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      await typeText(tester, 'use ');
      await typeText(tester, '`');
      await typeText(tester, 'foo');
      await typeText(tester, '`');
      await tester.pump();
      await tester.pump();
      final node = _node(c, 'a');
      expect(node.text.text, 'use foo');
      final span = node.text.spans.single;
      expect((span.attribution.name, span.start, span.end), ('code', 4, 7));
      // Typing on continues outside the code style.
      await typeText(tester, ' x');
      await tester.pump();
      expect(_node(c, 'a').text.text, 'use foo x');
      expect(_node(c, 'a').text.spans.single.end, 7);
      // One undo gives back the literal backticks.
      c.undo();
      c.undo();
      expect(_node(c, 'a').text.spans, isEmpty);
      expect(_node(c, 'a').text.text, 'use `foo`');
    });

    test('a backtick typed first in a line does not throw', () {
      final c = _controller([_p('a', '`')]);
      _select(c, 'a', 1);
      c.replaceText(nodeId: 'a', start: 0, end: 0, insertedText: '`');
      expect(_node(c, 'a').text.text, '``');
    });

    test('a lone backtick or a fence is left alone', () {
      final c = _controller([_p('a', 'x ``')]);
      _select(c, 'a', 4);
      c.replaceText(nodeId: 'a', start: 4, end: 4, insertedText: '`');
      expect(_node(c, 'a').text.text, 'x ```');
      expect(_node(c, 'a').text.spans, isEmpty);
    });

    testWidgets('a fence with a language names the code block', (tester) async {
      final c = _controller([_p('a', '')]);
      await _pump(tester, c);
      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      await typeText(tester, '```dart');
      await typeText(tester, ' ');
      await tester.pump();
      await tester.pump();
      expect(_node(c, 'a').blockType, 'code');
      expect(_node(c, 'a').metadata['language'], 'dart');
    });
  });

  group('syntax highlighting', () {
    test('tokenises keywords, strings, numbers, comments and types', () {
      const src = 'final x = Foo("hi", 42); // done';
      final runs = highlight(src, 'dart');
      String of(SyntaxToken t) => runs
          .where((r) => r.token == t)
          .map((r) => src.substring(r.start, r.end))
          .join('|');
      expect(of(SyntaxToken.keyword), 'final');
      expect(of(SyntaxToken.type), 'Foo');
      expect(of(SyntaxToken.string), '"hi"');
      expect(of(SyntaxToken.number), '42');
      expect(of(SyntaxToken.comment), '// done');
    });

    test('aliases, plain text and unknown languages', () {
      expect(canonicalLanguage('JS'), 'javascript');
      expect(canonicalLanguage('nope'), isNull);
      expect(highlight('final x', 'plain'), isEmpty);
      expect(highlight('final x', null), isEmpty);
      expect(highlight('final x', 'klingon'), isEmpty);
    });

    test(
      'an unterminated string or comment runs to the end without throwing',
      () {
        expect(
          highlight('x = "abc', 'python').single.token,
          SyntaxToken.string,
        );
        expect(highlight('/* open', 'c').single.token, SyntaxToken.comment);
        expect(highlight("# c\nx = 'a\\'b'", 'python').length, 2);
      },
    );
  });

  group('block actions', () {
    test('move, duplicate, delete and turn into', () {
      final c = _controller([_p('a'), _p('b'), _p('c')]);
      expect(c.canMoveBlock('a', up: true), isFalse);
      expect(c.canMoveBlock('a', up: false), isTrue);
      c.moveBlock('a', 1);
      expect(_ids(c), ['b', 'a', 'c']);
      c.undo();
      expect(_ids(c), ['a', 'b', 'c']);

      c.duplicateBlock('b');
      expect(c.document.nodes.length, 4);
      expect(_node(c, c.document.nodes[2].id).text.text, 'b');
      expect(c.composer.selection!.extent.nodeId, c.document.nodes[2].id);

      c.deleteBlock('c');
      expect(c.document.nodes.length, 3);

      c.turnBlockInto('a', 'header2');
      expect(_node(c, 'a').blockType, 'header2');
      c.turnBlockInto('a', 'header2'); // names the state: stays
      expect(_node(c, 'a').blockType, 'header2');
    });

    test('a line inside a table resolves to its table', () {
      final table = TableNode(
        id: 't',
        rows: [
          TableRow(
            cells: [
              TableCell(nodes: [_p('cell')]),
            ],
          ),
        ],
      );
      final c = _controller([_p('a'), table]);
      expect(c.topLevelBlockIdOf('cell'), 't');
      expect(c.topLevelBlockIdOf('a'), 'a');
      expect(c.canMoveBlock('cell', up: true), isFalse); // nested: not movable
    });

    testWidgets('Block actions in the panel opens the menu and duplicates', (
      tester,
    ) async {
      final c = _controller([_p('a', 'first'), _p('b', 'second')]);
      await _pump(tester, c, toolbar: true);
      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Block actions'),
        100,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Block actions'));
      await tester.pumpAndSettle();
      expect(find.text('Turn into'), findsOneWidget);
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      expect(c.document.nodes.length, 3);
      expect(_node(c, c.document.nodes[1].id).text.text, 'first');
    });

    testWidgets('the Turn into list converts the block', (tester) async {
      final c = _controller([_p('a', 'plain')]);
      await _pump(tester, c, toolbar: true);
      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      await showBlockMenuForTest(tester, c, 'a');
      await tester.ensureVisible(find.text('Quote'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quote'));
      await tester.pumpAndSettle();
      expect(_node(c, 'a').blockType, 'blockquote');
    });
  });

  group('block handle', () {
    testWidgets('dragging the handle reorders blocks; the gutter is reserved', (
      tester,
    ) async {
      final c = _controller([_p('a'), _p('b'), _p('c')]);
      await _pump(tester, c, blockHandles: true);
      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
      // Text is pushed right by the gutter.
      expect(
        tester.getTopLeft(findNode('a')).dx,
        greaterThanOrEqualTo(kBlockHandleGutter),
      );

      final handle = tester.getCenter(find.byIcon(Icons.drag_indicator));
      final target = tester.getCenter(findNode('c'));
      final g = await tester.startGesture(handle);
      // Real drags arrive as a stream of moves; the first ones clear the slop.
      for (var dy = 10.0; dy < target.dy - handle.dy + 6; dy += 10) {
        await g.moveTo(Offset(handle.dx, handle.dy + dy));
        await tester.pump();
      }
      await g.moveTo(Offset(handle.dx, target.dy + 6));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(_ids(c), ['b', 'c', 'a']);
      c.undo();
      expect(_ids(c), ['a', 'b', 'c']);
    });

    testWidgets('tapping the handle opens the block menu', (tester) async {
      final c = _controller([_p('a'), _p('b')]);
      await _pump(tester, c, blockHandles: true);
      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.drag_indicator));
      await tester.pumpAndSettle();
      expect(find.text('Move down'), findsOneWidget);
      await tester.tap(find.text('Move down'));
      await tester.pumpAndSettle();
      expect(_ids(c), ['b', 'a']);
    });

    testWidgets('no handle and no gutter unless asked for', (tester) async {
      final c = _controller([_p('a')]);
      await _pump(tester, c);
      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
    });

    testWidgets('a mouse hover shows the handle on that block', (tester) async {
      final c = _controller([_p('a'), _p('b')]);
      await _pump(tester, c, blockHandles: true);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(findNode('b')));
      await tester.pump();
      final handle = tester.getCenter(find.byIcon(Icons.drag_indicator));
      expect(
        (handle.dy - tester.getCenter(findNode('b')).dy).abs(),
        lessThan(14),
      );
    });
  });

  group('code block chrome', () {
    testWidgets('shows the language, lets you change it, and copies', (
      tester,
    ) async {
      final c = _controller([
        _p('a', 'var x = 1;', {'blockType': 'code'}),
      ]);
      await _pump(tester, c);
      expect(find.text('Plain text'), findsOneWidget);
      await tester.tap(find.text('Plain text'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dart'));
      await tester.pumpAndSettle();
      expect(_node(c, 'a').metadata['language'], 'dart');
      expect(find.text('Dart'), findsOneWidget);

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      await tester.tap(find.byIcon(Icons.content_copy));
      await tester.pump();
      expect(copied, 'var x = 1;');
      expect(find.byIcon(Icons.check), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('plain text clears the language', (tester) async {
      final c = _controller([
        _p('a', 'x', {'blockType': 'code', 'language': 'dart'}),
      ]);
      await _pump(tester, c);
      await tester.tap(find.text('Dart'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plain text'));
      await tester.pumpAndSettle();
      expect(_node(c, 'a').metadata.containsKey('language'), isFalse);
    });
  });

  group('note links', () {
    final notes = [
      const QuireNoteRef(id: 'n1', title: 'Groceries'),
      const QuireNoteRef(id: 'n2', title: 'Trip plan'),
    ];
    QuireNoteLinks links(List<String> opened) => QuireNoteLinks(
      search: (q) => [
        for (final n in notes)
          if (n.title.toLowerCase().contains(q.toLowerCase())) n,
      ],
      onOpen: opened.add,
    );

    testWidgets(
      'typing [[ opens the picker; choosing replaces the brackets with a link',
      (tester) async {
        final c = _controller([_p('a', '')], links: links([]));
        await _pump(tester, c);
        await tester.tap(findNode('a'));
        await _settle(tester);
        await typeText(tester, 'see ');
        await typeText(tester, '[');
        await typeText(tester, '[');
        await tester.pump();
        await _settle(tester);
        expect(find.text('Groceries'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'trip');
        await _settle(tester);
        expect(find.text('Groceries'), findsNothing);
        await tester.tap(find.text('Trip plan'));
        await _settle(tester);
        final node = _node(c, 'a');
        expect(node.text.text, 'see Trip plan');
        final span = node.text.spans.single;
        expect(
          (
            span.attribution.name,
            span.attribution.value['id'],
            span.start,
            span.end,
          ),
          ('noteLink', 'n2', 4, 13),
        );
        c.undo();
        expect(_node(c, 'a').text.text, 'see [[');
      },
    );

    testWidgets('dismissing the picker leaves the brackets as text', (
      tester,
    ) async {
      final c = _controller([_p('a', '')], links: links([]));
      await _pump(tester, c);
      await tester.tap(findNode('a'));
      await _settle(tester);
      await typeText(tester, '[');
      await typeText(tester, '[');
      await _settle(tester);
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);
      expect(_node(c, 'a').text.text, '[[');
      expect(_node(c, 'a').text.spans, isEmpty);
    });

    testWidgets('no [[ picker without noteLinks', (tester) async {
      final c = _controller([_p('a', '')]);
      await _pump(tester, c);
      await tester.tap(findNode('a'));
      await _settle(tester);
      await typeText(tester, '[');
      await typeText(tester, '[');
      await _settle(tester);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('tapping a note link opens that note, not an external URL', (
      tester,
    ) async {
      final opened = <String>[];
      final text = AttributedText('go to Groceries now', [
        AttributionSpan(Attribution('noteLink', value: {'id': 'n1'}), 6, 15),
      ]);
      final c = _controller([
        TextNode(id: 'a', text: text),
      ], links: links(opened));
      await _pump(tester, c);
      final box = tester.getTopLeft(findNode('a'));
      await tester.tapAt(box + const Offset(150, 8));
      await tester.pump();
      expect(opened, ['n1']);
    });

    test('insertNoteLink links the selected text, or inserts the title', () {
      final c = _controller([_p('a', 'my groceries list')], links: links([]));
      _select(c, 'a', 3, 12);
      c.insertNoteLink(notes[0]);
      expect(_node(c, 'a').text.text, 'my groceries list');
      expect(_node(c, 'a').text.spans.single.attribution.value['id'], 'n1');

      final d = _controller([_p('a', 'see ')], links: links([]));
      _select(d, 'a', 4);
      d.insertNoteLink(notes[1]);
      expect(_node(d, 'a').text.text, 'see Trip plan');
    });

    test('editing inside a note link unlinks it whole', () {
      final text = AttributedText('Groceries', [
        AttributionSpan(Attribution('noteLink', value: {'id': 'n1'}), 0, 9),
      ]);
      final c = _controller([TextNode(id: 'a', text: text)]);
      c.replaceText(nodeId: 'a', start: 3, end: 4, insertedText: '');
      expect(_node(c, 'a').text.spans, isEmpty);
    });

    Future<void> openPanelAtInlineCode(
      WidgetTester tester,
      QuireEditorController c,
    ) async {
      await _pump(tester, c, toolbar: true);
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Inline code'),
        100,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the panel offers Link to note when the host supports it', (
      tester,
    ) async {
      await openPanelAtInlineCode(
        tester,
        _controller([_p('a')], links: links([])),
      );
      expect(find.text('Link to note'), findsOneWidget);
    });

    testWidgets('the panel hides Link to note without noteLinks', (
      tester,
    ) async {
      await openPanelAtInlineCode(tester, _controller([_p('a')]));
      expect(find.text('Inline code'), findsOneWidget);
      expect(find.text('Link to note'), findsNothing);
    });
  });
}

/// Opens the block menu directly (the handle/panel paths are covered above).
Future<void> showBlockMenuForTest(
  WidgetTester tester,
  QuireEditorController c,
  String id,
) async {
  final context = tester.element(find.byType(Scaffold));
  // ignore: unawaited_futures
  showBlockMenu(context, c, id);
  await tester.pumpAndSettle();
}

/// The picker's autofocused TextField blinks its caret forever, so
/// pumpAndSettle never returns while it is up.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}
