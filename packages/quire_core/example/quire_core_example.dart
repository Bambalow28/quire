// Minimal demo of the quire_core document model and edit pipeline: build a
// document, run an edit request through the Editor, read back the result.
import 'package:quire_core/quire_core.dart';

void main() {
  final document = MutableDocument(
    nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
  );
  final composer = DocumentComposer();
  final editor = Editor(
    document,
    composer,
    requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
  );

  editor.execute([
    InsertTextRequest(
      DocumentPosition('a', const TextNodePosition(5)),
      ' world',
    ),
  ]);

  print((document.getNodeById('a') as TextNode).text.text); // hello world

  // Wrapping the editor in an EditHistory adds undo/redo.
  final history = EditHistory(editor);
  composer.selection = DocumentSelection(
    base: DocumentPosition('a', const TextNodePosition(0)),
    extent: DocumentPosition('a', const TextNodePosition(5)),
  );
  history.execute([ToggleAttributionRequest(const Attribution('bold'))]);
  print((document.getNodeById('a') as TextNode).text.spans); // bold span
  history.undo();
  print((document.getNodeById('a') as TextNode).text.spans); // empty again
}
