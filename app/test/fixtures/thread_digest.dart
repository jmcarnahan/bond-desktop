/// A budgeted, purely EXTRACTIVE digest of everything earlier in a thread.
///
/// A straight port of `compress_thread` in `golden/tools/pack_items.py`, and
/// it has to STAY byte-compatible with it: the golden set's `ctx_compressed`
/// digests were produced by that Python, and every measured number for the
/// digest rung was scored against them. A port that renders one character
/// differently is measuring a prompt the set never priced. The expected
/// strings in `test/thread_digest_test.dart` were generated from the Python
/// itself for exactly that reason.
///
/// Extractive on purpose. A generated summary would need a model — so the
/// digest would stop being reproducible — and would risk handing the judgement
/// away for free: a summariser that writes "Priya is still waiting on you"
/// has answered the needs-you question before the model reads the message.
///
/// The Python also returns a roster, a span and the omitted count. Those are
/// fixture metadata for a human reading the packed set; the app renders the
/// digest string and nothing else, so only the string is ported.
///
/// It lives in the test fixtures rather than in `lib/` because the context
/// ladder measured on 2026-09-16/17 shipped the digest to no stage. The rule
/// was pre-registered: the message alone had to beat the tail by 4 points on
/// a triage boolean before the tail was dropped and the digest tried, and it
/// did not (`none` 70 / 70 then 70 / 68 against `tail3` 72 / 75 then 71 /
/// 72); needs-you kept the tail (digest verdict 92 against 93 for the message
/// alone and 92 for the tail, judged evidence 30 against 34); extraction
/// stayed message-alone (people 87 -> 66, project 66 -> 53 with the digest). So
/// nothing in the app builds a digest today. The three `threadDigest` prompt
/// fields, the 900-character `fitThreadDigest`, the `digest` rung and
/// `GOLDEN_EXTRACT_CTX` all stay, and this builder is what a future round
/// wires into a stage if a rung wins.
library;

import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/attachments/attachment_markers.dart';

/// How many earlier messages the digest may quote at all. Past this the thread
/// is sampled rather than read: a regime that grows with thread length is not
/// a regime, it is a context-window bug.
const int _maxLines = 14;

/// The newest few earlier messages get more room — an ask made two turns ago
/// is likelier to still be open than one made forty turns ago.
const int _recentCount = 6;
const int _recentCap = 200;
const int _olderCap = 140;

/// The whole digest, so a long thread cannot push the judged message out of
/// the model's attention. Roughly the cost of four verbatim tail messages.
/// What a PROMPT then reads of it is `threadDigestCap`, which is smaller
/// again; this is the cap the digest is built to.
const int _totalCap = 2000;

/// The digest, or null when there is nothing earlier to digest.
///
/// Byte-compatible with the packer's `compress_thread` — see the library doc
/// above for why that matters and what was deliberately left out of the port.
///
/// [earlier] is the thread BEFORE the tail, oldest first — the same rows
/// `MessageStore.loadThread` hands back, minus what the tail already quotes.
/// Null when there is nothing earlier, which is the ordinary case.
String? buildThreadDigest(List<Message> earlier) {
  if (earlier.isEmpty) return null;

  final n = earlier.length;
  final recentStart = n - _recentCount < 0 ? 0 : n - _recentCount;
  final recent = [for (var i = recentStart; i < n; i++) i];

  // The oldest two, then an even spread across the middle. Sampling rather
  // than truncation: the first turns of a thread are what say what it is
  // about, and dropping them keeps only the end of a story.
  final List<int> older;
  if (recentStart == 0) {
    older = const [];
  } else {
    final olderSlots = _maxLines - recent.length;
    final head = [for (var i = 0; i < (recentStart < 2 ? recentStart : 2); i++) i];
    final spanStart = head.length;
    final spanEnd = recentStart;
    final middleSlots = olderSlots - head.length < 0 ? 0 : olderSlots - head.length;
    final middle = <int>[];
    if (middleSlots > 0 && spanEnd > spanStart) {
      final step = (spanEnd - spanStart) ~/ middleSlots < 1
          ? 1
          : (spanEnd - spanStart) ~/ middleSlots;
      for (var i = spanStart; i < spanEnd && middle.length < middleSlots; i += step) {
        middle.add(i);
      }
    }
    older = ({...head, ...middle}.toList()..sort());
  }

  String render(int index, int? previousIndex) {
    final message = earlier[index];
    final name = message.fromName ?? '';
    final who = message.outbound ? 'You' : (name.isEmpty ? '(unknown)' : name);
    final cap = index >= recentStart ? _recentCap : _olderCap;
    // Whitespace collapsed to single spaces, the way the Python's
    // `" ".join(text.split())` does, then cut to the cap. The cut is by UTF-16
    // code unit rather than by code point, which is what Dart's `substring`
    // offers; the digests the set carries are prose and neither side has been
    // observed to differ on one.
    final squashed = _tidy(_bodyOf(message));
    var text = squashed.length > cap ? squashed.substring(0, cap) : squashed;
    if (text.isEmpty) text = '(no text -- attachment or system notice)';
    final stamp = message.receivedAt ?? '';
    final date = stamp.length > 10 ? stamp.substring(0, 10) : stamp;
    // The skipped count rides as a prefix on the line that follows the gap, so
    // a reader can tell "the next turn" from "forty turns later" without
    // spending a whole line on saying so.
    final gap = previousIndex == null ? index : index - previousIndex - 1;
    final prefix = gap > 0 ? '[+$gap omitted] ' : '';
    return '$date · $prefix$who: $text';
  }

  // The recent tail is rendered FIRST and never sacrificed: budget is spent
  // from the newest end backwards, because a truncation that eats the latest
  // turns defeats the point of carrying context at all.
  final recentLines = <String>[];
  for (var position = 0; position < recent.length; position++) {
    final previous = position > 0
        ? recent[position - 1]
        : (older.isEmpty ? null : older.last);
    recentLines.add(render(recent[position], previous));
  }

  var used = 0;
  for (final line in recentLines) {
    used += line.length + 1;
  }
  final keptOlder = <String>[];
  for (var position = older.length - 1; position >= 0; position--) {
    final previous = position > 0 ? older[position - 1] : null;
    final line = render(older[position], previous);
    if (used + line.length + 1 > _totalCap) break;
    keptOlder.insert(0, line);
    used += line.length + 1;
  }

  final quoted = keptOlder.length + recentLines.length;
  final lines = [...keptOlder, ...recentLines];
  // States plainly how many messages were never quoted, so a reader is never
  // misled into thinking this is the whole thread.
  if (quoted < n) {
    lines.insert(0, '(thread has $n earlier messages; $quoted quoted below)');
  }
  return lines.join('\n');
}

/// `buildMessageBlock`'s own precedence: the body text when non-empty, else
/// the preview — chosen BEFORE stripping, so a marker-only body resolves to
/// empty rather than silently falling back to the preview.
String _bodyOf(Message message) => stripAttachmentMarkers(
      message.bodyText?.isNotEmpty == true
          ? message.bodyText!
          : (message.bodyPreview ?? ''),
    );

/// Every run of whitespace down to one space, and the ends trimmed — the
/// Python's `" ".join(text.split())`. The two whitespace classes are not the
/// same set (Python's `split()` also breaks on U+0085 and U+001C–001F; Dart's
/// `\s` also matches U+FEFF), a caveat of the same size as the UTF-16 one
/// above: prose does not carry them, and neither side has been seen to differ.
String _tidy(String text) =>
    text.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).join(' ');
