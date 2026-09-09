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
  enqueue block at the end of a pass, and the reconcile
  (`_reconcileIfDue` / `_reconcileFolder`, and the `persistCursor` flag on
  `_drain` that keeps it off the cursor).
- `app/lib/services/teams_sync.dart` — the Teams twin of the same sequence.
- `app/lib/data/message_store.dart` — `enqueueWork`, `enqueueExtractBacklog`,
  `requeueWork` and the doc comments distinguishing them (why storylines need
  the revive path rather than a plain enqueue).

**Windows and caps.** How far back a sync reaches is a preference — 14 days by
default, set in Settings → Sync & data — and the AI pipeline reads that same
window: mail inside the lookback is triaged, extracted, judged and embedded,
with no separate 7-day AI window behind it. The backlog enqueue files at most
`backlogEnqueueCap` (150) rows per queue per pass, but skips messages that
already have a work row, so a deep window drains across passes rather than
being truncated to its newest 150. Work in flight is re-queued at the next
launch, so a restart loses nothing. Teams carries its own lookback in the same
Settings section, defaulting to the same 14 days: a chat's first fetch reaches
back to that floor through a server-side date filter rather than taking one
page of its newest messages. Two limits bound that walk and both are logged
when hit — the chat list stops at 200 chats (4 pages of 50), and one chat's
message walk stops at 40 pages. Both windows are set by the **How far back to
sync** pair at the top of Settings → Sync & data — a preset per source or a
custom `YYYY-MM-DD` date, with the calendar day the window reaches spelled out
under it (see [../settings.md](../settings.md)).

**Catch-up and revive.** Every pass ends with a block of cheap statements that
put back what an outage, a crash or a race left behind: `reviveErroredTriage`
and `reviveErroredWork` for what failed, `reclaimStaleTriage` /
`reclaimStaleWork` for claims nobody is holding, and `reviveTerminalTriage` /
`reviveTerminalWork` for one more try a day past those ceilings. Two more join
them here.

`reviveOwedStorylineStages` heals the settle race. The notification
coordinator can settle a message in the middle of a sync — before this pass's
own enqueue has run — leaving the row with `settle_state = 'done'` and
`storyline_state` still `pending`, and an `outcome` that will never close
behind it. Both syncs call it (mail and Teams, since the race is not
mail-specific), it requeues the `storyline` work for each stuck conversation,
and it reports `revived_storyline` on the sync event only when it found any.
`dropped = 0` keeps a gate cascade out of it; the loosened guard on
`writeStorylineProgress` is what lets the pass it queues actually land (see
[09-notifications.md](09-notifications.md)).

The one-shot `needs_you_flag_backfill` runs once, beside the other one-shots,
raising the Needs You chip on rows that settled before the verdict column
existed. It reports `backfilled_needs_you` (see
[11-needs-you.md](11-needs-you.md)). Every one-shot marker is deleted by
`wipeAll`, so a sign-out-and-wipe lets them run again on the next account.

`rependGatedTriage` — the Teams sync's catch-up for the retired `teams_source`
gate — now resets the progress rows it re-pends in the same transaction. A
re-pended message is about to be triaged again, and the gate cascade left on
its row would otherwise read as a finished pipeline.

**Reconcile.** The delta feed is trusted for position, and has still been
seen to skip a message: on one day two of nine inbound messages never appeared
on any page, and a fresh enumeration hours later found both. Nobody has a cause
for it, so this is a safety net rather than a fix. Every `reconcileEvery`
(10 minutes) the mail pass re-enumerates the last `reconcileWindow` (24 hours)
of `inbox` and `sentitems` from scratch — no cursor, a `receivedDateTime ge`
filter, walking `nextLink` itself — and ingests through the same idempotent
page path, so anything already stored is neither counted nor re-folded.

What it never does is the point. It never calls `setDeltaLink`, so the folder's
delta position, its `synced_at` and the vacation rule that reads that stamp are
all untouched — storing the deltaLink such a walk returns would rewind the
cursor to now and skip every change behind it. It never runs more than once per
ten minutes, on a `mail_last_reconcile` preference that is stamped after the
attempt whether it succeeded or failed, so a persistently failing reconcile
retries on the cadence rather than on every sixty-second poll. And it never
takes the sync down: a 410 or a network failure inside it is caught, logged as
`reconcile_error` on the (still `ok`) `sync_mail` event, and the pass carries
on to its enqueues.

What it reports is nothing at all when it finds nothing, which is the normal
state. When it does find something, `reconciled: k` rides on the `sync_mail`
event and a `sync_reconcile` event names the subjects (at most ten). Settings →
Sync & data carries a **Mail reconcile** row beside the mail stamp, so a reader
can see the net is alive even on the passes it writes no row for.

Reconciled messages take the ordinary path: `pending` triage (or `backlog`
below the floor), and their `extract` / `needs_you` / `embed` rows filed by the
backlog enqueue in this same pass. Because that enqueue runs after the drains,
they settle on the notification coordinator's deadline like any other message
rather than immediately.

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

It also takes off what the sender never wrote. Exchange prepends its
first-contact safety tip — *You don't often get email from …. Learn why this
is important<…>* — to the BODY of the first mail from any new sender, and
the delta page's `bodyPreview` opens with the same words.
`stripSenderIdentification` (`app/lib/services/mail_text.dart`) removes it
from both at ingest, at the head of the text only (a person quoting the
banner wrote those words on purpose), so the transcript, the preview, the
search index and every prompt see the sender's own first sentence. A one-off
behind the `sender_tip_strip` pref rewrites the rows stored before this
build, reported as `stripped_sender_tips` on the sync's activity row; it
moves `updated_at` with the text so the keyword index refiles them.
