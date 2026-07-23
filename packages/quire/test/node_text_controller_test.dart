import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  testWidgets(
    'buildTextSpan composes overlapping bold+italic spans into distinct runs',
    (tester) async {
      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox();
            },
          ),
        ),
      );

      const bold = Attribution('bold');
      const italic = Attribution('italic');
      // "hello world": bold covers [0, 8) ("hello wo"), italic covers
      // [5, 11) (" world") -> three runs: bold-only, bold+italic, italic-only.
      final text = AttributedText('hello world', [
        AttributionSpan(bold, 0, 8),
        AttributionSpan(italic, 5, 11),
      ]);
      final controller = NodeTextController(nodeId: 'a', text: text);

      final span = controller.buildTextSpan(
        context: capturedContext,
        withComposing: false,
      );
      final runs = span.children!.cast<TextSpan>();

      expect(runs.map((r) => r.text).toList(), ['hello', ' wo', 'rld']);
      expect(runs[0].style!.fontWeight, FontWeight.w700);
      expect(runs[0].style!.fontStyle, isNot(FontStyle.italic));
      expect(runs[1].style!.fontWeight, FontWeight.w700);
      expect(runs[1].style!.fontStyle, FontStyle.italic);
      expect(runs[2].style!.fontWeight, isNot(FontWeight.w700));
      expect(runs[2].style!.fontStyle, FontStyle.italic);
    },
  );

  testWidgets('buildTextSpan ignores unknown attribution names', (
    tester,
  ) async {
    late BuildContext capturedContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox();
          },
        ),
      ),
    );

    final text = AttributedText('hi', [
      const AttributionSpan(Attribution('made-up'), 0, 2),
    ]);
    final controller = NodeTextController(nodeId: 'a', text: text);

    expect(
      () => controller.buildTextSpan(
        context: capturedContext,
        withComposing: false,
      ),
      returnsNormally,
    );
  });
}
