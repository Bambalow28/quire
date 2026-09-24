// Test helpers for driving `DocumentInputClient` (quire's editor-level
// `DeltaTextInputClient`) the way the real platform does: as JSON-encoded
// `TextEditingDelta`s over the `flutter/textinput` platform channel, rather
// than the old `tester.enterText`/`find.byType(EditableText)` route (there
// is no more per-node `EditableText` for those to find — see
// `IME_REWRITE_SPEC.md` stage 4).
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Finds a text node's rendered block by id — the `find.byType(EditableText)`
/// replacement, now that a node is a keyed `RichText`/`Semantics` block
/// rather than its own field. See the `ValueKey('quire-node-<id>')` added in
/// `quire_editor.dart`'s `_buildTextNode`.
Finder findNode(String nodeId) => find.byKey(ValueKey('quire-node-$nodeId'));

/// Every text node's rendered block currently in the tree — the
/// `find.byType(EditableText)` replacement for a test that wants a COUNT of
/// rendered nodes rather than one specific node's.
final Finder findAllNodes = find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('quire-node-'),
);

/// A second tap at [target] guaranteed NOT to register as the second half of
/// a double-tap, no matter how little real wall-clock time separates it from
/// a prior touch tap — multi-tap detection reads the wall clock
/// (`DateTime.now()`), which a widget test's fake frame clock can't
/// fast-forward, so two `tester.tapAt` calls back-to-back always look like a
/// double-tap in a test even when the production gesture they're standing in
/// for (tap an existing caret again, well after the fact) never would.
/// Uses a different pointer kind (mouse, vs `tapAt`'s touch), which the
/// multi-click streak already treats as unrelated — lands on the exact same
/// offset a same-position touch tap would, since layout is deterministic.
Future<void> tapAgain(WidgetTester tester, Offset target) async {
  final gesture = await tester.startGesture(
    target,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

/// The `TextInput.setClient` client id most recently seen by
/// [WidgetTester.testTextInput] — every delta message below is addressed to
/// this id, same as the engine addresses them to whichever client currently
/// holds the platform's `TextInputConnection`.
int _clientId(WidgetTester tester) {
  final setClientCall = tester.testTextInput.log.lastWhere(
    (call) => call.method == 'TextInput.setClient',
    orElse: () => throw StateError(
      'No TextInput.setClient call seen yet — focus the editor before sending deltas.',
    ),
  );
  return (setClientCall.arguments as List<dynamic>)[0] as int;
}

Map<String, dynamic> _deltaJson({
  required String oldText,
  required int deltaStart,
  required int deltaEnd,
  required String deltaText,
  required int selectionBase,
  required int selectionExtent,
  int composingBase = -1,
  int composingExtent = -1,
}) => {
  'oldText': oldText,
  'deltaText': deltaText,
  'deltaStart': deltaStart,
  'deltaEnd': deltaEnd,
  'selectionBase': selectionBase,
  'selectionExtent': selectionExtent,
  'selectionAffinity': 'TextAffinity.downstream',
  'selectionIsDirectional': false,
  'composingBase': composingBase,
  'composingExtent': composingExtent,
};

/// Sends one `TextInputClient.updateEditingStateWithDeltas` platform message
/// carrying [deltas] (each built with [_deltaJson]), then pumps once so the
/// editor's `DocumentInputClient` processes them.
Future<void> sendDeltas(
  WidgetTester tester,
  List<Map<String, dynamic>> deltas,
) async {
  final clientId = _clientId(tester);
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(
      MethodCall('TextInputClient.updateEditingStateWithDeltas', <dynamic>[
        clientId,
        {'deltas': deltas},
      ]),
    ),
    (_) {},
  );
  await tester.pump();
}

/// What this helper believes the (fake) platform currently holds — updated
/// locally after every delta it sends (mirroring `TextEditingDelta.apply`,
/// same as a real IME keeps its own copy) and re-adopted from
/// `tester.testTextInput.editingState` whenever the app pushes a *new* one
/// on its own (attach, undo, a cross-node commit, ...). `DocumentInputClient`
/// deliberately skips a push when nothing actually changed (never clobber
/// an active composing region), so reading `editingState` alone after every
/// call would go stale — see its `syncFromModel` doc comment.
TextEditingValue? _localTrackedValue;
Map<String, dynamic>? _lastSeenEditingState;

/// The editing value to build the next delta against — the ground truth a
/// real IME would keep, not just whatever was last echoed back to the
/// platform (see [_localTrackedValue]'s doc comment for why those differ).
TextEditingValue trackedValue(WidgetTester tester) {
  final state = tester.testTextInput.editingState;
  if (state == null) {
    throw StateError('No editing state yet — focus the editor first.');
  }
  if (!identical(state, _lastSeenEditingState)) {
    _lastSeenEditingState = state;
    _localTrackedValue = TextEditingValue.fromJSON(state);
  }
  return _localTrackedValue!;
}

/// Types [text] at the tracked selection, as one insertion/replacement
/// delta — mirrors what a soft keyboard sends for a single keystroke (or an
/// autocomplete commit) once composing is done.
Future<void> typeText(WidgetTester tester, String text) async {
  final value = trackedValue(tester);
  final newSelectionOffset = value.selection.start + text.length;
  final delta = _deltaJson(
    oldText: value.text,
    deltaStart: value.selection.start,
    deltaEnd: value.selection.end,
    deltaText: text,
    selectionBase: newSelectionOffset,
    selectionExtent: newSelectionOffset,
  );
  _localTrackedValue = TextEditingValue(
    text: value.text.replaceRange(
      value.selection.start,
      value.selection.end,
      text,
    ),
    selection: TextSelection.collapsed(offset: newSelectionOffset),
  );
  await sendDeltas(tester, [delta]);
}

/// One backspace at the tracked caret — a pure deletion delta covering the
/// one grapheme cluster (or UTF-16 code unit, same as a real backspace)
/// immediately before the caret.
Future<void> backspace(WidgetTester tester) async {
  final value = trackedValue(tester);
  final caret = value.selection.start;
  final int deleteStart;
  final int deleteEnd;
  if (!value.selection.isCollapsed) {
    deleteStart = value.selection.start;
    deleteEnd = value.selection.end;
  } else if (caret > 0) {
    deleteStart = caret - 1;
    deleteEnd = caret;
  } else {
    return;
  }
  final delta = _deltaJson(
    oldText: value.text,
    deltaStart: deleteStart,
    deltaEnd: deleteEnd,
    deltaText: '',
    selectionBase: deleteStart,
    selectionExtent: deleteStart,
  );
  _localTrackedValue = TextEditingValue(
    text: value.text.replaceRange(deleteStart, deleteEnd, ''),
    selection: TextSelection.collapsed(offset: deleteStart),
  );
  await sendDeltas(tester, [delta]);
}

/// A soft-keyboard Return — arrives as a literal "\n" insertion delta, same
/// as `TextInputAction.newline` does on a real device.
Future<void> pressEnter(WidgetTester tester) => typeText(tester, '\n');

/// Replaces the focused (single-node) field's entire real text — everything
/// after the leading IME sentinel — with [newText], as one delta. The
/// `tester.enterText(find.byType(EditableText)...)` replacement for a test
/// that wants "the field now reads exactly this", not a keystroke-precise
/// edit.
Future<void> replaceEntireText(WidgetTester tester, String newText) async {
  final value = trackedValue(tester);
  const sentinelLength = 1;
  final delta = _deltaJson(
    oldText: value.text,
    deltaStart: sentinelLength,
    deltaEnd: value.text.length,
    deltaText: newText,
    selectionBase: sentinelLength + newText.length,
    selectionExtent: sentinelLength + newText.length,
  );
  _localTrackedValue = TextEditingValue(
    text: value.text.substring(0, sentinelLength) + newText,
    selection: TextSelection.collapsed(offset: sentinelLength + newText.length),
  );
  await sendDeltas(tester, [delta]);
}

/// A selection-only (non-text) delta — a caret move or drag with no text
/// change, same as e.g. tapping elsewhere in the same node.
Future<void> moveSelection(WidgetTester tester, TextSelection selection) async {
  final value = trackedValue(tester);
  final delta = _deltaJson(
    oldText: value.text,
    deltaStart: -1,
    deltaEnd: -1,
    deltaText: '',
    selectionBase: selection.baseOffset,
    selectionExtent: selection.extentOffset,
  );
  _localTrackedValue = value.copyWith(selection: selection);
  await sendDeltas(tester, [delta]);
}
