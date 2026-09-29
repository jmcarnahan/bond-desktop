import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:drift/drift.dart' show Variable;

/// A triaged row as the pipeline leaves it once BOTH stages have spoken: the
/// decision's classification ([MessageStore.writeTriage]) and the message
/// text ([MessageStore.writeMessageText]). The one seed for a test that wants
/// a summary, action items or a deadline on a row — `writeTriage` writes the
/// classification only since the decision-model round.
///
/// [label] is written straight to the column: nothing in the app writes one
/// any more, and a test that needs an old row's label says so here.
Future<void> writeTriaged(
  MessageStore store,
  String source,
  String sourceMessageId, {
  required String status,
  String urgency = 'normal',
  String category = 'other',
  String label = '',
  String summary = '',
  bool needsAction = false,
  List<String> actionItems = const [],
  bool replyExpected = false,
  String deadline = '',
  String? error,
  String? gateReason,
  int? attempts,
}) async {
  await store.writeTriage(
    source,
    sourceMessageId,
    status: status,
    result: TriageResult(
      urgency: urgency,
      category: category,
      needsAction: needsAction,
      replyExpected: replyExpected,
    ),
    error: error,
    gateReason: gateReason,
    attempts: attempts,
  );
  await store.writeMessageText(
    source,
    sourceMessageId,
    summary: summary,
    actionItems: actionItems,
    deadline: deadline,
  );
  if (label.isNotEmpty) {
    await store.db.customUpdate(
      'UPDATE messages SET label = ? '
      'WHERE source = ? AND source_message_id = ?',
      variables: [
        Variable<String>(label),
        Variable<String>(source),
        Variable<String>(sourceMessageId),
      ],
    );
  }
}

/// A kept message the decision model says needs the owner: `triaged`, with
/// [p] in `needs_you_p` — over the slider's default unless a test says
/// otherwise.
///
/// Triaged as well as decided, because a widget test's triage queue decides a
/// `pending` message with no owner line, and a probability decided without
/// the owner is cleared rather than trusted: a seed that left the row pending
/// would watch its thread leave Needs You a few pumps in.
Future<void> seedNeedsYou(
  MessageStore store,
  String source,
  String sourceMessageId, {
  double p = 0.9,
  String? reason,
}) async {
  await store.writeTriage(source, sourceMessageId, status: 'triaged');
  await store.writeNeedsYouP(source, sourceMessageId, p: p, reason: reason);
}
