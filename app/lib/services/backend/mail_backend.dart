import 'backend_types.dart';

/// The mail reads and draft writes this app makes. Nothing here touches
/// sqlite — `SyncService` owns the writes.
///
/// Auth failures pass through UNWRAPPED. [NotSignedIn] and [ReconsentRequired]
/// mean the session is over and the UI must route to sign-in; a plain
/// [AuthException] is transient. Wrapping any of them in a backend's own
/// exception type would erase that distinction.
abstract class MailBackend {
  /// One page of the delta drain for [folder] ('inbox', 'sentitems').
  ///
  /// [link] is an opaque cursor from a previous page and is fetched VERBATIM —
  /// it already carries the select and filter the drain started with, and
  /// rebuilding it would silently change the query mid-drain.
  /// [minReceivedIso] applies only to a drain starting from scratch.
  ///
  /// Throws [DeltaResyncRequired] when the cursor is older than the server's
  /// change history and only a fresh drain can recover.
  Future<DeltaPage> deltaPage(
    String folder, {
    String? link,
    String? minReceivedIso,
  });

  /// The full body and headers for one message.
  Future<Map<String, dynamic>> getMessageDetail(String id);

  /// Creates a draft reply to [messageId] in the user's Drafts folder.
  ///
  /// The server builds the reply, which is the whole reason it is done this
  /// way — the recipients, the subject, the In-Reply-To and References headers
  /// and the quoted thread all come from the message being replied to, and none
  /// of them are this app's to reconstruct. The response must carry `id` to
  /// fill in and send, and `webLink` to hand to Outlook when this app may only
  /// save drafts.
  Future<Map<String, dynamic>> createReplyDraft(String messageId);

  /// Replaces a draft's body with [text].
  ///
  /// Plain text, always: the composer is a plain-text field, and sending its
  /// contents as HTML would turn every `<` a person typed into markup.
  Future<void> updateDraftBody(String draftId, String text);

  /// Sends an existing draft. Nothing in this app calls this except a Send
  /// button the user pressed.
  Future<void> sendDraft(String draftId);

  /// Marks messages read (or unread) on the server.
  ///
  /// A best-effort ACK of a decision the local store has already made: the
  /// caller has flipped its own rows and is telling Microsoft afterwards.
  /// Returns the ids it could not update — a message deleted between the open
  /// and the ack is gone, not failed, and is NOT in the returned list; only
  /// ids worth retrying come back.
  Future<List<String>> markRead(List<String> messageIds, {bool isRead = true});
}
