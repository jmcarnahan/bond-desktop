import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

import '../services/external_sender.dart';
import 'attachment_models.dart';
import 'label_models.dart';

/// Wire/row models for the inbox. Hand-written and deliberately defensive:
/// every field reads through a nullable cast with a default, so neither a
/// drifting API payload nor a half-written sqlite row can throw during a
/// render. Timestamps stay ISO [String]s — they are displayed and sorted,
/// never arithmetic'd.
///
/// Ported from a sibling app's conversation models, minus the fields this
/// inbox has no use for (campaign, relevance, suggestions, attachments).

/// What marks a message id as the app's own optimistic row: the local echo a
/// mail send writes for itself, before the server's copy comes back. See
/// `services/mail_echo.dart` for the whole contract, which re-exports this so
/// a caller reasoning about echoes still imports one file.
///
/// It lives HERE, at the bottom of the layering, because three layers share
/// it and none of them may import the other two: [Message.isLocalEcho] reads
/// it, the echo writer builds ids with it, and `MessageStore.deleteLocalEcho`
/// guards BOTH of its statements with a `LIKE 'local:%'` over it. That guard
/// is the only thing standing between the app's one delete and a widening of
/// what it is able to destroy, so a second copy of this string — drifting
/// from the one the guard uses — is the failure worth designing against.
const String localEchoPrefix = 'local:';

/// Decodes a JSON-encoded TEXT column into a list, tolerating null, empty
/// string, malformed JSON, and a payload that decodes to a non-list.
List<dynamic> _decodeJsonList(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    return decoded is List ? decoded : const [];
  } on FormatException {
    return const [];
  }
}

/// A `to_json` column read into display strings.
///
/// Public because two models read the same column and must read it the same
/// way: [Message.fromRow] builds a transcript bubble's recipients out of it,
/// and `SentRow.fromRow` names who a sent message went to. The blob is a JSON
/// array of addresses as the connectors write it; `toString` is what turns
/// anything else somebody stored in there into something renderable rather
/// than into a crash.
List<String> recipientsFromJson(Object? raw) =>
    [for (final t in _decodeJsonList(raw)) t.toString()];

/// sqlite has no bool: STRICT columns hold 0/1 integers. Null stays null —
/// "not triaged yet" is not the same as "no action needed".
///
/// `HomeFeedRow.fromRow` reads `needs_you_verdict` with the stricter `== 1`;
/// the store writes only 0/1/NULL, so the two readings agree on every stored
/// value. Keep them agreeing if either moves.
bool? _boolFromInt(Object? raw) => raw == null ? null : raw != 0;

/// Where a conversation sits in the reply lifecycle. An unrecognized value
/// maps to [waiting] so a wire drift never silently demands action.
enum ConversationState {
  needsReply,
  waiting,
  done;

  static ConversationState fromWire(String? value) => switch (value) {
        'needs_reply' => ConversationState.needsReply,
        'done' => ConversationState.done,
        _ => ConversationState.waiting,
      };

  String get wire => switch (this) {
        ConversationState.needsReply => 'needs_reply',
        ConversationState.done => 'done',
        ConversationState.waiting => 'waiting',
      };
}

/// Call-to-action urgency for a conversation row. Unknown → [normal], the
/// neutral middle, so noise never masquerades as urgent nor gets buried.
enum CtaUrgency {
  low,
  normal,
  high,
  urgent;

  static CtaUrgency fromWire(String? value) => switch (value) {
        'low' => CtaUrgency.low,
        'high' => CtaUrgency.high,
        'urgent' => CtaUrgency.urgent,
        _ => CtaUrgency.normal,
      };
}

/// A participant on a conversation. Both fields nullable — a bare address
/// with no display name is common.
@immutable
class Participant {
  final String? name;
  final String? email;

  const Participant({this.name, this.email});

  /// Display: name when present, else email, else empty.
  String get display =>
      (name != null && name!.isNotEmpty) ? name! : (email ?? '');

  factory Participant.fromJson(Map<String, dynamic> json) {
    return Participant(
      name: json['name'] as String?,
      email: json['email'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {'name': name, 'email': email};
}

/// One conversation summary row.
@immutable
class Conversation {
  final String id;

  /// Which connector this thread came from. Email today; a Teams channel
  /// later reuses every model below it unchanged.
  final String source;

  final String? subject;
  final List<Participant> participants;
  final String? category;
  final ConversationState state;
  final String? ctaText;
  final CtaUrgency ctaUrgency;
  final int messageCount;
  final int inboundCount;
  final String? lastInboundAt;
  final String? lastOutboundAt;
  final String? lastMessageAt;
  final String? lastMessagePreview;

  /// Where the app has filed this thread — `'later'` or null for the inbox.
  /// Lives on `conversation_ai`, not on the thread's own row: it is the app's
  /// opinion about the mail, not a fact about the mail. Null on anything read
  /// from a payload that does not carry it.
  final String? bucket;

  /// How loudly this thread is asking for the user, 0..2. Written by the
  /// scoring pass; null until one has run.
  final double? attentionScore;

  /// How many inbound messages on this thread the user has not read. Counted
  /// at read time from `messages.is_read` by the subquery in
  /// `loadConversations` rather than stored on the thread, so read state made
  /// in Outlook arrives with the next sync and a derived count can never drift
  /// from the messages it describes. Zero on anything read from a payload that
  /// does not carry it, because absent data must never invent unread mail.
  final int unreadCount;

  /// How many pipeline steps are still open against this thread — triage and
  /// extraction on its own messages, storyline and draft work on the thread.
  /// Summed at read time from the two subquery columns in `loadConversations`,
  /// and zero on any read that does not run them, because absent data must
  /// never claim the model is busy: an indicator that errs that way never
  /// turns off.
  final int aiPendingCount;

  /// How many non-inline attachments the thread carries. Counted at read time
  /// by the subquery in `loadConversations` for [unreadCount]'s reason — the
  /// attachments ARE the truth, and a maintained counter would drift with
  /// nothing to correct it. Zero on any read that does not run the subquery,
  /// which reads as "no paperclip" rather than as a wrong number.
  final int attachmentCount;

  /// The date or timeframe the thread's NEWEST INBOUND message named, in the
  /// sender's own words ("Friday", "before the 15th"). Null when that message
  /// named none — even if an older one did, because a deadline somebody stated
  /// three replies ago has already been answered or overtaken.
  ///
  /// Read at read time by the subquery in `loadConversations`, and null on any
  /// read that does not run it — which reads as "no date named" rather than as
  /// a wrong one.
  final String? latestDeadline;

  /// How many suggestions are waiting against the message the thread is
  /// waiting on. Zero or one in practice: the `drafts` table is keyed by the
  /// message a suggestion answers, and only the newest inbound one counts.
  ///
  /// Counted at read time by the subquery in `loadConversations`, and zero on
  /// any read that does not run it — which reads as "nothing suggested",
  /// never as a badge over a thread whose composer is empty.
  final int pendingDraftCount;

  /// When a thread the user deferred should come back, as a UTC ISO stamp in
  /// [MessageStore.isoStamp]'s exact shape. Null means no date was set, which
  /// is every thread a SENDER rule filed: a standing rule about a person has
  /// no "when", and resurfacing its threads one at a time would quietly exempt
  /// them from the rule that had just been made.
  ///
  /// A read-time column off `conversation_ai`, so it is null on every read
  /// that does not join it — which reads as "no date", never as a date that
  /// has passed.
  final String? snoozedUntil;

  /// The owner's own words on this thread, most-used first — the chips a row
  /// draws. Read at read time by the GROUP_CONCAT subquery in
  /// `loadConversations`, and EMPTY on every read that does not run it, which
  /// reads as "not filed" rather than as a wrong chip.
  ///
  /// Nothing to do with [Message.label], the model's verdict about one message.
  /// A thread carries as many of these as the owner has put on it.
  final List<Label> labels;

  /// WHY this thread wants the owner, in the words the needs-you pass wrote:
  /// `'teams_direct'` from the deterministic floor, or the model's own evidence
  /// sentence. Null when nothing on the thread has been judged to need them.
  ///
  /// Read at read time by the subquery in `loadConversations`, off the newest
  /// KEPT inbound message whose verdict was YES — the only kind of row that can
  /// answer this question. A reason attached to a `false` verdict explains why a
  /// message does NOT want the owner, and showing it here would answer the
  /// opposite of what was asked. Null on every read that does not run the
  /// subquery, which reads as "nothing to show" rather than as a wrong sentence.
  ///
  /// [needsYouReasonWords] is the one place these turn into words on screen.
  final String? needsYouReason;

  /// Which message [needsYouReason] came off, and when it landed. Carried so a
  /// later phase can jump the transcript to it — the line that shows the reason
  /// is inert text today — and null together with the reason.
  final String? needsYouReasonMessageId;
  final String? needsYouReasonAt;

  /// Whether the sender of the newest kept inbound message is waiting on an
  /// answer, as triage v2 judged it. TRI-STATE, and the null arm is the point:
  /// null means no v2 pass has ever judged that message, which is NOT "no reply
  /// expected" (`schema.drift` says so at the column, and [isNeedsYou] is
  /// written on that distinction).
  ///
  /// Read at read time by the subquery in `loadConversations`; null on every
  /// read that does not run it, which reads as "nobody has judged", never as a
  /// judgement.
  final bool? replyExpected;

  /// Whether the needs-you pass has vetoed this THREAD: its newest kept
  /// inbound was judged no, AND no kept inbound newer than the thread's last
  /// outbound carries a yes (with no outbound at all, no kept inbound does).
  ///
  /// Computed in SQL by `MessageStore`'s one veto fragment, the same one the
  /// Needs You tile and filter read, and never recomputed here from partial
  /// data. A no on the newest message alone is not enough: the judge rates
  /// THAT message, so a reply-all "adding Jordan for visibility" judged no
  /// must not hide an older ask the owner has not answered.
  ///
  /// It outranks triage's ask and `reply_expected` in [isNeedsYou]: the judge
  /// reads the thread before the message and answers the narrower question —
  /// is this the owner's — where triage answers "does anyone owe a reply".
  /// False on every read that did not run the fragment, which leaves the
  /// thread where the other terms put it.
  final bool needsYouVetoed;

  /// The envelope address of the newest KEPT inbound message — who the thread
  /// is waiting on. Null on every read that does not run the subquery in
  /// `loadConversations`, and on a thread with no inbound mail at all.
  ///
  /// Carried for [isExternalTo] and for select-similar's sender and domain
  /// scopes (`services/select_similar.dart`), and for nothing else, which is
  /// why it is an address and not a [Participant]: the name beside it is
  /// already on [participants], and a second copy of it could disagree with
  /// the first.
  final String? latestInboundFrom;

  const Conversation({
    required this.id,
    this.source = 'email',
    this.subject,
    this.participants = const [],
    this.category,
    this.state = ConversationState.waiting,
    this.ctaText,
    this.ctaUrgency = CtaUrgency.normal,
    this.messageCount = 0,
    this.inboundCount = 0,
    this.lastInboundAt,
    this.lastOutboundAt,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.bucket,
    this.attentionScore,
    this.unreadCount = 0,
    this.aiPendingCount = 0,
    this.attachmentCount = 0,
    this.latestDeadline,
    this.pendingDraftCount = 0,
    this.snoozedUntil,
    this.labels = const [],
    this.needsYouReason,
    this.needsYouReasonMessageId,
    this.needsYouReasonAt,
    this.replyExpected,
    this.needsYouVetoed = false,
    this.latestInboundFrom,
  });

  /// Whether this thread came from outside the owner's own organisation.
  ///
  /// **The LATEST INBOUND SENDER's domain, and nobody else's.** A thread is
  /// external when the person the inbox is waiting on writes from a domain that
  /// is not one of [ownerDomains] — so a vendor copied in on an internal thread
  /// does not tint it, and an internal reply to a vendor's mail un-tints the
  /// thread the moment a colleague answers. The alternative rule — any external
  /// participant, ever — would paint half a busy inbox and stop meaning
  /// anything.
  ///
  /// **Computed at display time and never stored.** Whose domains are "ours"
  /// is a fact about the signed-in account, not about the mail: a stored flag
  /// would be wrong for the next account to open the same database, and right
  /// only until the owner's own address changed. The cost is a string compare
  /// per drawn row, which is the same cost as the row's own `from:` filter.
  ///
  /// [ownerDomains] comes from `ownerDomainsOf(account.mail ??
  /// account.userPrincipalName)` — the one source `needs_you_handler` ranks
  /// from, so the tint and the ranking cannot disagree about who is a stranger.
  /// EMPTY — a signed-out app, and every widget test that passes nothing —
  /// answers false for every thread: an app that cannot say who the owner is
  /// does not get to call anybody external.
  bool isExternalTo(Set<String> ownerDomains) =>
      isExternalAddress(latestInboundFrom, ownerDomains);

  /// First participant — the row's primary sender. Null when a conversation
  /// somehow carries no participants.
  Participant? get primaryParticipant =>
      participants.isEmpty ? null : participants.first;

  String? get primaryEmail => primaryParticipant?.email;

  /// Whether anything on this thread is still unread. What bolds a row in
  /// Conversations.
  bool get hasUnread => unreadCount > 0;

  /// Whether the model is still working on this thread.
  bool get isAiBusy => aiPendingCount > 0;

  /// Deliberately narrow: state, unread count and labels are the only three
  /// fields a local action flips. Marking a thread done flips the state;
  /// opening one flips the count to zero; filing one under a word of the
  /// owner's puts a chip on it.
  ///
  /// Labels are here rather than in a method of their own because an empty list
  /// is a real value: taking the last label off a thread and leaving its labels
  /// alone are `[]` and null, which is exactly what an optional list says.
  Conversation copyWith({
    ConversationState? state,
    int? unreadCount,
    List<Label>? labels,
  }) {
    return Conversation(
      id: id,
      source: source,
      subject: subject,
      participants: participants,
      category: category,
      state: state ?? this.state,
      ctaText: ctaText,
      ctaUrgency: ctaUrgency,
      messageCount: messageCount,
      inboundCount: inboundCount,
      lastInboundAt: lastInboundAt,
      lastOutboundAt: lastOutboundAt,
      lastMessageAt: lastMessageAt,
      lastMessagePreview: lastMessagePreview,
      bucket: bucket,
      attentionScore: attentionScore,
      unreadCount: unreadCount ?? this.unreadCount,
      aiPendingCount: aiPendingCount,
      attachmentCount: attachmentCount,
      latestDeadline: latestDeadline,
      pendingDraftCount: pendingDraftCount,
      snoozedUntil: snoozedUntil,
      labels: labels ?? this.labels,
      needsYouReason: needsYouReason,
      needsYouReasonMessageId: needsYouReasonMessageId,
      needsYouReasonAt: needsYouReasonAt,
      replyExpected: replyExpected,
      needsYouVetoed: needsYouVetoed,
      latestInboundFrom: latestInboundFrom,
    );
  }

  /// The bucket, changed — including to null, which is the whole reason this is
  /// its own method rather than another [copyWith] parameter. Clearing a bucket
  /// and leaving one alone are opposite intentions, and an optional `String?`
  /// spells them the same way.
  Conversation withBucket(String? bucket) {
    return Conversation(
      id: id,
      source: source,
      subject: subject,
      participants: participants,
      category: category,
      state: state,
      ctaText: ctaText,
      ctaUrgency: ctaUrgency,
      messageCount: messageCount,
      inboundCount: inboundCount,
      lastInboundAt: lastInboundAt,
      lastOutboundAt: lastOutboundAt,
      lastMessageAt: lastMessageAt,
      lastMessagePreview: lastMessagePreview,
      bucket: bucket,
      attentionScore: attentionScore,
      unreadCount: unreadCount,
      aiPendingCount: aiPendingCount,
      attachmentCount: attachmentCount,
      latestDeadline: latestDeadline,
      pendingDraftCount: pendingDraftCount,
      snoozedUntil: snoozedUntil,
      labels: labels,
      needsYouReason: needsYouReason,
      needsYouReasonMessageId: needsYouReasonMessageId,
      needsYouReasonAt: needsYouReasonAt,
      replyExpected: replyExpected,
      needsYouVetoed: needsYouVetoed,
      latestInboundFrom: latestInboundFrom,
    );
  }

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final rawParticipants = json['participants'] as List<dynamic>?;
    return Conversation(
      id: json['id'] as String? ?? '',
      source: json['source'] as String? ?? 'email',
      subject: json['subject'] as String?,
      participants: [
        for (final p in rawParticipants ?? const [])
          if (p is Map<String, dynamic>) Participant.fromJson(p),
      ],
      category: json['category'] as String?,
      state: ConversationState.fromWire(json['state'] as String?),
      ctaText: json['cta_text'] as String?,
      ctaUrgency: CtaUrgency.fromWire(json['cta_urgency'] as String?),
      messageCount: (json['message_count'] as num?)?.toInt() ?? 0,
      inboundCount: (json['inbound_count'] as num?)?.toInt() ?? 0,
      lastInboundAt: json['last_inbound_at'] as String?,
      lastOutboundAt: json['last_outbound_at'] as String?,
      lastMessageAt: json['last_message_at'] as String?,
      lastMessagePreview: json['last_message_preview'] as String?,
    );
  }

  /// A row from the `conversations` table. `conversation_key` is the id here;
  /// `participants_json` is JSON-encoded TEXT.
  factory Conversation.fromRow(Map<String, Object?> row) {
    return Conversation(
      id: row['conversation_key'] as String? ?? '',
      source: row['source'] as String? ?? 'email',
      subject: row['subject'] as String?,
      participants: [
        for (final p in _decodeJsonList(row['participants_json']))
          if (p is Map<String, dynamic>) Participant.fromJson(p),
      ],
      category: row['category'] as String?,
      state: ConversationState.fromWire(row['state'] as String?),
      ctaText: row['cta_text'] as String?,
      ctaUrgency: CtaUrgency.fromWire(row['cta_urgency'] as String?),
      messageCount: (row['message_count'] as num?)?.toInt() ?? 0,
      inboundCount: (row['inbound_count'] as num?)?.toInt() ?? 0,
      lastInboundAt: row['last_inbound_at'] as String?,
      lastOutboundAt: row['last_outbound_at'] as String?,
      lastMessageAt: row['last_message_at'] as String?,
      lastMessagePreview: row['last_message_preview'] as String?,
      // Both come from the LEFT JOIN in `loadConversations`, so both are null
      // on a thread with no `conversation_ai` row and on every read that did
      // not join it.
      bucket: row['bucket'] as String?,
      attentionScore: (row['attention_score'] as num?)?.toDouble(),
      // Counted by the same query's subquery, and absent from every read that
      // does not run it — which reads as "nothing unread", never as unread.
      unreadCount: (row['unread_count'] as num?)?.toInt() ?? 0,
      // The two busy columns are one number to everything above here: the
      // user is being told the model is working, not which queue it is in.
      aiPendingCount: ((row['ai_busy_messages'] as num?)?.toInt() ?? 0) +
          ((row['ai_busy_thread'] as num?)?.toInt() ?? 0),
      // The third subquery, and absent from every read that does not run it —
      // which reads as "nothing attached", never as a paperclip on a thread
      // that has none.
      attachmentCount: (row['attachment_count'] as num?)?.toInt() ?? 0,
      // The last two subqueries, absent from every read that does not run
      // them — which reads as "no date named" and "nothing suggested", never
      // as a deadline or a badge on a thread carrying neither.
      latestDeadline: row['latest_deadline'] as String?,
      pendingDraftCount: (row['pending_draft_count'] as num?)?.toInt() ?? 0,
      // From the same LEFT JOIN the bucket comes from, and null on every read
      // that does not run it — which reads as "no date set".
      snoozedUntil: row['snoozed_until'] as String?,
      // The owner's own words, concatenated by the last subquery and absent
      // from every read that does not run it — which reads as "not filed".
      labels: Label.parseConcat(row['labels']),
      // The three reason columns travel together: one subquery picks the
      // message, and a read that does not run it carries none of them.
      needsYouReason: row['needs_you_reason'] as String?,
      needsYouReasonMessageId: row['needs_you_reason_message_id'] as String?,
      needsYouReasonAt: row['needs_you_reason_at'] as String?,
      // Null survives as null, exactly as it does on [Message.replyExpected]:
      // a message triage v2 has never judged is not a message it judged "no".
      replyExpected: _boolFromInt(row['reply_expected']),
      // The thread veto, computed by the store's one fragment; absent reads
      // as no veto.
      needsYouVetoed: _boolFromInt(row['needs_you_vetoed']) ?? false,
      // The last subquery, and null on every read that does not run it — which
      // reads as "cannot tell who this is from", and [isExternalTo] answers
      // false to that rather than calling an unknown sender a stranger.
      latestInboundFrom: row['latest_inbound_from'] as String?,
    );
  }
}

/// A message within a thread. [pendingSend] flags a locally-appended
/// optimistic outbound bubble that no store write has confirmed yet — it is
/// never set from the wire or from a row.
@immutable
class Message {
  final String id;
  final String source;
  final bool outbound;
  final String? fromName;
  final String? fromAddress;
  final List<String> to;
  final String? receivedAt;
  final String? subject;
  final String? bodyText;

  /// Whether the user has read this message, as the server last told us.
  /// Defaults to read, and stays read when the column is absent or null: a
  /// message nobody can say anything about must not be shown as new mail.
  final bool isRead;

  /// The sender-side snippet a delta page carries. Bodies are fetched one
  /// thread at a time, so this is what a message has to show for itself
  /// between landing in the list and being opened.
  final String? bodyPreview;

  /// Why the triage gate skipped this message (bulk sender, no body, …).
  final String? gateReason;

  /// The row's `has_attachments` flag, as the delta page or the detail fetch
  /// last set it. False when the column is absent or null. The meeting gate's
  /// empty-body fallback asks it: a calendar response carries no file, so an
  /// `Accepted:` mail with a PDF on it is somebody sending a document.
  final bool hasAttachments;

  /// `'user'` when the owner pressed Restore on this message, which clears
  /// [gateReason] and exempts the row from every gate. Null otherwise, and on
  /// every read that did not select the column. Reply suppression asks it, so
  /// a restored message is not refused a draft on the same classification the
  /// owner just overruled.
  final String? gateOverride;

  /// The connector-specific blob stored alongside the message — for email,
  /// `{"headers": {...}, "meeting": "…"}` from the per-message detail fetch,
  /// each key present only when that fetch had something to put in it. Held as
  /// raw JSON rather than decoded eagerly: the inbox renders thousands of
  /// messages and reads this on none of them.
  ///
  /// Read through [headers] and [meetingMessageType], never by hand: both
  /// answer for a blob that never carried their key, which is every row a
  /// build before theirs wrote.
  final String? sourceMetaJson;

  // ── Triage output ────────────────────────────────────────────────────
  final String? urgency;
  final String? category;

  /// The free-text "what is this about" label triage writes alongside
  /// [category] — a couple of words like "dinner plans" or "invoice". Null
  /// until triage has run; buckets filter, this displays.
  final String? label;
  final String? summary;
  final bool? needsAction;
  final List<String> actionItems;
  final String triageStatus;

  /// Whether this message singled the user out — sole To: recipient for mail,
  /// a 1:1 chat or an @mention for Teams. Written at ingest by the connector,
  /// so it says something about the message rather than about the model.
  /// False when nothing knows better, which is the quiet answer.
  final bool addressedMe;

  /// Whether the sender is waiting on an answer, as triage v2 judged it. Null
  /// means no v2 pass has ever judged this message — NOT "no reply expected".
  /// The two read the same to a careless caller and mean opposite things, so
  /// anything acting on this must check for null first.
  final bool? replyExpected;

  /// The date or timeframe triage read out of the message, in the sender's own
  /// words ("Friday", "before the 15th"). Null when the message named none.
  final String? deadline;

  /// The needs-you pass's verdict on this message, tri-state: true = it wants
  /// the owner, false = judged not to, null = never judged. Null is NOT false —
  /// the unjudged rows are the pass's worklist — so nothing here may collapse
  /// it into a bool.
  final bool? needsYouVerdict;

  /// Why the pass answered as it did: `'teams_direct'` from the deterministic
  /// floor, or the model's own evidence sentence. Null when nothing has judged
  /// the message, which is not the same as a verdict with no reason given.
  final String? needsYouReason;

  /// Local-only optimistic bubble.
  final bool pendingSend;

  /// What came with this message, in the order the connector listed it.
  ///
  /// Hydrated by [MessageStore.loadThread] with ONE query for the whole thread
  /// — never per message — and empty everywhere else. Empty therefore means
  /// "nobody asked", not "nothing attached", which is why nothing keys a
  /// decision off an empty list: the row reads `has_attachments` for that.
  ///
  /// [Message.fromRow] does not fill it. A `messages` row has no attachment
  /// columns and hydration needs a second query, so the store is the one place
  /// that can do it and the model stays constructible from a row alone.
  final List<AttachmentRef> attachments;

  const Message({
    required this.id,
    required this.outbound,
    this.source = 'email',
    this.fromName,
    this.fromAddress,
    this.to = const [],
    this.receivedAt,
    this.subject,
    this.bodyText,
    this.isRead = true,
    this.bodyPreview,
    this.gateReason,
    this.hasAttachments = false,
    this.gateOverride,
    this.sourceMetaJson,
    this.urgency,
    this.category,
    this.label,
    this.summary,
    this.needsAction,
    this.actionItems = const [],
    this.triageStatus = 'pending',
    this.addressedMe = false,
    this.replyExpected,
    this.deadline,
    this.needsYouVerdict,
    this.needsYouReason,
    this.pendingSend = false,
    this.attachments = const [],
  });

  bool get inbound => !outbound;

  /// Whether this row is the app's own record of a message it just sent,
  /// written before the server's copy came back — see [localEchoPrefix].
  ///
  /// It renders as an ordinary outbound message on purpose: it IS one, and the
  /// only thing provisional about it is the id, which the next sync swaps for
  /// the server's. Callers that must not act on a provisional id — anything
  /// asking Graph about a specific message — ask this first.
  bool get isLocalEcho => id.startsWith(localEchoPrefix);

  /// This message with its attachments filled in.
  ///
  /// Its own method rather than a general `copyWith` because there is exactly
  /// one caller and one field: the store, hydrating a thread it has just read.
  /// A broad copyWith on a twenty-field model is a place for a field to be
  /// silently dropped.
  Message withAttachments(List<AttachmentRef> attachments) => Message(
        id: id,
        outbound: outbound,
        source: source,
        fromName: fromName,
        fromAddress: fromAddress,
        to: to,
        receivedAt: receivedAt,
        subject: subject,
        bodyText: bodyText,
        isRead: isRead,
        bodyPreview: bodyPreview,
        gateReason: gateReason,
        hasAttachments: hasAttachments,
        gateOverride: gateOverride,
        sourceMetaJson: sourceMetaJson,
        urgency: urgency,
        category: category,
        label: label,
        summary: summary,
        needsAction: needsAction,
        actionItems: actionItems,
        triageStatus: triageStatus,
        addressedMe: addressedMe,
        replyExpected: replyExpected,
        deadline: deadline,
        needsYouVerdict: needsYouVerdict,
        needsYouReason: needsYouReason,
        pendingSend: pendingSend,
        attachments: attachments,
      );

  /// The message's wire headers, lowercase-keyed. Empty when there are none
  /// stored — which is the normal state for a message whose thread has never
  /// been opened, since headers arrive with the per-message detail fetch and
  /// not with a delta page. Readers must treat "no headers" as "unknown",
  /// never as "not a newsletter".
  ///
  /// Decoded on each read rather than cached: this class is immutable and
  /// const-constructible, and the only caller is the triage gate, which runs
  /// once per message.
  Map<String, String> get headers {
    final raw = sourceMetaJson;
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final headers = decoded['headers'];
      if (headers is! Map) return const {};
      return {
        for (final entry in headers.entries)
          entry.key.toString().toLowerCase(): entry.value?.toString() ?? '',
      };
    } on FormatException {
      return const {};
    }
  }

  /// Whether the stored body was written by an older converter and is owed a
  /// refetch — the `body_stale` key the `mail_html_rebuild_2` one-shot sets.
  ///
  /// The old text stays readable meanwhile: every stage that is not the
  /// transcript reads it as it stands, and `ensureBodies` refetches a stale
  /// row as if it had no body. Any detail answer clears the key, a 200 or a
  /// permanent refusal alike, so a message the server no longer has keeps its
  /// old text and stops being asked for. False for a blob that is null,
  /// invalid or silent about the key.
  bool get bodyStale {
    final raw = sourceMetaJson;
    if (raw == null || raw.isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      final stale = decoded['body_stale'];
      return stale == 1 || stale == true;
    } on FormatException {
      return false;
    }
  }

  /// What kind of invitation this message is, in Graph's own words —
  /// `meetingRequest`, `meetingCancelled`, `meetingAccepted` and the rest.
  ///
  /// Null on ordinary mail, on every Teams and MCP message, and on any row
  /// whose detail was fetched before the sync asked for the field: a reader
  /// must treat null as "nobody said", never as "not a meeting".
  String? get meetingMessageType {
    final raw = sourceMetaJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final meeting = decoded['meeting'];
      if (meeting is! String || meeting.isEmpty) return null;
      return meeting;
    } on FormatException {
      return null;
    }
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    final rawTo = json['to'] as List<dynamic>?;
    final rawActionItems = json['action_items'] as List<dynamic>?;
    return Message(
      id: json['id'] as String? ?? '',
      source: json['source'] as String? ?? 'email',
      outbound: (json['direction'] as String?) == 'outbound',
      fromName: json['from_name'] as String?,
      fromAddress: json['from_address'] as String?,
      to: [
        for (final t in rawTo ?? const []) t.toString(),
      ],
      receivedAt: json['received_at'] as String?,
      subject: json['subject'] as String?,
      bodyText: json['body_text'] as String?,
      isRead: json['is_read'] as bool? ?? true,
      bodyPreview: json['body_preview'] as String?,
      gateReason: json['gate_reason'] as String?,
      urgency: json['urgency'] as String?,
      category: json['category'] as String?,
      label: json['label'] as String?,
      summary: json['summary'] as String?,
      needsAction: json['needs_action'] as bool?,
      actionItems: [
        for (final a in rawActionItems ?? const []) a.toString(),
      ],
      triageStatus: json['triage_status'] as String? ?? 'pending',
      addressedMe: json['addressed_me'] as bool? ?? false,
      replyExpected: json['reply_expected'] as bool?,
      deadline: json['deadline'] as String?,
      needsYouVerdict: json['needs_you_verdict'] as bool?,
      needsYouReason: json['needs_you_reason'] as String?,
    );
  }

  /// A row from the `messages` table. `source_message_id` is the id here;
  /// `to_json` / `action_items_json` are JSON-encoded TEXT and
  /// `needs_action` / `is_read` are 0/1 integers (STRICT has no bool).
  factory Message.fromRow(Map<String, Object?> row) {
    return Message(
      id: row['source_message_id'] as String? ?? '',
      source: row['source'] as String? ?? 'email',
      outbound: (row['direction'] as String?) == 'outbound',
      fromName: row['from_name'] as String?,
      fromAddress: row['from_address'] as String?,
      to: recipientsFromJson(row['to_json']),
      receivedAt: row['received_at'] as String?,
      subject: row['subject'] as String?,
      bodyText: row['body_text'] as String?,
      // A row read without the column, or with a null in it, is read: the
      // unread grammar only ever comes from a `0` somebody wrote.
      isRead: _boolFromInt(row['is_read']) ?? true,
      bodyPreview: row['body_preview'] as String?,
      gateReason: row['gate_reason'] as String?,
      hasAttachments: _boolFromInt(row['has_attachments']) ?? false,
      gateOverride: row['gate_override'] as String?,
      sourceMetaJson: row['source_meta_json'] as String?,
      urgency: row['urgency'] as String?,
      category: row['category'] as String?,
      label: row['label'] as String?,
      summary: row['summary'] as String?,
      needsAction: _boolFromInt(row['needs_action']),
      actionItems: [
        for (final a in _decodeJsonList(row['action_items_json'])) a.toString(),
      ],
      triageStatus: row['triage_status'] as String? ?? 'pending',
      addressedMe: _boolFromInt(row['addressed_me']) ?? false,
      // Null survives as null: a row triage v2 has never judged is not a row
      // it judged "no".
      replyExpected: _boolFromInt(row['reply_expected']),
      deadline: row['deadline'] as String?,
      // Tri-state, exactly as `reply_expected` above: a row the needs-you pass
      // has never reached is not a row it judged "no", and the Why panel says
      // which of the two it is looking at.
      needsYouVerdict: _boolFromInt(row['needs_you_verdict']),
      needsYouReason: row['needs_you_reason'] as String?,
    );
  }
}

/// What the triage model returns for one inbound message. The store writes
/// these fields onto the message row.
@immutable
class TriageResult {
  final String urgency;
  final String category;

  /// A couple of free-text words naming what the message is about ("dinner
  /// plans", "invoice"). Empty when the model offered none — the store writes
  /// it as-is, and an empty label renders as no label.
  final String label;
  final String summary;
  final bool needsAction;
  final List<String> actionItems;

  /// Whether the sender is waiting on an answer from the owner. Stored as the
  /// message's `reply_expected`, which is what turns a NULL (never judged by
  /// v2) into a judgement.
  final bool replyExpected;

  /// The date or timeframe the message named, in its own words. Empty when it
  /// named none — the store writes that as NULL, the same rule [label] takes.
  final String deadline;

  const TriageResult({
    required this.urgency,
    required this.category,
    this.label = '',
    required this.summary,
    required this.needsAction,
    required this.actionItems,
    this.replyExpected = false,
    this.deadline = '',
  });

  /// What a message gets when the model fails or answers unparseably: the
  /// quiet middle. Never a guess that would push mail up the list.
  factory TriageResult.fallback() => const TriageResult(
        urgency: 'normal',
        category: 'other',
        label: '',
        summary: '',
        needsAction: false,
        actionItems: [],
        replyExpected: false,
        deadline: '',
      );

  /// This result with the classification fields replaced — how the triage
  /// queue lays the decision model's answers over the text call's.
  TriageResult copyWith({
    String? urgency,
    String? category,
    bool? needsAction,
    bool? replyExpected,
  }) =>
      TriageResult(
        urgency: urgency ?? this.urgency,
        category: category ?? this.category,
        label: label,
        summary: summary,
        needsAction: needsAction ?? this.needsAction,
        actionItems: actionItems,
        replyExpected: replyExpected ?? this.replyExpected,
        deadline: deadline,
      );

  factory TriageResult.fromJson(Map<String, dynamic> json) {
    final rawActionItems = json['action_items'] as List<dynamic>?;
    return TriageResult(
      urgency: json['urgency'] as String? ?? 'normal',
      category: json['category'] as String? ?? 'other',
      label: json['label'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      needsAction: json['needs_action'] as bool? ?? false,
      actionItems: [
        for (final a in rawActionItems ?? const []) a.toString(),
      ],
      replyExpected: json['reply_expected'] as bool? ?? false,
      deadline: json['deadline'] as String? ?? '',
    );
  }
}

/// The activity panel's header numbers, computed over one window of
/// `activity_events` by [MessageStore.activityStats].
///
/// Everything here is derived — the rows are the truth — which is why this is
/// a plain value object with no logic beyond holding what the queries found.
@immutable
class ActivityStats {
  /// New messages ingested per source over the window: `'email' → 42`.
  final Map<String, int> ingestedBySource;

  /// AI work rows by kind then status: `'triage' → {'ok': 30, 'error': 2}`.
  final Map<String, Map<String, int>> byKind;

  /// Mean wall-clock milliseconds per successful item, by kind.
  final Map<String, int> avgMsByKind;

  /// Median of the same — the number to trust when one pathological message
  /// drags the mean.
  final Map<String, int> medianMsByKind;

  /// Rows whose status is `error`. Parks are deliberately not errors: a model
  /// server that is not running is a state, not a failure.
  final int errorCount;

  /// AI work rows in the window, every status counted.
  final int aiItemCount;

  const ActivityStats({
    this.ingestedBySource = const {},
    this.byKind = const {},
    this.avgMsByKind = const {},
    this.medianMsByKind = const {},
    this.errorCount = 0,
    this.aiItemCount = 0,
  });
}
