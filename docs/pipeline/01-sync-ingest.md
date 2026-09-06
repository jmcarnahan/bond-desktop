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
owner wrote. See [12-attachments.md](12-attachments.md).
