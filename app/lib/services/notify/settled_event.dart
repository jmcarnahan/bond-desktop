import 'package:flutter/foundation.dart';

import '../../models/message_models.dart';

/// One message finished the pipeline and earned a mention.
///
/// This is THE settle event: it is emitted once per notified message, by
/// [NotificationCoordinator] and nothing else, and every consumer downstream —
/// the in-app ribbon, the OS notification dispatcher — reads this same object.
/// Nothing else in the app may declare a second settle event; a second one
/// would be a second definition of "the user has been told", and the whole
/// point of the state machine behind this is that there is exactly one.
///
/// It is a snapshot, not a handle: the fields are what was true at the moment
/// the row settled, so a consumer that renders it minutes later shows what the
/// user was told, not what the thread has since become.
@immutable
class MessageSettled {
  final String source;
  final String sourceMessageId;
  final String conversationKey;

  /// What to call the message: its subject, or the sender's name when it has
  /// none. Null only when the message carried neither.
  final String? title;

  final String? summary;
  final String? ctaText;
  final CtaUrgency ctaUrgency;
  final String? urgency;
  final String? deadline;
  final bool replyExpected;

  /// The storyline this thread belongs to, when that is known. Null carries
  /// two different meanings, and [settledOnDeadline] is what tells them apart:
  /// on a complete settle it means "no storyline"; on a deadline settle it
  /// means "not known yet" — the storyline pass may still be running.
  final String? storylineId;
  final String? storylineTitle;

  final double? attentionScore;
  final String? receivedAt;
  final String settledAt;

  /// True when the deadline ran out before the pipeline finished, so this was
  /// settled on whatever verdicts existed at that moment rather than on a
  /// complete set of them.
  final bool settledOnDeadline;

  const MessageSettled({
    required this.source,
    required this.sourceMessageId,
    required this.conversationKey,
    required this.settledAt,
    this.title,
    this.summary,
    this.ctaText,
    this.ctaUrgency = CtaUrgency.normal,
    this.urgency,
    this.deadline,
    this.replyExpected = false,
    this.storylineId,
    this.storylineTitle,
    this.attentionScore,
    this.receivedAt,
    this.settledOnDeadline = false,
  });

  /// The coalescing key: the thread this belongs to. Three messages landing on
  /// one conversation are one thing that happened, not three, and the ribbon
  /// dedupes on exactly this.
  String get key => '$source/$conversationKey';
}
