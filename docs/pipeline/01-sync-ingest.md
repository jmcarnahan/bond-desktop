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
It carries the `internet_message_id` that `manage_draft(action="send")`
reported, which is the same one the Sent Items copy will carry — the copy's
`id` differs, because the draft the app sent no longer exists.

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

An echo's id is on no server, and two paths refuse it by name: the detail
fetch (`_fetchDetailInto`, which every body fetch goes through) returns
without a call, and Restore leaves the row untouched — it is gated `outbound`
like any Sent Items copy, so the Dropped tab lists it for the minute it
exists, but reviving it would queue work on a row the next drain deletes.

**Attachments.** Sync is where a message learns what came with it. The
paperclip (`messages.has_attachments`) rides the mail delta page, so a list
card shows it before any body is fetched. The attachment LIST arrives later
and differently per connector: mail writes rows inside `_fetchDetailInto`,
because the detail fetch is the first moment a list exists; chat writes them
in `_ingestChat`'s insert loop, because chat has no detail step. Both then
queue `attachment_text` work for the rows the text policy accepts — and only
that kind, since a digest of a document nobody has extracted yet is a call
that can only fail. Rows are written on EVERY sighting, not only the first: an
edit can add a file, and the upsert preserves everything the handlers and the
owner wrote.

The mail detail fetch also REWRITES the body it stores. Outlook's "attach as
link" is not in Graph's attachment list at all — it is a zero-width-space
delimited run in the body — so `_fetchDetailInto` parses it out
(`owa_links.dart`), replaces the run with an `[[att:<id>]]` marker, writes a
`reference` row numbered after the connector's own, and raises the paperclip
even though the message said `hasAttachments: false`. See
[12-attachments.md](12-attachments.md).
