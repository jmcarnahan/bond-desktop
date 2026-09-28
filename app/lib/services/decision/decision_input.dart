/// What the decision model reads about one message, before it is rendered.
///
/// Raw fields rather than a pre-rendered block, because the renderer
/// (`decision_state.dart`) is a byte-for-byte port of the Python that wrote
/// the model's training data, and the fixtures that pin it are expressed in
/// exactly these fields. [DecisionInput.fromRows] is the one door from the
/// app's own models into this shape.
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../models/attachment_models.dart';
import '../../models/message_models.dart';
import '../owner_lookup.dart';

/// One attachment as the renderer's stand-in reads it: a body that says
/// nothing is replaced by the first shared file's card text, or its name.
@immutable
class DecisionAttachment {
  final String? name;
  final bool isInline;
  final String? cardText;

  const DecisionAttachment({this.name, this.isInline = false, this.cardText});
}

/// One earlier message of the thread, as the tail section prints it.
///
/// [who] is `You` for the owner's own message, else the sender's display name;
/// [text] is already what the tail shows, markers stripped.
@immutable
class DecisionTailItem {
  final String who;
  final String text;

  const DecisionTailItem({required this.who, required this.text});
}

/// Everything the renderer needs for one message.
@immutable
class DecisionInput {
  /// Already composed, e.g. `Rivera, Sam <sam.rivera@example.org>`. Null or
  /// empty renders no owner line — which costs the model its best lever on
  /// `needs_you`, so a caller should pass one whenever it has one.
  final String? owner;

  /// `email` or `teams`.
  final String source;

  final String? fromName;
  final String? fromAddress;
  final String? subject;

  /// The RAW stored string: the block prints it as-is and the date line is
  /// computed from it.
  final String? receivedAt;
  final String? bodyText;
  final String? bodyPreview;

  /// The stored `addressed_me` fact — see `decision_input_test.dart` for what
  /// ingest means by it on each source.
  final bool addressedMe;

  /// Mail: how many To recipients. Teams: 0.
  final int toCount;

  final List<DecisionAttachment> attachments;

  /// Oldest first. The renderer keeps the last three.
  final List<DecisionTailItem> tail;

  const DecisionInput({
    this.owner,
    required this.source,
    this.fromName,
    this.fromAddress,
    this.subject,
    this.receivedAt,
    this.bodyText,
    this.bodyPreview,
    this.addressedMe = false,
    this.toCount = 0,
    this.attachments = const [],
    this.tail = const [],
  });

  /// The input for [message] from what the triage queue already holds: the
  /// message itself, its thread as `MessageStore.loadThread` returns it, and
  /// its attachment rows.
  ///
  /// A port of `build_states.py`'s main loop, which is what the model was
  /// trained on:
  ///
  /// - the tail is the thread's messages whose `received_at` sorts BEFORE this
  ///   one's, compared as plain strings exactly as Python compared them, the
  ///   last [tailMax], oldest first; `You` for an outbound one; each text is
  ///   the body (else the preview) with its `[[att:…]]` markers stripped, cut
  ///   to [tailTextCap] code points and otherwise untouched — no link
  ///   stripping, because training had none;
  /// - `toCount` is the length of the stored To list for mail and 0 for Teams;
  /// - `addressedMe` is the stored column, which ingest writes with the
  ///   training's own rule on both sources.
  factory DecisionInput.fromRows({
    required Message message,
    required List<Message> thread,
    required List<AttachmentRef> attachments,
    String? owner,
  }) {
    final receivedAt = message.receivedAt ?? '';
    // Indexed so equal stamps keep the order the caller gave them: Python's
    // sort is stable and Dart's is not.
    final prior = [
      for (final (i, m) in thread.indexed)
        if (!(m.id == message.id && m.source == message.source) &&
            (m.receivedAt ?? '').compareTo(receivedAt) < 0)
          (i, m),
    ]..sort((a, b) {
        final byTime = (a.$2.receivedAt ?? '').compareTo(b.$2.receivedAt ?? '');
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
    final kept = prior.length > tailMax
        ? prior.sublist(prior.length - tailMax)
        : prior;

    final ordered = [...attachments.indexed]..sort((a, b) {
        final byOrdinal = a.$2.ordinal.compareTo(b.$2.ordinal);
        return byOrdinal != 0 ? byOrdinal : a.$1.compareTo(b.$1);
      });

    return DecisionInput(
      owner: owner,
      source: message.source,
      fromName: message.fromName,
      fromAddress: message.fromAddress,
      subject: message.subject,
      receivedAt: message.receivedAt,
      bodyText: message.bodyText,
      bodyPreview: message.bodyPreview,
      addressedMe: message.addressedMe,
      // `Message.to` is `to_json` decoded, and a malformed value decodes to an
      // empty list, which is the 0 a Teams row gets anyway.
      toCount: message.source == 'email' ? message.to.length : 0,
      attachments: [
        for (final (_, a) in ordered)
          DecisionAttachment(
            name: a.name,
            isInline: a.isInline,
            cardText: a.cardText,
          ),
      ],
      tail: [
        for (final (_, m) in kept)
          DecisionTailItem(
            who: m.outbound ? 'You' : (m.fromName ?? ''),
            text: cutCodePoints(
              stripDecisionMarkers(
                (m.bodyText ?? '').isNotEmpty ? m.bodyText : m.bodyPreview,
              ),
              tailTextCap,
            ),
          ),
      ],
    );
  }

  /// How many earlier messages the tail keeps (`build_states.THREAD_TAIL`).
  static const int tailMax = 3;

  /// How many code points of each tail message it keeps
  /// (`build_states.THREAD_MESSAGE_CAP`).
  static const int tailTextCap = 300;
}

/// The owner line's `owner`, composed the way the training data wrote it:
/// `name <address>`, else whichever of the two is known, else null (no line).
String? decisionOwnerString(OwnerIdentity? owner) {
  final name = owner?.name?.trim() ?? '';
  final address = owner?.address?.trim() ?? '';
  if (name.isNotEmpty && address.isNotEmpty) return '$name <$address>';
  if (address.isNotEmpty) return address;
  if (name.isNotEmpty) return name;
  return null;
}

/// `build_states.strip_markers`, exactly — which is NOT the app's own
/// `stripAttachmentMarkers` (`attachments/attachment_markers.dart`), and the
/// name differs so a file can import both:
///
/// - only `[[att:…]]` is removed; an `[[img:…]]` marker stays in the text,
///   because the training data kept it;
/// - a text with no marker comes back UNCHANGED, runs of spaces and all;
/// - after a removal the runs are collapsed and the ends stripped with
///   Python's whitespace set, while a line inside may keep a leading space.
String stripDecisionMarkers(String? text) {
  if (text == null || text.isEmpty) return '';
  if (!_marker.hasMatch(text)) return text;
  return pythonStrip(text
      .replaceAll(_marker, ' ')
      .replaceAll(_spaceRun, ' ')
      .replaceAll(_blankRun, '\n\n'));
}

final RegExp _marker = RegExp(r'\[\[att:[^\]]*\]\]');
final RegExp _spaceRun = RegExp(r'[ \t]{2,}');
final RegExp _blankRun = RegExp(r'\n{3,}');

/// [text] cut to its first [max] Unicode code points, which is what a Python
/// slice counts. A UTF-16 cut would count an emoji twice and could split it.
String cutCodePoints(String text, int max) {
  // Code points never outnumber UTF-16 units, so a short string is already
  // inside the cap without walking it.
  if (text.length <= max) return text;
  final out = StringBuffer();
  var taken = 0;
  for (final rune in text.runes) {
    if (taken == max) break;
    out.writeCharCode(rune);
    taken++;
  }
  return out.toString();
}

/// Python's `str.strip()` with no argument.
///
/// Not Dart's `trim()`: the two whitespace sets differ at the edges (Python
/// strips U+001C–U+001F and keeps U+FEFF; Dart does the opposite), and the
/// state must match the training bytes.
String pythonStrip(String text) {
  var start = 0;
  var end = text.length;
  while (start < end && _isPythonSpace(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isPythonSpace(text.codeUnitAt(end - 1))) {
    end--;
  }
  return (start == 0 && end == text.length) ? text : text.substring(start, end);
}

/// `str.isspace()` for one code unit. Every Python whitespace character is in
/// the Basic Multilingual Plane, so a surrogate is never one.
bool _isPythonSpace(int c) =>
    (c >= 0x09 && c <= 0x0D) ||
    (c >= 0x1C && c <= 0x20) ||
    c == 0x85 ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;
