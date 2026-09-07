import '../data/message_store.dart';
import 'mail_echo.dart' show firstLine;
import 'teams_sync.dart' show TeamsSync;

/// The writes a chat message this app just posted owes the database, in one
/// place so the reply arm and the compose screen cannot disagree about them.
///
/// Extracted from `DraftNotifier._sendChat` when compose-new arrived: a chat
/// post is the one send in this app that stores its own transcript row, and
/// two copies of "which row, folded how" is exactly how a composed message
/// would start landing in the rail differently from a reply to the same chat.

/// Writes the row for a chat message this app just posted, and folds the
/// conversation it belongs to.
///
/// The row is built from what Graph handed back, id and all — the same builder
/// the pull uses — so the next pull recognises the id and folds the message as
/// history rather than as news that reopens the thread.
///
/// Returns the row written, or null when [sent] is not a chat message: a shape
/// this app cannot store. The send still went, so that is not a failure — the
/// next pull writes the transcript entry this one could not.
Future<Map<String, Object?>?> writeOutboundChatRow(
  MessageStore store,
  Map<String, dynamic> sent,
  String chatId,
  String text,
) async {
  final row = TeamsSync.messageRow(sent, chatId, outbound: true);
  if (row == null) return null;
  await store.upsertMessage(row);
  // The fold, not just the counts: the rail orders by `last_message_at` and
  // shows `last_message_preview`, so recounting alone left a chat the user had
  // just answered sitting where it was, previewing the question. Nothing would
  // ever have corrected it — the next pull skips this row as already seen.
  await store.foldOutboundSend(
    'teams',
    chatId,
    receivedAt: row['received_at'] as String?,
    preview: firstLine(text),
  );
  await queueRecapFor(store, 'teams', chatId);
  return row;
}

/// Wakes the recap of every storyline this thread is filed in, because the
/// user just changed the answer to the question a recap exists to ask.
///
/// Called from BOTH send arms, because both write a row no ingest will
/// announce. The chat reply is written with the id Graph assigned and the next
/// pull deliberately skips it as already-known; the mail echo is written under
/// a `local:` id the drain has never heard of and then quietly deleted when the
/// real copy lands. Neither ever reaches
/// [MessageStore.staleRecapStorylineIds] on its own.
///
/// That catch-up is what covers every OTHER outbound row: a reply sent from
/// Outlook or from Teams itself arrives on a pull, and every sync ends by
/// requeueing `storyline_sweep`, whose recap handler drains later in the same
/// pass. Wiring a per-message requeue into the mail ingest would buy nothing
/// and would cost a query per message inside the page transaction, on first
/// syncs that can run to six figures.
///
/// Mirrors `ExtractHandler._queueRecap`, label included — `requeueWork` is
/// keyed on `(kind, source, entity_id)`, and 'email' is the label
/// `StorylineService` writes storyline work under for BOTH connectors.
Future<void> queueRecapFor(
  MessageStore store,
  String source,
  String conversationKey,
) async {
  for (final storylineId
      in await store.storylineIdsFor(source, conversationKey)) {
    if (storylineId.isEmpty) continue;
    await store.requeueWork('storyline_recap', 'email', storylineId);
  }
}
