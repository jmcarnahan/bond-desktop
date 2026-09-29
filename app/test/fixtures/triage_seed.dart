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
