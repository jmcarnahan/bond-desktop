# 1 · Sync / ingest

**What happens.** A sync pass pulls the Microsoft Graph delta (mail via
`sync_service.dart`, Teams chats via `teams_sync.dart`), upserts message rows,
and stamps cheap derived fields — notably `addressed_me`. It then enqueues all
downstream work: `enqueueExtractBacklog` and `enqueueEmbedBacklog` write work
rows for messages that lack extraction or vectors, and
`requeueWork('storyline_sweep')` revives the clustering pass. Last, one
`context_reconcile` item per REGISTERED context directory, under source
`local` — the folders the owner registered are re-read on every pass, linked
or not, so the index follows a project that keeps changing
([13-context-directories.md](13-context-directories.md)). Enqueueing is
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

**Windows and caps.** How far back a sync reaches is a preference — **one day**
by default, set in Settings → Sync & data — and the AI pipeline reads that same
window: mail inside the lookback is triaged, extracted, judged and embedded,
with no separate AI window behind it. A first sync on a new machine is
therefore a morning's mail; a stored choice is untouched by the default. The
backlog enqueue files at most
`backlogEnqueueCap` (150) rows per queue per pass, but skips messages that
already have a work row, so a deep window drains across passes rather than
being truncated to its newest 150. Work in flight is re-queued at the next
launch, so a restart loses nothing. Teams carries its own lookback in the same
Settings section, defaulting to the same one day: a chat's first fetch reaches
back to that floor through a server-side date filter rather than taking one
page of its newest messages. Two limits bound that walk and both are logged
when hit — the chat list stops at 200 chats (4 pages of 50), and one chat's
message walk stops at 40 pages. Both windows are set by the **How far back to
sync** pair at the top of Settings → Sync & data — a preset per source or a
custom `YYYY-MM-DD` date, with the calendar day the window reaches spelled out
under it (see [../settings.md](../settings.md)).

**After a clear.** Settings → Processing → **Clear AI results** empties the
work table along with every other derived table, re-pends the messages the
pipeline had gated, and queues the whole rerun itself, in the same
transaction: one `attachment_text` row per attachment left `pending` (there is
no backlog call for that kind anywhere), and then extraction, the needs-you
judgement and the embedding for **every** kept message of every source in
`messages` — unpaced and with no window, one statement per kind per source.
The reset does not leave this to the sync, and that is the point. The three
backlog calls pass the **lookback floor** as their `sinceIso`, which is right
for a poll — new mail arrives inside the window — but a reset is the one path
that re-pends messages *outside* it, a corpus pulled down under a wider window
and narrowed since. Left to the sync, those messages were triaged and then
never extracted, judged or embedded again. The sync's own paced calls and
`requeueSweep()` still run on **every** pass and are `OR IGNORE`-idempotent
over what the reset filed, so a poll after a clear adds only genuinely new
mail; the triage drain claims the re-pended rows on its own; and the worker
still refuses an extract or needs-you item whose message triage has not spoken
about, so the order the stages run in is unchanged. The verdicts ingest wrote
(`outbound`, `backlog`, and Teams' `auto_generated` and `teams_source`)
survive the clear, because nothing in a later pass would write them again, and
so does the owner's own `user` reason from Ignore; every other gate reason is
re-derived at the next triage claim. Those kept verdicts leave their rows
`skipped`, which is what keeps them off all three queues. See
[../settings.md](../settings.md) → Processing.

**Paging and re-entry.** A window-asking drain — first run, widen, 410
recovery — sends its `min_received` floor on EVERY `sync_mail` page, not just
the first. The Bond MCP server enforces the floor as a hard cap per page, but
only on pages it is told the floor for, so a continuation that dropped it would
let the server walk past the window (`sync_paging_guard_test`). Incremental
passes send no floor; the cursor drives them. The server also answers
`has_more`, defined on its side as "a `next_cursor` is set"; `DeltaPage.hasMore`
records it as contract, and the loop itself keeps paging on the presence of the
next cursor, the only thing a further page can be fetched with. `syncNow` on
both services carries an in-flight latch: the inbox polls every 60 s, a deep
pass can outlast that, and a second pass over the same MCP session used to end
in `Broken pipe`. A re-entrant call JOINS the pass in flight rather than
returning at once — `load` arms notifications and reloads when its sync comes
back, and a no-op return would arm them a minute into a long first drain and
announce the rest of the backlog as new mail. The latch clears with the pass,
success or failure, so a failed pass never silences the next one.

**Catch-up and revive.** Every pass ends with a block of cheap statements that
put back what an outage, a crash or a race left behind: `reviveErroredTriage`
and `reviveErroredWork` for what failed, `reclaimStaleTriage` /
`reclaimStaleWork` for claims nobody is holding, and `reviveTerminalTriage` /
`reviveTerminalWork` for one more try a day past those ceilings. Three more
join them here.

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

`reviveOwedMessageStages` heals what no window can reach any more: mail
triaged inside the bootstrap window whose extract, needs-you and embed work
the rolling floor overtook before the paced enqueue got there. It reads "owed"
off the progress row (triage done, extract still pending, outcome pending, not
dropped, a kept inbound), so a row it re-offers is one the next sync does not
repeat. It files `extract`, `needs_you` and `embed_message` rows with
`INSERT OR IGNORE`, the embed arm only where no vector exists, at most
the cap that sync's own backlog enqueue uses, per kind per pass:
`backlogEnqueueCap` (150) for mail, `TeamsSync._extractCap` (100) for Teams.
Both syncs call it after their embed backlog, and it reports `revived_owed_work` (the extract count; the two
twins ride along) only when it queued any. See
[04-extraction.md](04-extraction.md) and [11-needs-you.md](11-needs-you.md).

The one-shot `needs_you_flag_backfill` runs once, beside the other one-shots,
raising the Needs You chip on rows that settled before the verdict column
existed. It reports `backfilled_needs_you` (see
[11-needs-you.md](11-needs-you.md)). Its lowering twin, `needs_you_flag_veto`,
runs once beside it and clears the settled chips that stood on triage's ask
before a judged no was allowed to outrank it (`lowerVetoedNeedsYou`, ticking
each row), reported as `vetoed_needs_you`. After them, `needs_you_hedge_rejudge`
re-queues needs-you work once for every in-window inbound mail and chat
message whose verdict is 0 (`requeueZeroNeedsYouVerdicts`), because earlier
builds stored a hedge as 0 and a hedge is NULL now; it reports
`requeued_needs_you_hedges` and Clear AI results does not reset it. Every one-shot marker is deleted by
`wipeAll`, so a sign-out-and-wipe lets them run again on the next account.

`rependGatedTriage` — the Teams sync's catch-up for the retired `teams_source`
gate — now resets the progress rows it re-pends in the same transaction. A
re-pended message is about to be triaged again, and the gate cascade left on
its row would otherwise read as a finished pipeline. The mail sync calls it
once more under the `label_rule_gate_retired` one-shot: the label rules were
removed in 2026-09 (schema v19), so a message the old `label_rule` gate skipped
would never be looked at again. Before the backlog enqueues, it re-pends those
rows for email and Teams inside this pass's floor, and reports
`repended_label_rule_gates`.

**Reconcile.** The delta feed is trusted for position, and has still been
seen to skip a message: on one day two of nine inbound messages never appeared
on any page, and a fresh enumeration hours later found both. Nobody has a cause
for it, so this is a safety net rather than a fix. Every `reconcileEvery`
(10 minutes) the mail pass re-enumerates the last `reconcileWindow` (24 hours)
of `inbox` and `sentitems` from scratch — no cursor, a `receivedDateTime ge`
filter, walking `nextLink` itself — and ingests through the same idempotent
page path, so anything already stored is neither counted nor re-folded.

Since the default lookback became one day, that 24-hour window is the same
size as the default sync window. On a fresh install the reconcile therefore
re-enumerates the whole window every ten minutes, and what it finds lands at or
just below the midnight-truncated floor. It is idempotent and cursor-free, so
the cost is the enumeration rather than any double ingest.

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

**What the fold reads.** The thread state machine
(`app/lib/services/conversation_state.dart`) folds only the messages the gate
KEPT. An inbound the gate throws out AT INSERT — mail from behind the sync
floor, stored `skipped`/`backlog`; a Teams bot's line under `auto_generated` —
is history being backfilled rather than news, so both ingests pass it to
`foldMessage` as `historical`: watermarks, counts, preview and subject move,
the state does not. A thread must not be made to ask for a reply to a message
no stage of this app will ever read. The rule is INBOUND-ONLY: every outbound
is born `skipped`/`outbound`, and reading that stamp as a gate would make every
reply historical and no thread would ever settle. `resolvesAsk` is unchanged
for the same reason.

A gate that speaks AFTER ingest tells the thread through
`MessageStore.refoldThreadState`, in one direction — see
[02-gates.md](02-gates.md). The one-shot `thread_state_refold` repairs the rows
written before the fold learned to wait for the gate, walking every
`needs_reply` thread on every connector with the lowering rule and reporting
`refolded_threads` on the `sync_mail` event.

Two more one-shots repair stored text and verdicts that a later rule would
have written differently. `meeting_regate_crlf` gates the meeting RESPONSES
already in the mailbox (`regateMeetingResponses`, then a refold when it gated
any), because a gate only speaks about a message on its way past. The key is
the second one: the first pass read Exchange's `\r\n` empty body as somebody
talking and gated none of the fallback-shape rows. It reports
`regated_meeting_responses`. `meeting_detail_backfill` (MCP only, once the
calendar mirror's first full read has been swept) re-fetches the detail of up
to 200 likely meeting messages from the last 30 days that were stored before
`read_email` sent the meeting fields, then re-gates the same way; a failed
pass stays owed (`attempt:<n>`) and the third failure closes it.
It reports `backfilled_meetings` ([14-calendar.md](14-calendar.md)).
`plan_relative_banner_strip` takes a trailing
plan-relative "— by Day 1" off the stored ask banners through
`showableDeadline` (`stripPlanRelativeBanners`), reported as
`stripped_plan_relative_banners` (see [08-attention.md](08-attention.md)).

Beside `thread_state_refold`, the one-shot `gated_conversation_repair` walks what a late
gate leaves BUILT rather than what it leaves said: every conversation carrying
an embedding whose inbound messages were all gated loses that embedding, its
automatic storyline memberships and its pending `storyline` row. It walks at
most `GateRepairService.oneShotCap` (200) threads per sync and the pref is
set only when a pass comes back short of the cap, so a mailbox that raced
hundreds of threads before the claim invariant heals over a few syncs rather
than stalling one. It runs before the sweep is requeued, so the sweep reads
the cleaned pool, and reports `repaired_gated_conversations` on the
`sync_mail` event. See [02-gates.md](02-gates.md).

Four more one-shots beside them, added in Round F, carry the SEARCH corpora
onto the current embedding tag: one slice a sync of stale message vectors
re-queued for `embed_message`, of attachment passages nulled and re-queued for
`attachment_text`, and of directory passages nulled for the reconcile that is
already filed below, plus a single uncapped pass that nulls every skill
description vector. Each has its own pref and each runs on every sync until its
own pref closes, unlike the clustering walk above, which takes one slice a sync
across all of its tags. They report `requeued_message_embeds`,
`requeued_attachment_embeds`, `cleared_passage_embeds` and
`cleared_description_embeds` on the `sync_mail` event, counts only and only on
a pass that moved something. See [05-embeddings.md](05-embeddings.md).

**Threading.** Everything downstream keys threads by `(source,
conversationKey)` — a mail thread and a chat with colliding keys can never
interleave (PR #9).

**Who is on a thread.** The fold writes `conversations.participants_json` as
`{name, email}` objects: the SENDER of every inbound message, and the To:
recipients of every outbound one — never the user. `_recipients` carries the
display name off `toRecipients` alongside the address, so a colleague the user
wrote to is stored under their name rather than as a bare address; without it
an outbound-only thread showed an address in the thread header, in the
recent-people typeahead and on that colleague's own row under People.
`addParticipant` fills a name in on an address already stored nameless, so a
later message names somebody an earlier one left bare. A recipient with no
address is dropped — there is nothing to key a participant on. Nothing is
looked up per recipient at ingest: the loop stays query-free.

`messages.to_json` is a separate column and a separate shape — a list of
address STRINGS, which `recipientsFromJson` and the local-echo path both read
that way. Names ride in `participants_json` and nowhere else.

A one-off behind the `participant_names_backfill` pref fills the stored rows
that predate this build. `MessageStore.fillParticipantNames` builds
address → name once, from every participant that carries both and then from
the newest `from_name` per address, rewrites only the conversations it actually
fills, and is idempotent — a second run changes nothing and moves no
`updated_at`. It is reported as `named_participants` on the sync's activity
row.

**One row builder per channel.** `SyncService.mailRow` and
`TeamsSync.messageRow` are the only places a message becomes a `messages` row.
Both are public statics because the send paths call them too — a locally
written reply and the copy the next drain folds in must agree on every column.

**Teams senders.** A chat sender's name is a ladder in `TeamsSync._sender`:
the `displayName` Graph gave, then `Bot` for an application it named nothing,
then `Unknown sender` for a message with no `from` at all. A PERSON with no
name keeps a null name, so the roster does not list two `Unknown sender`
entries. Rows stored before the ladder are fixed at display time by
`displaySenderName` and `isBotSender` (`app/lib/services/sender_display.dart`),
which never show a `teams:` pseudo-address.

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
flag (`messages.has_attachments`) rides the mail delta page and is the
handlers' cue to hydrate a message's attachment rows; the list card's 📎
count reads the rows themselves (`attachment_count` in `loadConversations`),
so for mail it appears once the detail fetch has written them. The attachment LIST arrives later
and differently per connector: mail writes rows inside `_fetchDetailInto`,
because the detail fetch is the first moment a list exists; chat writes them
in `_ingestChat`'s insert loop, because chat has no detail step. A Teams
quote-reply arrives as a `message_reference` entry, and its quote lands on the
columns mail's `item` rows own: `item_from` is who was quoted, `card_text` the
snippet and `content_id` the quoted message's id. It is a quote, not a file
(see [12-attachments.md](12-attachments.md)). Teams still sets
`has_attachments` for a quote-only message. No paperclip or file count reads
that flag: the handlers read it only as the cue to hydrate a message's
attachment rows, which is how the quote reaches their prompts. Both then
queue `attachment_text` work for the rows the text policy accepts — and only
that kind, since a digest of a document nobody has extracted yet is a call
that can only fail. Rows are written on EVERY sighting, not only the first: an
edit can add a file, and the upsert preserves everything the handlers and the
owner wrote.

**The body is converted here.** The Graph detail fetch asks for HTML
(`Prefer: outlook.body-content-type="html"` in `graph_mail.dart`), because
Graph's own text conversion writes `label <href>` for every anchor and `[alt]`
for every image, and in automated mail that noise is most of the message.
`_fetchDetailInto` is the one conversion site: `mailBodyFromDetail`
(`app/lib/services/mail_body.dart`) reads the connector's `contentType`, runs
HTML through the mail profile of the core in `app/lib/services/html_text.dart`,
and only tidies a body that arrived as text, which is what the MCP server
sends. The mail profile's rules, each pinned by a test:

- **Source whitespace is HTML whitespace.** Between tags, a run of
  `[\t\r\n ]` folds to one space; tags stay as written, and so do the blocks
  whose source newlines are their layout: `<pre>`, `<textarea>`, and a div,
  span, p, td, th, li, code, blockquote, font, section or article whose inline
  `style` sets `white-space: pre`, `pre-wrap` or `pre-line` (ticketing and CI
  mailers write comment bodies that way). A styled block is found one opener
  at a time, its style read from that tag's own text, and its closer looked
  for no further than the next opener of the same name, so an element nested
  inside another of the same name ends the outer one's protection. That is
  what keeps the fold linear on hostile input, such as one tag repeating
  `style=` a thousand times. Exchange's plain-text mail (`line<br>\r\n`) is therefore
  single-spaced. The fold runs in the document profile too.
- **Entities.** `decodeHtmlEntities` knows all 252 HTML 4.01 named entities
  plus `&apos;`, case-sensitively, in ONE pass: a replacement is never scanned
  again, so `&amp;rsquo;` stays `&rsquo;`. An unknown name stays as typed, and
  `&nbsp;` is a plain space.
- **Divs and breaks.** A run of div boundaries is one newline (`_mailDivRun`);
  a `<div><br></div>` keeps the blank line its `<br>` writes, and `<p>` keeps
  its paragraph gap.
- **Links** become `label <url>` runs through `canonicalLinkRun`. The href
  drops tab, CR and LF the way a browser does. A label that is the address
  again prints once, an anchor with no label (a linked logo) drops whole, and
  an unopenable target keeps only the label. A Safe Links wrapper with no label, or
  a URL-shaped one, gets a label rebuilt from the address it carries; a
  worded label keeps its words.
- **Deceptive labels yield.** A URL-looking label whose HOST differs from the
  href's host is replaced by the href; a label carrying userinfo names no
  host, so it yields too. An email label over a `mailto:` for a different
  address yields. A label on the same host with another path keeps its words.
  A bare domain such as `bank.example` is not read as a claim, because
  `Report.xlsx` looks the same; the transcript's hover caption shows the real
  host instead. A Safe Links wrapper is read through to the address it
  carries, so a readable label built from a wrapper is not a claim against
  the wrapper's own host. The rule is ONE function, `labelClaimsOtherHost`, and the
  painter (`linkSpansOf` in `linked_text.dart`) applies it again to every
  stored `label <url>` run, because a body also reaches the transcript as
  escaped text, as Graph's own conversion on the MCP connection, and from
  Teams. A bare address followed at once by ` <url>` paints as one link
  labelled with the address, under the same host rule.
- **Pictures.** An inline `cid:` image becomes a `[cid:X]` token the
  transcript splices the bytes onto; its id is entity-decoded once, like a
  link run's label and target. Every other image is dropped with no
  placeholder. U+200B is kept, because it delimits Outlook's attach-as-link
  runs.
- **Bounded input.** Before either profile's cap, any attribute value of 8 KB
  or more inside an opening tag is blanked (text between tags is never
  touched, so a long token in a `<pre>` log stays), so a `data:` download link or a style `url(data:…)`
  leaves no megabytes of base64 behind. Mail is then cut to `htmlInputCap`
  (2 Mi characters) after scripts,
  styles and pictures are dropped, so a base64 chart costs nothing; the cut
  backs off to a tag start within 64 Ki characters and never splits a surrogate pair.
  The attachment preview caps with `capProse: true`, and context extraction
  never caps. Every tag pattern is `[^<>]*`, and the comment, `<pre>`, anchor
  and open-head bodies cannot run past a later opener, so malformed input
  stays linear.

The mail detail fetch also REWRITES the body it stores. Outlook's "attach as
link" is not in Graph's attachment list at all — it is a zero-width-space
delimited run in the body — so `_fetchDetailInto` parses it out
(`owa_links.dart`), replaces the run with an `[[att:<id>]]` marker, writes a
`reference` row numbered after the connector's own, and raises
`has_attachments` even though the message said `hasAttachments: false`. See
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

The tenant's "External Email … use caution" banner goes the same way:
`stripExternalBanner` removes it from the head of the text, and nowhere else,
in the tidy step both paths share. The delta page's `bodyPreview` is Graph's
own text conversion whatever the detail prefers, so the preview is tidied and
link-stripped (`stripLinkTargets`) at ingest: a list card has two lines, and
the label is the snippet.

A body that converts to nothing, such as a notification that is one linked
image, is SETTLED rather than stored empty (`_settledEmptyBody`). An empty
body is what `ensureBodies` reads as "no body stored", so every open would
fetch it again. The stored preview becomes the body, or a single space when
there is not even a preview. A row that already holds words is the
exception: that is a stale body (below) whose refetch came back empty, and
`_settledEmptyBody` keeps the words it has rather than a preview or a space.

The detail's `$select` also asks for `meetingMessageType`, Graph's word for
the kind of invitation. It is stored under `meeting` in `source_meta_json`
beside `headers`, each key omitted when it has nothing to say; the
meeting-response gate reads it ([02-gates.md](02-gates.md)). In MCP mode the
backend maps `read_email`'s `meeting_message_type` onto the same key and adds
`calendarEventId`, stored as `event_id` — the link from a message to its
calendar event ([14-calendar.md](14-calendar.md)).

Two one-shots repair what earlier builds stored, and neither stamps
`messages.updated_at`, so the keyword index keeps the old text until a
refetch replaces it (see [05-embeddings.md](05-embeddings.md)).
`mail_html_rebuild_2` MARKS old bodies rather than nulling them
(`markStaleMailBodies`, reported as `stale_mail_bodies`): it sets
`body_stale` in `source_meta_json` and leaves the text where it is. A body
nulled first would be lost for good whenever the refetch cannot answer,
because Graph ids are not immutable here and a message filed in Outlook
since ingest now 404s. The marks are what an older conversion left and a
person does not: a `<http` run, a ` <mailto:` run, a `[cid:` token, a blank
line, or a literal named entity. The key superseded the first
`mail_html_rebuild`, because the first converter kept the source's CR/LF
beside every `<br>` newline, double-spacing plain-text mail, and decoded only
seven entities. It skips `local:` echoes, whose id the detail fetch refuses
so the mark could never clear, and marks rows the pipeline still owes work on
like any other, since nothing loses text now. `ensureBodies` refetches a
stale row exactly as it does one with no body. Any 200 clears the mark
(`updateMessageDetail`) and replaces the body only when words came back; a
403, 404 or 410 clears it through `clearBodyStale` and keeps the old text;
a transient error keeps the mark so the next open tries again. Every other
reader, the stages, the index and the prompts, reads the old text meanwhile.
The verdicts and summaries written from it are not re-judged: that is Clear
AI results, an owner decision. `mail_preview_tidy` rewrites the stored previews,
on messages and conversations, through the same link rules
(`tidyMailPreviews`), reported as `tidied_mail_previews`.
