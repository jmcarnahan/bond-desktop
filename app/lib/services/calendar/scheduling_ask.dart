import '../../data/message_store.dart';
import '../decision/decision_policy.dart';

/// Which threads are asking for a time (docs/pipeline/14-calendar.md "Find a
/// time").
///
/// The signal is the decision model's, read back from `message_decisions`:
/// the thread's NEWEST inbound message has `intent = scheduling` at
/// p ≥ [DecisionPolicy.booleanYes], the thread still needs a reply, and the
/// owner has not written since that message. Nothing here calls a model — a
/// thread the decision model never read is simply not a scheduling ask.
///
/// The rule has ONE spelling, the store's query
/// ([MessageStore.schedulingAskConversations]); the app and the tests both
/// read it through [schedulingAskKeys].

/// The `'$source|$id'` keys of every scheduling ask, newest first, at most
/// [limit] of them — for the Day stop's group and the thread header. One
/// query, whatever the number of threads.
Future<Set<String>> schedulingAskKeys(
  MessageStore store, {
  int limit = 200,
}) async {
  final asks = await store.schedulingAskConversations(
    limit: limit,
    threshold: DecisionPolicy.booleanYes,
  );
  return {
    for (final a in asks) schedulingAskKey(a.source, a.conversationKey),
  };
}

/// Every scheduling ask by its `'$source|$id'` key, with the id of the
/// thread's NEWEST inbound message — the one the rule read, and the one an
/// invite or a dismiss labels (`MessageStore.writeSchedulingAskLabel`).
/// What `schedulingAsksProvider` holds.
Future<Map<String, String>> schedulingAskMessageIds(
  MessageStore store, {
  int limit = 200,
}) async {
  final asks = await store.schedulingAskConversations(
    limit: limit,
    threshold: DecisionPolicy.booleanYes,
  );
  return {
    for (final a in asks)
      schedulingAskKey(a.source, a.conversationKey): a.sourceMessageId,
  };
}

/// The key [schedulingAskKeys] answers with.
String schedulingAskKey(String source, String id) => '$source|$id';
