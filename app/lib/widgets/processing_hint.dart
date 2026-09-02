import '../models/message_models.dart';

/// Whether a row should say the model is still working on it.
///
/// Two conditions, and the second one is the whole design. A fresh mailbox
/// lands about 150 mail and 100 chats at once, every one of them pending, and
/// a busy count alone would light up every row in the app on first run —
/// which reads as a hung application rather than as work in progress. The
/// rail's "Triaging N remaining…" caption already owns the backlog story and
/// tells it once; this tells the per-thread story, and only for mail that
/// arrived while the user was watching.
///
/// [since] is the session start, so a null one — every widget test that has
/// not opted in — shows nothing at all.
bool showsProcessing(Conversation c, {required DateTime? since}) {
  if (c.aiPendingCount <= 0) return false;
  if (since == null) return false;
  final last = DateTime.tryParse(c.lastMessageAt ?? '');
  if (last == null) return false;
  return last.isAfter(since);
}
