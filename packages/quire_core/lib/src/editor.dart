import 'document.dart';
import 'selection.dart';

/// A request to change the document/composer, submitted through
/// [Editor.execute]. This is the only entry point for mutation.
abstract class EditRequest {}

/// Something that happened as a result of executing requests.
abstract class EditEvent {}

class DocumentEdited extends EditEvent {
  DocumentEdited(this.changedNodeIds);
  final List<String> changedNodeIds;
}

class SelectionChanged extends EditEvent {}

class ComposingAttributionsChanged extends EditEvent {}

class EditContext {
  EditContext({required this.document, required this.composer});
  final MutableDocument document;
  final DocumentComposer composer;
}

/// Executes one [EditRequest] against the document/composer, emitting events
/// and optionally enqueueing follow-on commands via [CommandExecutor].
abstract class EditCommand {
  void execute(EditContext context, CommandExecutor executor);
}

/// Collects the events emitted while running a command.
class CommandExecutor {
  final List<EditEvent> events = [];

  void emit(EditEvent event) => events.add(event);
}

typedef EditRequestHandler = EditCommand? Function(EditRequest request);

/// Reacts to a batch of events by (optionally) issuing more requests via
/// `editor.execute(...)`. Runs after every top-level `execute` call, capped
/// at [Editor.maxReactionDepth] to prevent runaway reaction loops.
abstract class EditReaction {
  void react(EditContext context, Editor editor, List<EditEvent> events);
}

abstract class EditListener {
  void onEdit(List<EditEvent> events);
}

/// The one funnel through which the document and composer may be mutated.
///
/// A call to [execute] may, via reactions, trigger nested calls to
/// [execute]; all resulting events are collected into a single batch and
/// listeners are notified exactly once, after the outermost call finishes.
class Editor {
  Editor(
    MutableDocument document,
    DocumentComposer composer, {
    List<EditRequestHandler> requestHandlers = const [],
    List<EditReaction> reactions = const [],
  }) : _requestHandlers = requestHandlers,
       _reactions = reactions,
       context = EditContext(document: document, composer: composer);

  final EditContext context;
  final List<EditRequestHandler> _requestHandlers;
  final List<EditReaction> _reactions;
  final List<EditListener> _listeners = [];

  static const maxReactionDepth = 10;

  List<EditEvent>? _activeBatch;
  int _reactionDepth = 0;

  void addListener(EditListener listener) => _listeners.add(listener);
  void removeListener(EditListener listener) => _listeners.remove(listener);

  void execute(List<EditRequest> requests) {
    final isOutermost = _activeBatch == null;
    final batch = _activeBatch ??= <EditEvent>[];

    try {
      final newEvents = _runCommands(requests);
      batch.addAll(newEvents);

      if (_reactionDepth < maxReactionDepth) {
        _reactionDepth++;
        try {
          for (final reaction in _reactions) {
            reaction.react(context, this, newEvents);
          }
        } finally {
          _reactionDepth--;
        }
      }
    } finally {
      if (isOutermost) _activeBatch = null;
    }

    if (isOutermost && batch.isNotEmpty) {
      for (final listener in List<EditListener>.from(_listeners)) {
        listener.onEdit(batch);
      }
    }
  }

  List<EditEvent> _runCommands(List<EditRequest> requests) {
    // Resolve every request before running anything, so an unhandled request
    // throws without half-applying the batch.
    final commands = requests.map((request) {
      final command = _findHandler(request);
      if (command == null) {
        throw StateError(
          'No EditRequestHandler registered for ${request.runtimeType}',
        );
      }
      return command;
    }).toList();

    final events = <EditEvent>[];
    for (final command in commands) {
      final executor = CommandExecutor();
      command.execute(context, executor);
      events.addAll(executor.events);
    }
    return events;
  }

  EditCommand? _findHandler(EditRequest request) {
    for (final handler in _requestHandlers) {
      final command = handler(request);
      if (command != null) return command;
    }
    return null;
  }
}
