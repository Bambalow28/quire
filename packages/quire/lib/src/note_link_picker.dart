import 'package:flutter/material.dart';

import 'note_links.dart';

/// A search sheet over the host's notes. Returns the chosen note, or null when
/// dismissed.
Future<QuireNoteRef?> showNoteLinkPicker(
  BuildContext context,
  QuireNoteLinks links,
) {
  return showModalBottomSheet<QuireNoteRef>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _NoteLinkSheet(links: links),
  );
}

class _NoteLinkSheet extends StatefulWidget {
  const _NoteLinkSheet({required this.links});
  final QuireNoteLinks links;

  @override
  State<_NoteLinkSheet> createState() => _NoteLinkSheetState();
}

class _NoteLinkSheetState extends State<_NoteLinkSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = widget.links.search(_query.trim());
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Link to a note',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Expanded(
              child: results.isEmpty
                  ? Center(
                      child: Text(
                        _query.trim().isEmpty
                            ? 'No other notes yet'
                            : 'No notes match “${_query.trim()}”',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    )
                  : ListView.builder(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: results.length,
                      itemBuilder: (context, i) {
                        final ref = results[i];
                        return ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(
                            ref.title.isEmpty ? 'Untitled' : ref.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: ref.subtitle == null
                              ? null
                              : Text(
                                  ref.subtitle!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          onTap: () => Navigator.of(context).pop(ref),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
