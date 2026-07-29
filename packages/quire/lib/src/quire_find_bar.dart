import 'package:flutter/material.dart';

import 'quire_editor_controller.dart';

/// A compact find & replace bar, a sibling surface to [QuireEditor] (not a
/// dialog) — the host places it in its own layout (e.g. above the editor).
/// Renders nothing when [QuireEditorController.findBarOpen] is `false`, so the
/// host doesn't have to wire visibility itself.
class QuireFindBar extends StatefulWidget {
  const QuireFindBar({super.key, required this.controller});

  final QuireEditorController controller;

  @override
  State<QuireFindBar> createState() => _QuireFindBarState();
}

class _QuireFindBarState extends State<QuireFindBar> {
  final _queryController = TextEditingController();
  final _replacementController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    _replacementController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        if (!widget.controller.findBarOpen) return const SizedBox.shrink();

        final scheme = Theme.of(context).colorScheme;
        final matchCount = widget.controller.matches.length;
        final counterText = matchCount == 0
            ? 'No results'
            : '${widget.controller.currentMatchIndex + 1}/$matchCount';

        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Material(
            color: scheme.surface,
            elevation: 3,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _queryController,
                          autofocus: true,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: 'Find',
                          ),
                          onChanged: widget.controller.find,
                        ),
                      ),
                      Text(counterText, style: Theme.of(context).textTheme.bodySmall),
                      IconButton(
                        tooltip: 'Previous match',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.keyboard_arrow_up),
                        onPressed: matchCount > 0
                            ? widget.controller.findPrevious
                            : null,
                      ),
                      IconButton(
                        tooltip: 'Next match',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.keyboard_arrow_down),
                        onPressed: matchCount > 0
                            ? widget.controller.findNext
                            : null,
                      ),
                      IconButton(
                        tooltip: 'Close',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close),
                        onPressed: widget.controller.closeFind,
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _replacementController,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: 'Replace',
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: matchCount > 0
                            ? () => widget.controller.replaceCurrent(
                                _replacementController.text,
                              )
                            : null,
                        child: const Text('Replace'),
                      ),
                      TextButton(
                        onPressed: matchCount > 0
                            ? () => widget.controller.replaceAll(
                                _queryController.text,
                                _replacementController.text,
                              )
                            : null,
                        child: const Text('Replace all'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
