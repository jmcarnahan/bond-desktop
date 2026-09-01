/// The Teams chats this app reads and writes: the chat list, one chat's
/// members, a chat's messages since a cursor, the read viewpoint, and a reply.
/// Nothing here touches sqlite — `TeamsSync` and `DraftNotifier` own the writes.
///
/// **Nothing here may be called from a timer.** Microsoft's terms for the Teams
/// messaging endpoints forbid background polling: every call must trace back to
/// something the user did. The reads are made only by `TeamsSync`, which
/// enforces that; the two writes below need no enforcing, because a send is a
/// button press and a read-ack is queued by the act of opening a thread — a
/// write is a user action by construction, which is exactly why it is allowed
/// here at all.
///
/// Channel messages are deliberately absent: reading a team's channels needs
/// tenant-wide admin consent this app does not ask for, while 1:1 and group
/// chats need only delegated `Chat.Read`.
abstract class TeamsBackend {
  /// The signed-in user's id — the one field that decides whether a chat
  /// message is the user's own. Fetched per sync and held by the caller in
  /// memory rather than stored.
  Future<String> myUserId();

  /// Every chat the user is in, newest activity first, across at most
  /// [maxPages] pages.
  Future<List<Map<String, dynamic>>> listChats({int maxPages = 4});

  /// One chat's members — enough to name the thread and its participants.
  Future<List<Map<String, dynamic>>> chatMembers(String chatId);

  /// One chat's messages, newest first, back to [sinceIso].
  ///
  /// A null or empty [sinceIso] takes exactly ONE page: a chat the app has
  /// never seen starts from its newest messages, and reaching further back
  /// would spend requests on history the user has already read.
  ///
  /// With a cursor the walk runs until the FILTERED set is exhausted, because
  /// the caller advances its cursor to the newest message returned — a page cap
  /// that stopped the walk early would advance that cursor over messages never
  /// fetched, a permanent hole in the transcript. [maxPages] is only a runaway
  /// bound, and hitting it must be logged, because it means exactly such a hole.
  Future<List<Map<String, dynamic>>> chatMessagesSince(
    String chatId,
    String? sinceIso, {
    int maxPages = 40,
  });

  /// Marks a chat read for the signed-in user, up to its newest message.
  ///
  /// Per CHAT, not per message: Teams read state is a viewpoint on the
  /// conversation, so there is nothing here to enumerate. Requires
  /// `chat.readwrite`; callers gate on the grant before calling.
  Future<void> markChatRead(String chatId);

  /// Posts a plain-text message to a chat, and returns it as stored.
  ///
  /// The returned message carries the id and timestamps Graph assigned, which
  /// is what lets the caller write the outbound row itself instead of waiting
  /// for the next user-triggered pull to discover its own reply. Its shape is
  /// the one [chatMessagesSince] hands back, so the row built from it is the
  /// row a sync would have built.
  Future<Map<String, dynamic>> sendChatMessage(String chatId, String text);
}
