import 'dart:math';

import 'package:quire_core/quire_core.dart';
import 'package:quire_delta/quire_delta.dart';
import 'package:test/test.dart';

Object? _junk(Random rng, int depth) {
  switch (rng.nextInt(depth > 2 ? 5 : 8)) {
    case 0:
      return null;
    case 1:
      return rng.nextInt(100) - 50;
    case 2:
      return ['a', '\n', 'hi\nthere', '', '😀\n\n', '\u0000'][rng.nextInt(6)];
    case 3:
      return rng.nextBool();
    case 4:
      return 1.5;
    case 5:
      return [for (var i = 0; i < rng.nextInt(4); i++) _junk(rng, depth + 1)];
    default:
      return {
        for (var i = 0; i < rng.nextInt(4); i++)
          [
            'insert',
            'attributes',
            'bold',
            'header',
            'list',
            'image',
            'table',
            'link',
            'x',
          ][rng.nextInt(9)]: _junk(
            rng,
            depth + 1,
          ),
      };
  }
}

void main() {
  test('arbitrary junk ops never throw and always yield a valid document', () {
    for (var seed = 0; seed < 500; seed++) {
      final rng = Random(seed);
      final ops = [for (var i = 0; i < 1 + rng.nextInt(8); i++) _junk(rng, 0)];
      final doc = deltaToQuireOrNull(ops);
      expect(doc, isNotNull, reason: 'seed $seed returned null for $ops');
      expect(validateDocument(doc!), isEmpty, reason: 'seed $seed: $ops');
    }
  });
}
