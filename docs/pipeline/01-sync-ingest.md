# 1 · Sync / ingest

**What happens.** A sync pass pulls the Microsoft Graph delta (mail via
`sync_service.dart`, Teams chats via `teams_sync.dart`), upserts message rows,
and stamps cheap derived fields — notably `addressed_me`. It then enqueues all
downstream work: `enqueueExtractBacklog` and `enqueueEmbedBacklog` write work
rows for messages that lack extraction or vectors, and
`requeueWork('storyline_sweep')` revives the clustering pass. Enqueueing is
idempotent — re-syncing the same window writes no duplicate work.

**No model call.** Sync is the only stage that touches the network for
Microsoft data; everything after it runs against local rows.

**Code.**
- `app/lib/services/sync_service.dart` — mail delta, window choice, the
  enqueue block at the end of a pass.
- `app/lib/services/teams_sync.dart` — the Teams twin of the same sequence.
- `app/lib/data/message_store.dart` — `enqueueWork`, `enqueueExtractBacklog`,
  `requeueWork` and the doc comments distinguishing them (why storylines need
  the revive path rather than a plain enqueue).

**Windows and caps.** First run syncs 14 days of mail and queues the newest
7 days for triage, capped at 150 messages. Work in flight is re-queued at the
next launch, so a restart loses nothing.

**Threading.** Everything downstream keys threads by `(source,
conversationKey)` — a mail thread and a chat with colliding keys can never
interleave (PR #9).

**One row builder per channel.** `SyncService.mailRow` and
`TeamsSync.messageRow` are the only places a message becomes a `messages` row.
Both are public statics because the send paths call them too — a locally
written reply and the copy the next drain folds in must agree on every column.

**Local echo rows.** A mail reply sent from this app is written immediately,
under the id `local:<draftId>`, by `mailEchoRow`
(`app/lib/services/mail_echo.dart`) through `MessageStore.insertLocalEcho`.
It carries the `internet_message_id` that `send_draft` reported, which is the
same one the Sent Items copy will carry — the copy's `id` differs, because the
draft the app sent no longer exists.

Reconciliation happens inside the Sent Items page transaction. `_ingestPage`
reads `MessageStore.pendingEchoInternetMessageIds` once per page — one indexed
read, empty on every drain but the one after a send — and for each outbound
message whose `internetMessageId` is in that set calls
`MessageStore.deleteLocalEcho` before asking `hasMessage`. The echo and its
`message_progress` row go, the real row lands as a true first sighting, and it
folds like any other sent copy. No reader ever sees both.

`insertLocalEcho` is the other half: the 60 s poll has no re-entrancy guard, so
a sync already in flight can ingest the real copy *before* the echo is written.
It checks, in one transaction, for a non-`local:` row with the same
`internet_message_id` and declines to write when it finds one.

`deleteLocalEcho` is the only `DELETE FROM messages` in the app, and both of
its statements are guarded by the key range `>= 'local:' AND < 'local;'` —
exactly "starts with `local:`", written as a range rather than a LIKE so the
primary key serves it (SQLite will not use a BINARY index for a
case-insensitive LIKE, and a per-message scan of the source was minutes on a
first sync).
