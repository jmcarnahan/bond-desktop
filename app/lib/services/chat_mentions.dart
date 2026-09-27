import 'package:flutter/foundation.dart' show immutable;

/// A real Teams @mention on an outgoing chat message: the person it notifies,
/// by Graph id, and the name the message shows for them.
///
/// Built from the people the owner put on a reply. The id is what makes it a
/// mention rather than a name in a sentence — Teams notifies the id and draws
/// the name — which is why a person without one never becomes one of these.
@immutable
class ChatMention {
  /// The person's Azure AD object id, the same id a `teams:` address carries.
  final String userId;

  /// What the message shows, and what the at-tag wraps.
  final String displayName;

  const ChatMention({required this.userId, required this.displayName});

  @override
  bool operator ==(Object other) =>
      other is ChatMention &&
      other.userId == userId &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(userId, displayName);

  @override
  String toString() => 'ChatMention($userId, $displayName)';
}

/// [mentions] with each person once, first pick kept, in pick order.
///
/// The ONE numbering both backends and the builder agree on: a mention's index
/// here is its `id` in Graph's mentions array and in the `<at id>` that points
/// at it, so the two can never name different people.
List<ChatMention> distinctMentions(List<ChatMention> mentions) {
  final seen = <String>{};
  return [
    for (final mention in mentions)
      if (mention.userId.isNotEmpty &&
          mention.displayName.isNotEmpty &&
          seen.add(mention.userId))
        mention,
  ];
}

/// The ids in [asked] that the stored message [sent] does not mention.
///
/// [sent] is a chat message in Graph's shape — what both backends hand back
/// from a send, the MCP one after reshaping the server's flat
/// `mentioned_user_ids` into `mentions[].mentioned.user.id`. A server that
/// quietly ignored the mentions would post the text with every `@Name`
/// already stripped and nobody notified, and this is how the send notices.
///
/// A message with NO `mentions` key answers empty: that is a server which
/// does not report mentions at all, and nothing can be concluded from it —
/// the send keeps its old behaviour there rather than warning on every
/// message. A key that is present but short of someone is the drop.
List<String> missingMentionIds(
  List<ChatMention> asked,
  Map<String, dynamic> sent,
) {
  final people = distinctMentions(asked);
  if (people.isEmpty) return const [];
  final raw = sent['mentions'];
  if (raw is! List) return const [];
  final stored = <String>{};
  for (final entry in raw) {
    if (entry is! Map) continue;
    final mentioned = entry['mentioned'];
    final user = mentioned is Map ? mentioned['user'] : null;
    final id = user is Map ? user['id'] : null;
    if (id is String && id.isNotEmpty) stored.add(id);
  }
  return [
    for (final person in people)
      if (!stored.contains(person.userId)) person.userId,
  ];
}

/// [text] as the chat HTML Graph wants beside a mentions array.
///
/// The first `@Name` for each person becomes `<at id="i">Name</at>` — the `@`
/// drops, as Teams itself draws a mention. A person the text never names is
/// PREPENDED instead: the chip is the owner's stated intent, and the quick
/// reply box never writes `@Name` at all, so most of its sends take that path
/// and "Ada Park, can you…" reads as addressing.
///
/// Everything else is escaped, `&` first so an escape is never escaped twice,
/// and every entity used is one `stripChatHtml` decodes — which is what lets
/// the echo Graph hands back store as the words that were typed. `\n` becomes
/// `<br>`, the one break the strip turns back into a line.
String chatHtmlWithMentions(String text, List<ChatMention> mentions) {
  final people = distinctMentions(mentions);
  final raw = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  final spans = _claims(raw, people);

  final claimed = {for (final s in spans) s.id};
  final out = StringBuffer();
  for (var id = 0; id < people.length; id++) {
    if (claimed.contains(id)) continue;
    out
      ..write(_atTag(id, people[id].displayName))
      ..write(' ');
  }
  var cursor = 0;
  for (final span in spans) {
    out
      ..write(_escape(raw.substring(cursor, span.start)))
      ..write(_atTag(span.id, people[span.id].displayName));
    cursor = span.end;
  }
  out.write(_escape(raw.substring(cursor)));
  return out.toString().replaceAll('\n', '<br>');
}

/// [text] with each person's claimed `@Name` taken out, for a server that
/// builds its own at-tags and always puts them at the FRONT: sending the
/// `@Name` too would read "Ada Park @Ada Park can you…".
///
/// The claims are [chatHtmlWithMentions]'s own, so a token this removes is
/// exactly one that builder would have turned into a tag. One space beside
/// the token goes with it — the following one, else the one before — so
/// "Looping in @Ada Park." reads "Looping in." rather than keeping a gap.
String textWithoutClaimedMentions(String text, List<ChatMention> mentions) {
  final people = distinctMentions(mentions);
  final raw = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final spans = _claims(raw, people);
  if (spans.isEmpty) return text;
  final out = StringBuffer();
  var cursor = 0;
  for (final span in spans) {
    var start = span.start;
    var end = span.end;
    if (end < raw.length && raw[end] == ' ') {
      end++;
    } else if (start > cursor && raw[start - 1] == ' ') {
      start--;
    }
    out.write(raw.substring(cursor, start));
    cursor = end;
  }
  out.write(raw.substring(cursor));
  return out.toString().trim();
}

/// Where each person's first standalone `@Name` sits in [raw], in text order.
///
/// Longest name first when claiming, so `@Ada Park` is not claimed by an
/// `Ada` who happens to be on the same reply; ids stay in pick order.
List<({int start, int end, int id})> _claims(
  String raw,
  List<ChatMention> people,
) {
  final claimOrder = [for (var i = 0; i < people.length; i++) i]
    ..sort((a, b) =>
        people[b].displayName.length.compareTo(people[a].displayName.length));
  final spans = <({int start, int end, int id})>[];
  for (final id in claimOrder) {
    final needle = '@${people[id].displayName}';
    var from = 0;
    while (true) {
      final at = raw.indexOf(needle, from);
      if (at < 0) break;
      final end = at + needle.length;
      final overlaps = spans.any((s) => at < s.end && end > s.start);
      if (!overlaps && !_continuesWord(raw, end)) {
        spans.add((start: at, end: end, id: id));
        break;
      }
      from = at + 1;
    }
  }
  return spans..sort((a, b) => a.start.compareTo(b.start));
}

String _atTag(int id, String name) => '<at id="$id">${_escape(name)}</at>';

/// Whether the character at [index] carries on the word a match ended in —
/// `@Ada` inside `@Adam` names somebody else.
bool _continuesWord(String text, int index) {
  if (index >= text.length) return false;
  return RegExp(r'[\p{L}\p{N}_]', unicode: true).hasMatch(text[index]);
}

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
