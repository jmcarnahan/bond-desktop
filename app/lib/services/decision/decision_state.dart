/// The text the decision model reads for one message — its "state".
///
/// A byte-for-byte port of the Python that rendered the model's training data:
/// `distill/state.py` `render_state`, and `distill/build_states.py`'s block
/// helpers composed as `distill/serve_decision.py` `render_states` composes
/// them. The model learned THESE bytes, so a harmless-looking tidy-up here (a
/// trimmed line, a different date format, a UTF-16 cap) is a silent accuracy
/// loss rather than a style choice. `test/decision_state_test.dart` checks
/// every case of the fixture the Python service rendered.
library;

import 'decision_input.dart';

/// The renderer set the decision model was trained against, and the name
/// its heads file carries (`renderer`). `bond-state/2` is this file's
/// message state, whose bytes did not change from `bond-state/1`
/// (jev-prototype's `distill/state.py` `render_state` and
/// `distill/build_states.py`'s block helpers, as of 2026-09-27), plus the
/// storyline renderers in `storyline_state.dart` (`renderers.py`).
///
/// `DecisionHeads.fromJson` refuses a heads file naming another. Bump it only
/// with a change to the bytes of any renderer in the set, which the two
/// render-parity fixtures pin.
const String decisionRendererVersion = 'bond-state/2';

/// The owner line, the date line, the directness line, the tail (when there
/// is one) and the message block, joined by blank lines.
///
/// [toLocal] turns an aware `received_at` (in UTC) into the local wall time
/// the date line names; it defaults to this machine's zone, which is what
/// training used (the states were rendered on this Mac). A test passes a
/// fixed offset. Its result's fields are formatted as they stand, so a
/// returned UTC `DateTime` shifted by an offset is read as that wall time.
String renderDecisionState(
  DecisionInput input, {
  DateTime Function(DateTime utc)? toLocal,
}) {
  final tail = input.tail.length > DecisionInput.tailMax
      ? input.tail.sublist(input.tail.length - DecisionInput.tailMax)
      : input.tail;
  return renderDecisionStateFromParts(
    owner: input.owner,
    now: decisionNowAnchor(input.receivedAt, toLocal: toLocal),
    directnessLine: _directnessLine(input),
    tail: [
      for (final t in tail)
        // Capped here as the service capped it, and NOT marker-stripped
        // here: `DecisionInput.fromRows` strips, the service did not. The
        // composer below never caps, as `render_state` never did.
        DecisionTailItem(
          who: t.who,
          text: cutCodePoints(t.text, DecisionInput.tailTextCap),
        ),
    ],
    messageBlock: _messageBlock(input),
  );
}

/// `distill/state.py` `render_state`, exactly: the owner line (when
/// [owner] is non-empty), `Today is $now.`, the directness line, the thread
/// tail (when there is one) as `who: text` joined by `\n---\n`, and the
/// message block, joined by blank lines.
///
/// It takes the parts as they stand — no tail cap, no count limit, no
/// marker strip — because Python's `render_state` applied none; the raw-field
/// [renderDecisionState] applies its caps before calling this, and the golden
/// harness passes the packer's pre-rendered parts straight through (as
/// jev-prototype's `golden_states` did), so both reach the model through one
/// composition that cannot drift.
String renderDecisionStateFromParts({
  String? owner,
  required String now,
  required String directnessLine,
  required String messageBlock,
  List<DecisionTailItem> tail = const [],
}) {
  return [
    if (owner != null && owner.isNotEmpty)
      'The reader, the owner of this inbox, is $owner. Any mention of that '
          'name or address refers to the reader.',
    'Today is $now.',
    directnessLine,
    if (tail.isNotEmpty)
      'Recent thread before this message, oldest first, for context only:\n'
          '${[for (final t in tail) '${t.who}: ${t.text}'].join('\n---\n')}',
    'The message to judge:\n$messageBlock',
  ].join('\n\n');
}

/// How many code points of the body the block keeps
/// (`message_block.dart` `messageBlockBodyCap`, as the packer copied it).
const int decisionBodyCap = 4000;

/// `build_states.now_anchor`: `yyyy-MM-dd (Weekday)` in local time, or `''`
/// when there is no stamp.
///
/// Python replaced `Z` with `+00:00` and asked `datetime.fromisoformat`; an
/// aware stamp became local time, a naive one was used as it stood, and one
/// that did not parse fell back to its first ten characters. `DateTime
/// .tryParse` accepts the same ISO shapes the app stores (Graph's `…Z`, with or
/// without fractional seconds, and an explicit offset); the two parsers differ
/// only on strings no connector writes, and there the fallback agrees too
/// wherever the first ten characters are a date.
String decisionNowAnchor(
  String? receivedAt, {
  DateTime Function(DateTime utc)? toLocal,
}) {
  if (receivedAt == null || receivedAt.isEmpty) return '';
  final parsed = DateTime.tryParse(receivedAt);
  if (parsed == null) return cutCodePoints(receivedAt, 10);
  // `tryParse` marks a stamp that carried `Z` or an offset as UTC and leaves a
  // naive one local, with its fields exactly as written.
  final wall = parsed.isUtc
      ? (toLocal ?? (d) => d.toLocal())(parsed.toUtc())
      : parsed;
  return '${_pad(wall.year, 4)}-${_pad(wall.month, 2)}-${_pad(wall.day, 2)} '
      '(${_weekdays[wall.weekday - 1]})';
}

const List<String> _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String _pad(int value, int width) => value.toString().padLeft(width, '0');

/// `build_states.directness_line`, with its exact sentences.
String _directnessLine(DecisionInput input) {
  if (input.source == 'teams') {
    return input.addressedMe
        ? 'Addressed to: you directly (a 1:1 chat, or you are @mentioned).'
        : 'Addressed to: a group chat, not you specifically.';
  }
  if (input.addressedMe) return 'Addressed to: only you.';
  if (input.toCount > 1) {
    return 'Addressed to: you and ${input.toCount - 1} others.';
  }
  return 'Addressed to: you indirectly (CC, a list, or unknown).';
}

/// `build_states.message_block`: sender, subject (mail only, even when
/// empty), the raw received stamp, and the body.
String _messageBlock(DecisionInput input) {
  final teams = input.source == 'teams';
  final sender = teams
      ? 'From: ${input.fromName ?? ''}'
      : 'From: ${input.fromName ?? ''} <${input.fromAddress ?? ''}>';
  final subject = teams ? '' : 'Subject: ${input.subject ?? ''}\n';
  final bodyText = input.bodyText ?? '';
  var body = stripDecisionMarkers(
    bodyText.isNotEmpty ? bodyText : (input.bodyPreview ?? ''),
  );
  if (body.isEmpty) body = decisionAttachmentStandIn(input.attachments);
  body = cutCodePoints(body, decisionBodyCap);
  return '$sender\n${subject}Received: ${input.receivedAt ?? ''}\n\nBody:\n'
      '$body';
}

/// `build_states.attachment_stand_in`: what an empty body says instead. The
/// storyline thread text uses it too (`storylineThreadTextFor`), as jev's
/// corpus does.
String decisionAttachmentStandIn(List<DecisionAttachment> attachments) {
  final shared = [
    for (final a in attachments)
      if (!a.isInline) a,
  ];
  if (shared.isEmpty) return attachments.isEmpty ? '' : 'Shared an image';
  for (final a in shared) {
    final card = pythonStrip(a.cardText ?? '');
    if (card.isNotEmpty) return cutCodePoints(card, 300);
  }
  final names = [
    for (final a in shared.take(3))
      pythonStrip(a.name ?? '').isEmpty ? '(unnamed)' : pythonStrip(a.name!),
  ];
  return 'Shared a file: ${names.join(', ')}';
}
