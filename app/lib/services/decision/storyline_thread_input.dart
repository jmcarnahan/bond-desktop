/// One thread's text for the storyline questions, built from the database
/// after the rules jev-prototype built the training threads with.
///
/// The rules are J1's `distill/storyline_data/corpus.py` (re-read 2026-09-29,
/// the 14:21 revision), whose `build_corpus` renders every training thread as
/// `render_thread(subject, participants, shown)` over the thread's messages
/// oldest first:
///
/// - **subject** is `conversation_fields`: for mail `mail_subject`, the
///   oldest message whose `stripReFw`'d subject is non-empty, over ALL the
///   thread's messages (not only the shown ones); for Teams `teams_subject`,
///   the chat topic, else the names subject.
/// - **participants** are `conversation_fields` too, shown through
///   `participant_display` (name, else address). Mail is `mail_participants`:
///   over ALL the messages oldest first, an inbound one adds its sender and an
///   outbound one its To recipients, keyed by lowercased address, a repeat
///   filling an empty name, at most eight. Teams is `teams_participants`: the
///   roster at first sight, minus the owner, at most eight.
/// - the **shown** messages are `build_corpus`'s `shown`: the outbound and
///   the kept inbound (`MessageStore.storylineThreadRows`' `shown`).
/// - **who** is `who_of`: `You` for outbound, else the sender's name, else
///   the address, else `''`.
/// - **text** is `body_of(packer_row(m))` (`build_states.body_of`: the body,
///   else the preview, markers stripped by `stripDecisionMarkers`), else
///   `attachment_stand_in(attachments_for(...))`, the decision state's
///   `decisionAttachmentStandIn` over the message's attachment rows.
///
/// Where the app's rows do not carry what corpus.py read, and the text is
/// therefore close to the training text rather than equal to it:
///
/// - **Bodies.** The training sample had every message's unique body. Here a
///   message whose body was never fetched (an outbound one, or one still
///   pending its detail fetch) has a NULL `body_text` and renders its
///   `body_preview`, which for mail is Graph's preview of the whole body,
///   quoted chain and all. [StorylineThreadText.previewIds] names those
///   rows so a caller can fetch the bodies first. A fetched mail whose own
///   body is empty falls back to its preview here, as `packer_row` does too.
/// - **Recipient names.** `to_json` stores addresses only, so an outbound
///   recipient's name is taken from the thread's stored `participants_json`
///   (the name ingest had from the send, or one `fillParticipantNames` copied
///   in from another thread); corpus.py had the sent message's own name. On a
///   thread with more than eight people, a re-derived recipient who is not in
///   that stored row (ingest order, capped at eight) renders as a bare
///   address where corpus.py had the name.
/// - **Not yet triaged.** An inbound row triage has not reached is
///   `pending`, which `keptMessageSql` counts as kept, so it is shown at once
///   and drops out if the gate later skips it; the text changes when it
///   does. corpus.py labelled every message before rendering.
/// - **Teams.** The subject and the roster are the stored `conversations`
///   row, which ingest writes by corpus.py's rules at first sight. A chat
///   renamed later carries its NEW topic here, where corpus.py took the
///   oldest message's topic.
/// - **Order.** Oldest first by the stored `received_at` string, then
///   `source_message_id`, where corpus.py sorts by parsed time, then the
///   thread's listing order, then sample id. The two agree on time for the
///   stamps a connector writes; messages stamped the same second may still
///   come in a different order.
///
/// corpus.py also drops mail outside the Inbox and Sent Items and keeps Teams
/// channel threads out of its pool; the app syncs neither, so neither needs a
/// rule here. The renderer keeps the newest three and caps everything.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

import '../../data/message_store.dart';
import '../../models/attachment_models.dart' show AttachmentRef;
import '../../models/message_models.dart' show Participant;
import '../conversation_state.dart' show stripReFw;
import 'decision_input.dart' show DecisionAttachment, stripDecisionMarkers;
import 'decision_state.dart' show decisionAttachmentStandIn;
import 'storyline_state.dart';

/// A thread's rendered text and the preview rows it still carries.
@immutable
class StorylineThreadText {
  /// `renderStorylineThread`'s output: what a pair, a membership question or
  /// the Why panel reads.
  final String text;

  /// The `source_message_id`s of the messages the text renders (the newest
  /// three shown) that were rendered from `body_preview` because `body_text`
  /// was empty — mostly rows whose body was never fetched, whose text is not
  /// the body training saw; a fetched message whose own body is empty counts
  /// too, though `packer_row` fell back to the preview for it as well. What
  /// the storyline judge asks the mail sync to fetch.
  final List<String> previewIds;

  const StorylineThreadText({
    required this.text,
    this.previewIds = const [],
  });

  factory StorylineThreadText.of(
    String text, {
    List<String> previewIds = const [],
  }) =>
      StorylineThreadText(
        text: text,
        previewIds: previewIds,
      );

  /// How many rendered rows carry their preview: [previewIds]' length.
  int get previewRows => previewIds.length;
}

/// [conversationKey]'s thread text on [source].
Future<StorylineThreadText> storylineThreadTextFor(
  MessageStore store,
  String source,
  String conversationKey,
) async {
  final conversation = await store.getConversationRow(source, conversationKey);
  final stored = _participants(conversation?['participants_json']);
  final rows = await store.storylineThreadRows(source, conversationKey);
  final shown = [
    for (final row in rows)
      if (row['shown'] == 1) row,
  ];

  // The stand-in needs attachments only where a body says nothing, so only
  // those messages are asked about, in one query. Not gated on
  // `has_attachments`: an inline image does not set it, and the stand-in
  // still says "Shared an image" for one.
  final needAttachments = [
    for (final row in shown)
      if (stripDecisionMarkers(_body(row)).isEmpty)
        row['source_message_id'] as String,
  ];
  final attachments =
      await store.attachmentsForMessages(source, needAttachments);

  final rendered = shown.length > storylineThreadMessages
      ? shown.sublist(shown.length - storylineThreadMessages)
      : shown;
  final previewIds = [
    for (final row in rendered)
      if ((row['body_text'] as String? ?? '').isEmpty &&
          stripDecisionMarkers(row['body_preview'] as String?).isNotEmpty)
        row['source_message_id'] as String,
  ];

  final teams = source == 'teams';
  return StorylineThreadText.of(
    renderStorylineThread(
      subject: teams
          ? (conversation?['subject'] as String?)
          : _mailSubject(rows),
      participants: [
        for (final p in teams ? stored : _mailParticipants(rows, stored))
          p.display,
      ],
      messages: [
        for (final row in shown)
          StorylineMessage(
            who: row['direction'] == 'outbound'
                ? 'You'
                : _nonEmpty(row['from_name']) ??
                    _nonEmpty(row['from_address']) ??
                    '',
            text: _text(row, attachments[row['source_message_id']]),
          ),
      ],
    ),
    previewIds: previewIds,
  );
}

/// corpus.py `mail_subject`: the oldest message whose subject is non-empty
/// after `stripReFw`, stripped; null when none has one.
String? _mailSubject(List<Map<String, Object?>> rows) {
  for (final row in rows) {
    final stripped = stripReFw(row['subject'] as String?);
    if (stripped.isNotEmpty) return stripped;
  }
  return null;
}

/// At most this many people, as ingest and corpus.py keep.
const int _maxParticipants = 8;

/// corpus.py `mail_participants` / `add_mail_participant` over [rows] oldest
/// first: an inbound message adds its sender, an outbound one its To
/// recipients, named from [stored] (see the library doc).
///
/// An outbound row with an EMPTY `to_json` names no recipient to key on. That
/// happens in production too — a sent message synced before `to_json` was
/// stored, or one whose recipients Graph did not return — and it is how the
/// golden seed writes every outbound row, since the golden set records how
/// many addresses were on an envelope and not which. Such a row takes the
/// thread's [stored] participants as its recipients, in stored order: by
/// address where one is stored, else by name (case-insensitively, and never
/// a second time for a name already present). corpus.py always had the sent
/// message's own To, so this is the closest the stored row can come.
List<Participant> _mailParticipants(
  List<Map<String, Object?>> rows,
  List<Participant> stored,
) {
  final storedNames = <String, String>{
    for (final p in stored)
      if ((p.email ?? '').isNotEmpty && (p.name ?? '').isNotEmpty)
        p.email!.toLowerCase(): p.name!,
  };
  final people = <({String? name, String? email})>[];
  bool named(String name) => people.any(
        (p) => (p.name ?? '').toLowerCase() == name.toLowerCase(),
      );
  void add(String? name, String? email) {
    if (email == null || email.isEmpty) return;
    final key = email.toLowerCase();
    for (var i = 0; i < people.length; i++) {
      if (people[i].email?.toLowerCase() != key) continue;
      if ((people[i].name ?? '').isEmpty && (name ?? '').isNotEmpty) {
        people[i] = (name: name, email: people[i].email);
      }
      return;
    }
    if (people.length >= _maxParticipants) return;
    people.add((name: name, email: email));
  }

  void addByName(String name) {
    if (name.isEmpty || named(name)) return;
    if (people.length >= _maxParticipants) return;
    people.add((name: name, email: null));
  }

  for (final row in rows) {
    if (row['direction'] == 'outbound') {
      final to = _addresses(row['to_json']);
      if (to.isEmpty) {
        for (final p in stored) {
          if ((p.email ?? '').isNotEmpty) {
            add(p.name, p.email);
          } else {
            addByName(p.name ?? '');
          }
        }
      }
      for (final address in to) {
        add(storedNames[address.toLowerCase()], address);
      }
    } else {
      add(row['from_name'] as String?, row['from_address'] as String?);
    }
  }
  return [for (final p in people) Participant(name: p.name, email: p.email)];
}

String? _body(Map<String, Object?> row) {
  final text = row['body_text'] as String?;
  return (text ?? '').isNotEmpty ? text : row['body_preview'] as String?;
}

String _text(
  Map<String, Object?> row,
  List<Map<String, Object?>>? attachments,
) {
  final body = stripDecisionMarkers(_body(row));
  if (body.isNotEmpty) return body;
  return decisionAttachmentStandIn([
    for (final a in attachments ?? const <Map<String, Object?>>[])
      _asDecisionAttachment(AttachmentRef.fromRow(a)),
  ]);
}

DecisionAttachment _asDecisionAttachment(AttachmentRef a) =>
    DecisionAttachment(
      name: a.name,
      isInline: a.isInline,
      cardText: a.cardText,
    );

String? _nonEmpty(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// A stored `to_json`: a list of address strings. Anything else reads as no
/// recipients.
List<String> _addresses(Object? raw) {
  if (raw is! String) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final a in decoded)
        if (a is String && a.isNotEmpty) a,
    ];
  } on FormatException {
    return const [];
  }
}

/// The stored `participants_json`, in its stored order. A malformed value
/// (not JSON, or a field of the wrong type) reads as no participants.
List<Participant> _participants(Object? raw) {
  if (raw is! String) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final p in decoded)
        if (p is Map) Participant.fromJson(p.cast<String, dynamic>()),
    ];
  } on FormatException {
    return const [];
  } on TypeError {
    return const [];
  }
}
