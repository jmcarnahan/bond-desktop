import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

/// Wire/row models for the inbox. Hand-written and deliberately defensive:
/// every field reads through a nullable cast with a default, so neither a
/// drifting API payload nor a half-written sqlite row can throw during a
/// render. Timestamps stay ISO [String]s — they are displayed and sorted,
/// never arithmetic'd.
///
/// Ported from a sibling app's conversation models, minus the fields this
/// inbox has no use for (campaign, relevance, suggestions, attachments).

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

/// sqlite has no bool: STRICT columns hold 0/1 integers. Null stays null —
/// "not triaged yet" is not the same as "no action needed".
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
  });

  /// First participant — the row's primary sender. Null when a conversation
  /// somehow carries no participants.
  Participant? get primaryParticipant =>
      participants.isEmpty ? null : participants.first;

  String? get primaryEmail => primaryParticipant?.email;

  /// Whether anything on this thread is still unread. What bolds a row in
  /// Conversations.
  bool get hasUnread => unreadCount > 0;

  /// Deliberately narrow: state and unread count are the only two fields a
  /// local action flips. Marking a thread done flips the state; opening one
  /// flips the count to zero.
  Conversation copyWith({ConversationState? state, int? unreadCount}) {
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

  /// The connector-specific blob stored alongside the message — for email,
  /// `{"headers": {...}}` from the per-message detail fetch. Held as raw JSON
  /// rather than decoded eagerly: the inbox renders thousands of messages and
  /// reads this on none of them.
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

  /// Local-only optimistic bubble.
  final bool pendingSend;

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
    this.pendingSend = false,
  });

  bool get inbound => !outbound;

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
      to: [
        for (final t in _decodeJsonList(row['to_json'])) t.toString(),
      ],
      receivedAt: row['received_at'] as String?,
      subject: row['subject'] as String?,
      bodyText: row['body_text'] as String?,
      // A row read without the column, or with a null in it, is read: the
      // unread grammar only ever comes from a `0` somebody wrote.
      isRead: _boolFromInt(row['is_read']) ?? true,
      bodyPreview: row['body_preview'] as String?,
      gateReason: row['gate_reason'] as String?,
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
