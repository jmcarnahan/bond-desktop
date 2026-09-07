/// The local echo of a mail message this app just sent.
///
/// A sent draft is gone from Drafts and not yet in Sent Items, and the drain
/// that will fetch the Sent Items copy runs at most once a minute. Without a
/// row written here, a reply is invisible for a minute or two after the user
/// watched it leave — which reads as "it did not send" and gets sent twice.
///
/// So the send writes its own row, keyed `local:<draftId>`, from what the
/// server said went out. Three properties make that safe rather than a lie the
/// database has to live with:
///
/// - **It is a real row, not a bubble.** It survives a restart, and a thread
///   opened later reads it like any other outbound message.
/// - **It is reconcilable.** It carries the `internet_message_id` the Sent
///   Items copy will carry too, and the mail drain deletes it — inside the
///   page transaction, before the real row is written — through
///   `MessageStore.deleteLocalEcho`. The real copy then folds as a first
///   sighting, exactly as a reply sent from Outlook would.
/// - **It cannot arrive second.** `MessageStore.insertLocalEcho` refuses to
///   write when the real copy has already landed, which a poll in flight
///   during the send can make happen.
///
/// The row itself is built by [SyncService.mailRow], the same builder the
/// drain uses, so the echo and the copy that replaces it cannot disagree about
/// columns.
library;

import '../models/message_models.dart' show localEchoPrefix;
import 'backend/backend_types.dart';
import 'gates.dart';
import 'sync_service.dart';

// Re-exported so a caller that reasons about echoes imports one file. The
// constant itself is defined with the models — see the note on it there.
export '../models/message_models.dart' show localEchoPrefix;

/// [text]'s first non-empty line, trimmed and capped at [max] characters.
///
/// A preview is a row in a list, not a paragraph: the rail shows one line and
/// the transcript has the body. Empty in, empty out.
String firstLine(String text, {int max = 200}) {
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    return trimmed.length > max ? trimmed.substring(0, max) : trimmed;
  }
  return '';
}

/// Now, as `yyyy-MM-ddTHH:mm:ssZ`.
///
/// Seconds and a `Z`, which is the shape Graph prints `receivedDateTime` in —
/// and the only shape this may be written in. `received_at` is compared as a
/// STRING by every fold in the app, so a stamp carrying fractional digits
/// (`…:16.000Z`) would sort after mail that arrived a second later (`…:17Z`)
/// and leave the thread asking for a reply that had already gone.
///
/// Only a fallback: the server's own `sent_at` is preferred wherever there is
/// one, because it is the clock the Sent Items copy will be stamped by.
String nowSecondsZ() =>
    '${DateTime.now().toUtc().toIso8601String().split('.').first}Z';

/// The `messages` row for a reply that just went out.
///
/// The gate verdict comes from [triageStatusOnInsert] rather than a literal,
/// so the echo is gated by the same rule that gates the Sent Items copy —
/// `('skipped', 'outbound')`, which keeps it out of triage, extraction and the
/// home feed. The user's own mail has never needed the model's time.
///
/// Read, because the user wrote it. [owner] may be null — a thin `/me`, a
/// keychain that would not open — and an echo with no sender renders as `You`
/// like every other outbound row, so nothing is lost by tolerating it.
Map<String, Object?> mailEchoRow({
  required SentDraft sent,
  required String text,
  required String conversationKey,
  required AccountInfo? owner,
}) {
  final (triageStatus, gateReason) = triageStatusOnInsert(outbound: true);
  return SyncService.mailRow(
    id: '$localEchoPrefix${sent.draftId}',
    internetMessageId: sent.internetMessageId,
    conversationKey: conversationKey,
    direction: 'outbound',
    subject: sent.subject,
    fromName: owner?.displayName,
    fromAddress: owner?.mail ?? owner?.userPrincipalName,
    // Addresses only: there is no column for a recipient's display name, and
    // Cc is not stored at all — the Sent Items copy carries no cc either.
    to: [for (final recipient in sent.to) recipient.address],
    receivedAt: sent.sentAt ?? nowSecondsZ(),
    isRead: true,
    bodyPreview: firstLine(text),
    // The one thing the echo has that a delta page does not: the body was
    // typed on this machine. `ensureBodies` only fetches rows without one, so
    // this row is never dialled out for.
    bodyText: text,
    triageStatus: triageStatus,
    gateReason: gateReason,
  );
}
