import '../../data/message_store.dart';
import '../decision/decision_policy.dart';

/// Which threads are asking for a time (docs/pipeline/14-calendar.md "Find a
/// time").
///
/// The signal is the decision model's or the owner's, read back from the
/// store. Either way the owner has not written since the thread's NEWEST
/// inbound message and has not closed the ask (no `scheduling_ask` label
/// `no` on that message — an invite sent from it, or a dismiss); then EITHER
/// that message has `intent = scheduling` at p ≥ [DecisionPolicy.booleanYes]
/// in `message_decisions` and the thread still needs a reply, OR the owner
/// pressed the thread bar's Find a time, a `scheduling_ask` label `yes` on
/// that message (`MessageStore.reopenSchedulingAsk`, which also clears an
/// earlier `no` there: the owner's newer word wins). Every label is pinned
/// to the message by id, so a later inbound message is judged afresh.
/// Nothing here calls a model — a thread the decision model never read is an
/// ask only on the owner's word.
///
/// The rule has ONE spelling, the store's query
/// ([MessageStore.schedulingAskConversations]); the app and the tests read
/// it through [schedulingAskMessageIds] (`schedulingAsksProvider`).

/// Every scheduling ask by its `'$source|$id'` key ([schedulingAskKey]),
/// newest first, at most [limit] of them, each with the id of the thread's
/// NEWEST inbound message — the one the rule read, and the one an invite or
/// a dismiss labels (`MessageStore.writeSchedulingAskLabel`) and an owner's
/// press of Find a time says yes about. One query, whatever the number of
/// threads. What `schedulingAsksProvider` holds.
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

/// The key [schedulingAskMessageIds] answers with.
String schedulingAskKey(String source, String id) => '$source|$id';
