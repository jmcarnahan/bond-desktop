import 'message_models.dart';

/// Whether a thread still owes an answer, message by message.
///
/// Thread-level `cta_text` is overwritten by the newest triage, so an earlier
/// message's ask vanishes when a new one lands. The per-message triage fields
/// survive, and these read them back.
///
/// One reply answers everything before it — the same semantics the CTA already
/// clears under when a synced reply arrives.

/// The latest outbound `receivedAt` in [thread], as the lexicographic max over
/// ISO-8601 strings. Null when no outbound message carries a timestamp.
String? latestOutboundAt(List<Message> thread) {
  String? latest;
  for (final m in thread) {
    if (!m.outbound) continue;
    final at = m.receivedAt;
    if (at == null) continue;
    if (latest == null || at.compareTo(latest) > 0) latest = at;
  }
  return latest;
}

/// Whether [m]'s ask is still open.
///
/// [lastOutboundAt] is [latestOutboundAt] over the same thread: "some outbound
/// lands after m" is equivalent to "the latest outbound lands after m", so one
/// timestamp answers it for every message in the thread.
///
/// [Message.needsAction] and [Message.replyExpected] are tristate — NULL means
/// no pass has judged the message, which is not an ask. Hence `== true` and
/// never `!= false`.
bool hasOpenAsk(
  Message m, {
  required String? lastOutboundAt,
  required bool conversationDone,
}) {
  if (conversationDone) return false;
  if (!m.inbound) return false;
  if (m.needsAction != true && m.replyExpected != true) return false;
  if (lastOutboundAt == null) return true;
  // Strict: an outbound at the same instant did not answer this one. A message
  // with no timestamp cannot be ordered, so any timestamped reply closes it.
  return lastOutboundAt.compareTo(m.receivedAt ?? '') <= 0;
}

/// How many of [thread]'s asks are still open.
int openAskCount(List<Message> thread, {required bool conversationDone}) {
  final lastOut = latestOutboundAt(thread);
  var count = 0;
  for (final m in thread) {
    if (hasOpenAsk(m,
        lastOutboundAt: lastOut, conversationDone: conversationDone)) {
      count++;
    }
  }
  return count;
}
