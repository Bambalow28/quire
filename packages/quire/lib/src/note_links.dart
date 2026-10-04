/// A note the host app lets the editor link to.
class QuireNoteRef {
  const QuireNoteRef({required this.id, required this.title, this.subtitle});

  /// Whatever the host uses to find the note again; stored in the link.
  final String id;

  /// Shown in the picker, and inserted as the link text.
  final String title;

  /// A second, dimmer line in the picker (a preview, a folder, a date).
  final String? subtitle;
}

/// Hooks that let the editor link to the host's other notes: the `[[` picker,
/// the toolbar's "Link to note" row, and tapping an existing link. Without
/// one on the controller, none of those exist.
class QuireNoteLinks {
  const QuireNoteLinks({required this.search, required this.onOpen});

  /// The notes matching [query] (an empty query means "everything recent").
  final List<QuireNoteRef> Function(String query) search;

  /// Called with a link's stored id when it is tapped.
  final void Function(String noteId) onOpen;
}
