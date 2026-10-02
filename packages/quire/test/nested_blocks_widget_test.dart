import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  testWidgets('a collapsed toggle hides an image nested inside it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'toggle',
            text: AttributedText('Details'),
            metadata: {'blockType': 'toggleList', 'collapsed': true},
          ),
          ImageNode(
            id: 'img',
            url: 'x.png',
            altText: 'hidden pic',
            metadata: {'indent': 1},
          ),
          TextNode(id: 'after', text: AttributedText('after')),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireEditor(controller: controller)),
      ),
    );

    expect(find.text('hidden pic'), findsNothing);
    expect(find.byKey(const ValueKey('quire-node-after')), findsOneWidget);

    controller.toggleCollapsed('toggle');
    await tester.pump();
    expect(find.text('hidden pic'), findsOneWidget);
  });
}
