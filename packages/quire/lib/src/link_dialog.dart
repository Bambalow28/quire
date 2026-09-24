import 'package:flutter/material.dart';

/// Shows a dialog for entering/editing a link's URL and display text.
/// [initialUrl]/[initialText] prefill the fields (paste-detected URL, or an
/// existing selection's text). Returns the picked `(url, text)`, or `null`
/// if the user cancelled or left the URL empty.
Future<({String url, String text})?> showLinkDialog(
  BuildContext context, {
  String initialUrl = '',
  String initialText = '',
}) {
  return showDialog<({String url, String text})>(
    context: context,
    builder: (context) =>
        _LinkDialog(initialUrl: initialUrl, initialText: initialText),
  );
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.initialUrl, required this.initialText});

  final String initialUrl;
  final String initialText;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final _urlController = TextEditingController(text: widget.initialUrl);
  late final _textController = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _urlController.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    final text = _textController.text.trim();
    Navigator.of(context).pop((url: url, text: text.isEmpty ? url : text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Link'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _urlController,
            autofocus: widget.initialUrl.isEmpty,
            decoration: const InputDecoration(labelText: 'URL'),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _textController,
            autofocus: widget.initialUrl.isNotEmpty,
            decoration: const InputDecoration(labelText: 'Text to display'),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Insert')),
      ],
    );
  }
}
