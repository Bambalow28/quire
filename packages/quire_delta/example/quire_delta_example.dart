import 'package:quire_delta/quire_delta.dart';

void main() {
  final delta = [
    {
      'insert': 'Meeting Notes\n',
      'attributes': {'header': 2},
    },
    {'insert': 'This is '},
    {
      'insert': 'important',
      'attributes': {'bold': true},
    },
    {'insert': ' context.\n'},
    {
      'insert': 'Buy milk\n',
      'attributes': {'list': 'checked'},
    },
  ];

  final doc = deltaToQuire(delta);
  print('Converted ${doc.nodes.length} nodes:');
  for (final node in doc.nodesInDocumentOrder) {
    print('  $node');
  }
}
