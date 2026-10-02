# Manual test checklist

Automated tests cannot drive a real software keyboard or IME. Run this on
hardware before any release that touches `document_input_client.dart`,
`quire_editor.dart` key handling, or selection code. Several past regressions
(double newline on iOS Return, Enter racing typed text, multi-key IME batches)
only showed up on a device.

Record the device, OS version and Quire commit at the top of each run.

## iPhone (software keyboard)

- [ ] Type a sentence. First letter of a new paragraph auto-capitalises.
- [ ] Return at end of a line adds exactly one new line (not two).
- [ ] Return mid-line splits it; caret lands at the start of the second half.
- [ ] Return on an empty bullet, number, task or quote ends the list.
- [ ] Backspace at the start of a list item removes the list style first, then merges.
- [ ] Autocorrect: type `teh `, it corrects; Undo restores `teh`.
- [ ] Predictive bar suggestion replaces only the current word.
- [ ] Dictation: speak two sentences; text lands at the caret, formatting kept.
- [ ] Hold-space trackpad: caret moves, selection extends with a second finger.
- [ ] Long-press selects a word; drag handles resize; Copy/Cut/Paste appear.
- [ ] Emoji keyboard: insert an emoji, a skin-tone emoji and a flag; Backspace removes each in one press.
- [ ] Smart punctuation: `"quotes"` and `--` follow system settings.
- [ ] Rotate to landscape and back mid-edit: caret and scroll position hold.
- [ ] Dismiss and re-show the keyboard: caret returns where it was.

## Other input methods (iOS)

- [ ] Japanese (Kana or Romaji): composition underline shows; Return commits, does not add a line.
- [ ] Chinese Pinyin: candidate selection commits the right text; Backspace edits the pinyin, not prior text.
- [ ] Korean: a syllable being composed is replaced, not duplicated.
- [ ] Arabic or Hebrew: caret moves visually, text aligns right.
- [ ] Hardware Bluetooth keyboard: arrows, Cmd+B/I/U, Cmd+Z/Shift+Cmd+Z, Option+arrows, Cmd+arrows.

## Mac (hardware keyboard)

- [ ] Return, Shift+Return, Tab, Shift+Tab behave per list context.
- [ ] Option+Backspace deletes a word; Cmd+Backspace deletes to line start.
- [ ] Cmd+A then type replaces everything with one undo step.
- [ ] Mouse: click, double-click word, triple-click paragraph, drag across blocks.
- [ ] Right-click shows the context menu.
- [ ] Cmd+F opens find; next/previous and replace work.
- [ ] Paste from Safari and Notes: plain text lands, Markdown converts, URLs offer a link.
- [ ] Copy with `copyAsMarkdown` on, paste into Notion: headings and lists survive.

## Content

- [ ] A table with merged cells: type in each cell, Tab moves cell to cell.
- [ ] Select across two cells and delete: both cells stay, no cell becomes empty.
- [ ] A toggle with an image and a table inside: collapse hides both.
- [ ] A callout containing an image keeps its border around it.
- [ ] A note saved by a newer build opens read-only with a notice.
- [ ] VoiceOver: headings are announced as headings, tasks as checked/unchecked, table size is announced.
- [ ] Larger text (Settings > Accessibility): editor text scales, nothing clips.
