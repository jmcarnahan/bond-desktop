import '../data/message_store.dart';
import 'deadline_parse.dart' show showableDeadline;

/// A conversation row's CTA is one line in a list, and the model was told to
/// write imperatives — this is a backstop, not a formatting step.
const int conversationCtaCap = 200;

/// Copies one message's verdict up onto its conversation — the CTA line, its
/// urgency and the category — but only when the message is the thread's
/// newest inbound, and only while the owner has not already replied to it.
///
/// ONE function, two callers, because the fold now happens in two steps. The
/// triage queue calls it the moment the decision model has spoken, with the
/// row's urgency and category and whatever text the row already holds. On a
/// new message there is none yet ([textLanded] false): the urgency and the
/// category land and the thread's current ask is LEFT as it is, rather than
/// cleared for the seconds the text call takes (a cleared ask drops the
/// thread out of Needs You and back). The message-text handler calls it
/// again WHEN THE TEXT LANDS, with the action items, summary and deadline it
/// just wrote, and that write decides the ask — including clearing it when
/// the message asks for nothing.
///
/// Without the newest-inbound check a backlog would end up showing the wrong
/// ask: the drains run newest-first, so an older message finishing later
/// would overwrite a current CTA with one from last week.
///
/// Without the already-replied check a RE-run would resurrect a dead ask.
/// Ingest clears the CTA on exactly the outbound that answers it
/// (`outboundResolves`); anything that sends the same message through again
/// afterwards — a re-judgment backfill, an error revive, a reply that lands
/// before the first drain gets there — would write that ask straight back,
/// along with the urgency multiplier that pushes an answered thread into
/// Needs You. The tie goes to the reply, matching `outboundResolves`: an
/// outbound at the same instant as the inbound counts as the answer.
///
/// [row] is the message's stored row; only `conversation_key` and
/// `received_at` are read off it.
Future<void> foldCtaUp(
  MessageStore store,
  String source,
  Map<String, Object?> row, {
  required String urgency,
  String? category,
  required bool needsAction,
  String summary = '',
  List<String> actionItems = const [],
  String deadline = '',
  bool textLanded = true,
  DateTime? now,
}) async {
  final key = row['conversation_key'] as String?;
  if (key == null || key.isEmpty) return;
  final conversation = await store.getConversationRow(source, key);
  if (conversation == null) return;

  final receivedAt = row['received_at'] as String? ?? '';
  final lastInbound = conversation['last_inbound_at'] as String?;
  if (lastInbound != null &&
      lastInbound.isNotEmpty &&
      receivedAt.compareTo(lastInbound) < 0) {
    return;
  }

  final lastOutbound = conversation['last_outbound_at'] as String?;
  if (lastOutbound != null &&
      lastOutbound.isNotEmpty &&
      lastOutbound.compareTo(receivedAt) >= 0) {
    return;
  }

  if (!textLanded) {
    await store.updateConversationTriage(
      source,
      key,
      ctaUrgency: urgency,
      category: category,
      keepCtaText: true,
    );
    return;
  }
  await store.updateConversationTriage(
    source,
    key,
    ctaText: ctaTextFor(
      summary: summary,
      actionItems: actionItems,
      needsAction: needsAction,
      deadline: deadline,
      now: now ?? DateTime.now(),
    ),
    ctaUrgency: urgency,
    category: category,
  );
}

/// The CTA line for one message, or null when it asks for nothing.
///
/// The first action item is the ask, in the imperative the model was asked
/// for. With no items, a summary stands in only when the message actually
/// needs something — a summary shown as a CTA on mail that needs nothing
/// reads as work that isn't there.
///
/// The deadline rides the banner for free — "Send the invoice — by Friday" is
/// the line the row wanted anyway. Appended BEFORE the clamp, so the pair
/// stays honest: a long ask loses its own tail rather than ending up with a
/// deadline the cap would have cut in half. Through [showableDeadline],
/// because this WRITES the banner: "— by Day 1" stamped here would outlive
/// every display-time filter.
String? ctaTextFor({
  required String summary,
  required List<String> actionItems,
  required bool needsAction,
  required String deadline,
  required DateTime now,
}) {
  var ask = actionItems.isNotEmpty
      ? actionItems.first
      : (needsAction ? summary : null);
  if (ask == null || ask.isEmpty) return null;
  final showable = showableDeadline(deadline, now: now);
  if (showable != null) ask = '$ask — by $showable';
  return ask.length > conversationCtaCap
      ? ask.substring(0, conversationCtaCap)
      : ask;
}
