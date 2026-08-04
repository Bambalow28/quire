import 'dart:convert';

import 'package:quire_core/quire_core.dart';
import 'package:test/test.dart';

void main() {
  const bold = Attribution('bold');

  group('insert', () {
    test('shifts spans after the insertion point', () {
      final text = AttributedText('hello world', [
        AttributionSpan(bold, 6, 11),
      ]);
      final result = text.insert(0, 'XX');
      expect(result.text, 'XXhello world');
      expect(result.spans, [AttributionSpan(bold, 8, 13)]);
    });

    test('extends a span that straddles the offset', () {
      final text = AttributedText('hello world', [
        AttributionSpan(bold, 0, 11),
      ]);
      final result = text.insert(5, 'XX');
      expect(result.text, 'helloXX world');
      expect(result.spans, [AttributionSpan(bold, 0, 13)]);
    });

    test('a span ending exactly at the offset does NOT extend', () {
      final text = AttributedText('hello world', [AttributionSpan(bold, 0, 5)]);
      final result = text.insert(5, 'XX');
      expect(result.text, 'helloXX world');
      expect(result.spans, [AttributionSpan(bold, 0, 5)]);
    });

    test(
      'caller-supplied attributions apply to inserted text at the boundary',
      () {
        final text = AttributedText('hello world', [
          AttributionSpan(bold, 0, 5),
        ]);
        final result = text.insert(5, 'XX', attributions: {bold});
        expect(result.attributionsAt(5), {bold});
        expect(result.attributionsAt(6), {bold});
      },
    );
  });

  group('remove', () {
    test('deletes range and shifts spans after it', () {
      final text = AttributedText('hello world', [
        AttributionSpan(bold, 6, 11),
      ]);
      final result = text.remove(0, 6);
      expect(result.text, 'world');
      expect(result.spans, [AttributionSpan(bold, 0, 5)]);
    });

    test('clips a span that straddles the removed range', () {
      final text = AttributedText('hello world', [
        AttributionSpan(bold, 0, 11),
      ]);
      final result = text.remove(5, 6);
      expect(result.text, 'helloworld');
      expect(result.spans, [AttributionSpan(bold, 0, 10)]);
    });

    test(
      'joins the surviving edges of a span around a fully-removed middle',
      () {
        final text = AttributedText('hello world', [
          AttributionSpan(bold, 0, 2),
          AttributionSpan(bold, 9, 11),
        ]);
        final result = text.remove(2, 9);
        expect(result.text, 'held');
        expect(result.spans, [AttributionSpan(bold, 0, 4)]);
      },
    );
  });

  test('copyRange extracts text and re-bases overlapping spans', () {
    final text = AttributedText('hello world', [AttributionSpan(bold, 3, 8)]);
    final result = text.copyRange(2, 9);
    expect(result.text, 'llo wor');
    expect(result.spans, [AttributionSpan(bold, 1, 6)]);
  });

  group('toggleAttribution', () {
    test('applies to the whole range when any part lacks it', () {
      final text = AttributedText('hello world', [AttributionSpan(bold, 0, 3)]);
      final result = text.toggleAttribution(bold, 0, 5);
      expect(result.hasAttributionThroughout(bold, 0, 5), isTrue);
    });

    test('removes when the whole range already has it', () {
      final text = AttributedText('hello world', [AttributionSpan(bold, 0, 5)]);
      final result = text.toggleAttribution(bold, 0, 5);
      expect(result.hasAttributionThroughout(bold, 0, 5), isFalse);
      expect(result.attributionsAt(0), isEmpty);
    });
  });

  test(
    'addAttribution replaces a conflicting attribution with the same name',
    () {
      final linkA = const Attribution('link', value: {'url': 'a.com'});
      final linkB = const Attribution('link', value: {'url': 'b.com'});
      final text = AttributedText('hello world', [
        AttributionSpan(linkA, 0, 5),
      ]);
      final result = text.addAttribution(linkB, 0, 5);
      expect(result.attributionsAt(0), {linkB});
    },
  );

  test('spans are normalized: sorted, merged, empty dropped', () {
    final text = AttributedText('hello world', [
      AttributionSpan(bold, 5, 5), // empty, dropped
      AttributionSpan(bold, 3, 6),
      AttributionSpan(bold, 6, 9), // adjacent, merges with previous
    ]);
    expect(text.spans, [AttributionSpan(bold, 3, 9)]);
  });

  test('json round-trip', () {
    final text = AttributedText('hello world', [
      AttributionSpan(bold, 0, 5),
      AttributionSpan(
        const Attribution('link', value: {'url': 'x.com'}),
        6,
        11,
      ),
    ]);
    final restored = AttributedText.fromJson(text.toJson());
    expect(restored, text);
  });

  test('json round-trip preserves a fontSize attribution and its value', () {
    final text = AttributedText('hello world', [
      const AttributionSpan(
        Attribution('fontSize', value: {'size': 24.0}),
        0,
        5,
      ),
    ]);
    final restored = AttributedText.fromJson(text.toJson());
    expect(restored, text);
    expect(restored.attributionsAt(0), {
      const Attribution('fontSize', value: {'size': 24.0}),
    });
  });

  test(
    'a TextNode with a fontSize attribution survives a real dart:convert '
    'jsonEncode/jsonDecode round trip, same as notesync persisting a note',
    () {
      final node = TextNode(
        id: 'a',
        text: AttributedText('hello world', [
          const AttributionSpan(
            Attribution('fontSize', value: {'size': 24.0}),
            0,
            5,
          ),
        ]),
      );
      final encoded = jsonEncode(node.toJson());
      final decoded = TextNode.fromJson(
        jsonDecode(encoded) as Map<String, Object?>,
      );
      expect(decoded.text, node.text);
      expect(decoded.text.attributionsAt(0), {
        const Attribution('fontSize', value: {'size': 24.0}),
      });
    },
  );

  group('clearAttributionsNamed', () {
    test('removes matching spans by name regardless of their value', () {
      final text = AttributedText('hello world', [
        const AttributionSpan(
          Attribution('fontSize', value: {'size': 32}),
          0,
          5,
        ),
      ]);
      final result = text.clearAttributionsNamed('fontSize', 0, 5);
      expect(result.attributionsAt(0), isEmpty);
    });

    test('only trims the overlapping part of a wider span', () {
      final text = AttributedText('hello world', [
        const AttributionSpan(
          Attribution('fontSize', value: {'size': 32}),
          0,
          11,
        ),
      ]);
      final result = text.clearAttributionsNamed('fontSize', 3, 6);
      expect(result.attributionsAt(0), {
        const Attribution('fontSize', value: {'size': 32}),
      });
      expect(result.attributionsAt(4), isEmpty);
      expect(result.attributionsAt(9), {
        const Attribution('fontSize', value: {'size': 32}),
      });
    });

    test('leaves other attribution names untouched', () {
      final text = AttributedText('hello world', [
        AttributionSpan(bold, 0, 5),
        const AttributionSpan(
          Attribution('fontSize', value: {'size': 32}),
          0,
          5,
        ),
      ]);
      final result = text.clearAttributionsNamed('fontSize', 0, 5);
      expect(result.attributionsAt(0), {bold});
    });
  });
}
