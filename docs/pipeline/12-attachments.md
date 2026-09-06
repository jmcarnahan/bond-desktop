# 12 · Attachments

**What happens.** Every message records what came with it. The mail sync
learns an attachment list from the per-message detail fetch; the Teams sync
learns one at ingest, because chat has no detail step. Both write
`attachments` rows and queue the eligible ones for text extraction.

**No model call at this stage.** Discovering an attachment costs one already-
planned Graph read and a local write. Triage sees names and sizes; nothing
waits for a download.

> **Live.** All three stages run: the metadata stage inside stage 1, then
> `attachment_text` (Graph plus the embedding server, no chat model) and
> `attachment_digest` (one fast-slot call per document). What is still to come
> is what USES them — retrieval into replies, recap lines, and the needs-you
> re-verdict on a document that asks for something.

## The data model

Three tables, split by lifetime and size (`app/lib/data/schema.drift`, schema
v13).

| Table | Holds | Written by |
|---|---|---|
| `attachments` | the metadata a row draws and the text policy judges on | both syncs, on every sighting |
| `attachment_text` | the extracted words, up to 200 K chars | the text handler |
| `attachment_chunks` | the embedded passages, and the source of truth for the chunk vectors | the text handler, then the digest handler |

The primary key is `(source, source_message_id, attachment_id)` — the
connector's own identity for the file. Mail uses the Graph attachment id;
Teams uses the entry id, or the **hosted-content id** for an image pasted into
the body.

Two column conventions carry weight:

- **`size` is 0 for unknown, never NULL.** The Teams wire never states a size,
  and `upsertAttachments` raises it with `MAX(excluded.size, attachments.size)`
  so a later byte fetch can learn one without a null check at every call site.
- **A re-sync updates the connector's metadata and nothing else.** The
  `text_*`, `digest_*`, `blob_*`, `thumb_path` and `pinned_storyline_id`
  columns belong to the handlers and to the owner. A delta page coming round
  again must not cost a document its extracted words or a person their pin.

`Conversation.attachmentCount` is a scalar subquery in `loadConversations`,
counting **non-inline** rows over the thread's messages — the same pattern
`unreadCount` takes, and for the same reason: the attachments are the truth,
and a maintained counter would drift with nothing to correct it.
`Message.attachments` is hydrated by `loadThread` with ONE query per thread,
never one per message. A handler that read a SINGLE row with `getMessageRow`
gets no such hydration, so triage, needs-you, extraction and drafting each
hydrate the message they judge — `MessageStore.attachmentRefsFor`, guarded on
the row's own `has_attachments` — before it reaches a prompt builder. Without
that, a chat message whose whole body is a marker arrives at the model empty.

## Markers: where a file sat in a chat sentence

Teams writes a shared file into the message body as
`<attachment id="…"></attachment>` and a pasted screenshot as an `<img>`
pointing at the hosted-content endpoint. `stripChatHtml` used to delete both,
which stored a file-only message as an empty body and a screenshot as nothing
at all.

It now replaces them, **before any tag stripping**, with markers:

```
[[att:<attachment id>]]     a shared file
[[img:<hosted content id>]] an inline or pasted image
```

The markers survive into `messages.body_text`, so the stored body records
WHERE in the sentence the file was. Everything downstream owns its own view of
that:

- **`body_preview` is built from the marker-stripped text** — a list card and
  a recap line must never show a token nobody typed.
- **Every place a body reaches a model or an embedding calls
  `stripAttachmentMarkers`** (`app/lib/services/attachments/attachment_markers.dart`):
  `buildMessageBlock`, the triage thread tail, `DraftTask._formatMessage`,
  `ReplyDecisionTask._body`, `NeedsYouTask._body`, `_recapLine`, and
  `embedMessageRow` — which is the ONE place the shared search-card path is
  stripped, so `ExtractHandler` and `EmbedHandler` cannot produce different
  cards and different hashes for the same message. That change gives every
  marker-bearing Teams message a new `cardHash` and costs one slow re-embed
  drain (see [05-embeddings.md](05-embeddings.md)).
- **A body carrying no marker is returned byte for byte.** The whitespace
  tidying only runs on a body that actually lost a marker; ordinary mail, where
  a run of spaces is a numbered list, is never rewritten.
- **`textSearchMessages` does NOT strip.** It reads the stored column with a
  LIKE, and a marker in it matches nothing a person would type.

A body that is nothing BUT markers gets a synthesised stand-in
(`attachmentStandIn` in `message_block.dart`): a rendered card's text if there
is one, else `Shared a file: <names>`, else `Shared an image`. Otherwise the
model would be told the message said nothing, which is the opposite of true.

## The text policy

`app/lib/services/attachments/attachment_policy.dart` is the ONLY place the
judgement is made, and it is pure and total. Both syncs ask it before queuing
work; both handlers ask it again after claiming an item, because a message can
be gated between those two moments.

| Refusal | Why |
|---|---|
| `gated` | triage skipped the message — except a chat, which is born `skipped` under `teams_source` |
| `kind_<k>` | only `file`, `item` and `reference` carry a document |
| `inline` | a signature logo is not what a message is about |
| `small_image` | under 20 KB: decoration, a social icon, a tracking pixel |
| `too_large` | over 25 MB, refused before a fetch rather than after one |
| `reference_no_url` | a link attachment with nowhere to fetch from — see below |
| `over_cap` | the sixth attachment by the connector's own ordinal |

Outbound messages ARE processed: the owner's own documents are usually the
most quotable thing on a thread.

The work-queue id is `'<message id>|<attachment id>'`
(`attachmentEntityId` / `splitAttachmentEntityId`). `|` appears in neither
half — a Graph attachment id and a hosted-content id are base64url, a Teams
message id is decimal.

## The known hole: reference attachments have no url

**Every mail reference (OneDrive-link) attachment arrives with
`source_url = NULL` today**, on both backends, so the policy refuses it as
`reference_no_url` and it renders as a chip that says "link".

Neither path asks Graph for the property: the MCP server's
`ATTACHMENT_LIST_SELECT` omits it, and `sourceUrl` is declared on the
`referenceAttachment` subtype and is not reachable through the SDK path's
`$expand` either. The code path is built and the refusal is named, so the fix
is a one-line bond-mcps change
(`ATTACHMENT_LIST_SELECT += ",microsoft.graph.referenceAttachment/sourceUrl"`)
after which the desktop needs no change at all.

Related: **a bare `contentId` in the SDK's `$expand` is a Graph 400.** It is
written in the cast form, `microsoft.graph.fileAttachment/contentId`, and the
error names no field, so a hand that "simplifies" it gets a broken request
that reads as a broken request.

## Where the two connectors meet

Both backends hand the sync the SAME flat, snake_case entries, and the sync
knows about neither.

- **Mail.** `McpMailBackend.getMessageDetail` passes the server's `attachments`
  list through untouched — the server's flat summary IS the shape the columns
  are named after. `GraphMail.getMessageDetail` expands Graph's own
  `attachments[]` and flattens it into that shape (`_attachmentSummaries`),
  reading `kind` off the `@odata.type` tail.
- **Chat.** `McpTeamsBackend` passes the server's entries through — this is the
  one key deliberately NOT re-nested into Graph's shape, because the server's
  list is strictly richer: it has already merged the body's inline images in.
  `GraphTeams.attachmentEntries` produces the same list from Graph's
  `attachments[]` plus one `image` entry per `hostedContentIds(body)` (which
  lives in `attachment_markers.dart` with the regex it shares with the
  stripper, so a backend never imports the sync), and
  `chatMessagesSince` applies it to every raw message before returning, so
  `TeamsSync` reads one shape.

`TeamsSync.attachmentRows` turns either backend's entries into store rows.
It is a separate static from `TeamsSync.messageRow` because that one is shared
with the composer's send path and must stay IO-free.

**Nothing on the Teams backend may run from a timer** (Microsoft's terms). The
rows and the enqueues happen inside `_ingestChat`'s transaction, which is
sqlite-only and traces to a sync the user triggered.

## Bytes and the cache

Metadata says a file exists. Getting at it is a second seam,
`AttachmentBackend` (`app/lib/services/backend/attachment_backend.dart`), with
one implementation per connector and one rule they share.

**A refusal is an answer; a failure is transport.** A file too large to fetch, a
link with no url, an image with no words — none of those improve on a retry, so
`extractText` returns `AttachmentText.skipped(<reason>)` and `fetchBytes`, which
has no "no bytes" value to return, throws `AttachmentUnavailable`. A dropped
socket, a throttle, an expired consent throw the types the worker already routes
on (`GraphMailException`, `GraphTeamsException`, `ReconsentRequired`). Conflating
the two costs a document permanently or spends three requests reaching the same
no.

### Which call gets made

| ref | MCP | SDK (Graph) |
|---|---|---|
| mail `file`/`item`/`unknown`, text | `get_mail_attachment_json` `mode: text` | text-like types only, else `no_extractor` |
| mail `file`/`item`/`unknown`, bytes | `get_mail_attachment_json` `mode: bytes` | `GET /me/messages/{id}/attachments/{aid}/$value` |
| mail `reference`, teams `file` | `inspect_file_json` by `source_url` | `GET /shares/{token}/driveItem/content` |
| teams `file` thumbnail | `get_chat_attachment_json` `thumbnail: small` | `GET /shares/{token}/driveItem/thumbnails/0/{size}/content` |
| teams `image` | `get_chat_attachment_json` (the attachment id IS the hosted-content id) | `GET /chats/{chat}/messages/{msg}/hostedContents/{id}/$value` |
| teams `card`/`message_reference`/`other` | — | — (`binary` / `kind_<k>`) |

Two Graph details are load-bearing and fail as something else when they are
wrong. A sharing url reaches `/shares` as `'u!' + base64url(utf8(url))` with the
padding stripped — a plain `Uri.encodeComponent` is a 400 that names no
parameter (`GraphAttachmentBackend.shareToken`, pinned by a test). And a
hosted-content id sent to the mail endpoint answers 404, which reads as a
deleted message rather than as a wrong route.

**The preview cap belongs to the connector, not to the app.**
`AttachmentBackend.maxPreviewBytes` is **10 MB on MCP** — the server's
`get_mail_attachment_json` and `get_chat_attachment_json` both refuse above it,
because the payload rides back base64 inside one JSON reply, and only a chunked
bytes mode on bond-mcps would raise it — and **25 MB on the SDK path**, which
streams and is limited only by `maxAttachmentBytes`, the same figure the text
policy refuses above. `StoreAttachmentBytes` reads it off whichever backend is
wired and refuses before the request. The exported const
`attachmentTooLargeBytes` is the MCP number, kept for tests; the live cap is
always `maxPreviewBytes`.

**The SDK backend has no extractor, and says so.** It decodes only what a codec
can read (`text/plain`, `text/csv`, `text/markdown`, `text/html`, `text/xml`,
`application/json`, `application/xml`, or the extensions `.txt .csv .json .md
.log .xml .html .htm`), capped at 2 MB — the MCP server's own download ceiling —
and answers `skipped/no_extractor` for docx, pptx, xlsx and pdf **without
fetching**. That is a refusal, not a failure: downloading a 20 MB deck to
discover it is a deck helps nobody.

### The cache

`app/lib/services/attachments/attachment_cache.dart` is content-addressed:
`<Application Support>/attachments/<sha256[0:2]>/<sha256>.<ext>`.

- **The path is the content**, so the same quote forwarded three times is three
  `attachments` rows and one file. A re-fetch lands on the same path and costs a
  touch of the modification time rather than a rewrite.
- **The extension survives** because macOS decides what an unknown file is by its
  name; a bare hash opens a PDF in a text editor. Anything that is not one to
  eight lower-case alphanumerics is dropped rather than sanitised.
- **Writes are atomic** — temp file, then rename — because a half-file at a
  content-addressed path is a lie about what the bytes are.
- **The sweep is the whole eviction policy**: after every write, oldest by
  modification time goes until the tree fits `maxBytes` (2 GB, a constant, not a
  setting), never evicting the file just written. Nothing else expires and no
  timer cleans up.
- The sha is computed inside `compute` and so is the base64 decode of an MCP
  reply — the first two uses of a background isolate in this app.

`clear()` empties the tree and leaves the root standing, because everything that
clears it is followed by something writing to it. It is called by Settings →
Sync & data (two-step, beside the sign-out), by that sign-out, and by
`IdentityGuard` when a different account signs in — the last of those starts the
delete without waiting on it, since `wipeAll` has already removed every row that
pointed at a file.

### What the UI asks

`AttachmentBytes` (`attachment_bytes.dart`) is the only thing above the cache
that widgets see, and the throwing/not-throwing split is deliberate:
`bytesFor`/`pathFor` **throw** (they run off a click, and the panel has an error
state and a Try again), while `thumbnailFor`/`textFor` **never throw** (they run
off a row rendering, and a missing picture must not take out the thread around
it).

`bytesFor` ladders: a link kind is refused outright; the ref's `blob_path`, then
the row's, because a ref built before the fetch carries no path; then the 10 MB
preview cap (`attachmentTooLargeBytes`, the server's bytes-mode ceiling), refused
before the request; then the connector, the cache and the row. One in-flight
future per `source|message|attachment` means two rows wanting the same image in
one frame cost one download.

Thumbnails, in order: one already rendered; then an image, downscaled to 320 px
through `dart:ui` (`ImageDescriptor.instantiateCodec(targetWidth:)`) — an image
already that narrow is returned **untouched**, never upscaled and never
re-encoded; then, for a Teams shared file, OneDrive's own rendering at
`thumbnail: 'small'` — one small fetch, which is how a chat shows a picture of
a document this app never downloaded, and which is why it comes BEFORE the PDF
branch for a chat file; then a PDF's first page, drawn through the
`PdfThumbnailer` seam from the same cached bytes the preview will want, and
refused above `maxPreviewBytes` before any fetch.

The PDF branch is a **typedef, not a call**: the engine that can draw a page is
pdfrx, and pdfium must not be reachable from `services/` or a native library
would sit under every `flutter test` that touches an attachment.
`pdfThumbnailerProvider` answers null by default for exactly that reason, and
`main.dart` overrides it at startup with the real implementation. A build
without one has no PDF thumbnails and fetches nothing trying to make one.

**Nothing in this file may ever be called from a timer.** Microsoft's Teams terms
allow this app to read a chat because a person is looking at it, so every fetch
has to trace to a user action: a row rendering in an open thread, a chip clicked,
a Save chosen. There is no warm-up method and no schedule that calls one.

### XLSX without the `excel` package

The plan named `excel` and it cannot be used: its newest release requires
`archive ^3` and `xml <7`, while `pdfrx` 2.6 — which sets the toolchain floor —
requires `archive ^4`. A workbook is a zip of XML documents, so
`app/lib/services/attachments/xlsx_reader.dart` reads the parts a preview needs
directly and is the only file allowed to import `archive` or `xml`. It reads
sheet order and names, shared strings (every `<t>` in an `<si>`, so a bolded word
does not truncate the cell), inline strings, booleans as `TRUE`/`FALSE`, and
everything else as the characters the file stored — **no styles, no dates, no
formulas**, because a serial date silently rendered wrong is worse than a number
rendered plainly. 500 rows per sheet, with `totalRows` saying what was left out.

## Reading the words

`AttachmentTextHandler` (kind `attachment_text`, concurrency 2) turns one
attachment row into stored text and embedded passages. It talks to **two
servers and neither is a chat model**: Graph for the words, the embedding
server for the vectors. That is what fixes where it sits in the drain — a park
here is a park on `make embed`, the worker parks one kind at a time, and the
storyline and draft queues on another port keep draining behind it.

The digest is a SEPARATE kind for the mirror-image reason. A fast server that
is not running must not hold back the words, which search, retrieval and the
panel's Text segment all want whether or not a model has read them.

The ladder, in order:

1. An unparseable `entity_id`, a missing attachment row, or a missing message
   row is `skipped` and DONE — a work row that cannot be worked still has to
   complete.
2. `attachmentTextPolicy` is asked **again**, after the sync already asked it:
   a message can be gated between the enqueue and the claim. A refusal writes
   `text_status = 'skipped'` with its reason and stops.
3. `text_status == 'done'` is the **resume path**: `unembeddedChunks` says what
   a park left behind, and the handler pays only for that tail. Empty means a
   raced enqueue, which is `skipped/already_extracted`.
4. `extractText` runs. `AttachmentUnavailable` is recorded as the skip it
   amounts to (defensive — the seam says a refusal never throws, and the
   store's state must not depend on that). A `GraphMailException` or
   `GraphTeamsException` whose status is **404 or 410** is `skipped/gone`.
   Everything else propagates: `NotSignedIn`/`ReconsentRequired` park the
   drain, a 5xx or a dropped socket spends an attempt, and `AiWorker` owns that
   ladder.
5. A `skipped` extraction writes its reason and stops — **no digest is queued**.
6. Otherwise the text is stored, chunked, and each passage embedded under
   `EmbeddingsClient.documentPrefix` one POST at a time. An `unavailable`
   server throws `LlmUnavailableException`, which parks the kind with no
   attempt spent and **keeps the text and the passages**. A `rejected` passage
   keeps a NULL embedding and the loop carries on.
7. `indexPendingChunks()`, then `enqueueWork('attachment_digest', …)` — only
   now, and only with words.

**A skip closes the digest.** `setAttachmentText` sets
`digest_status = 'skipped'` whenever the status is anything but `done`, in the
same UPDATE. Left `pending`, a refused attachment would carry the chip's
`reading…` hint for the life of the mailbox, because nothing else ever comes
along to answer it.

Note keys on the activity row: `fetch_ms` and `bytes` always (written before
the outcome is judged — a skip that cost a 10 MB download is worth seeing),
then `chars`, `chunks`, `embedded` and `truncated` on success, or `chunks`,
`embedded` and `resumed` on the resume path.

## Chunks and the second index

`chunkAttachmentText` (`attachment_chunker.dart`) is pure and total. **The
shape is read off the TEXT, never off the mime type**: the extractor writes the
same flat text whatever the file was and marks structure with delimiters, so a
content type that says `.xlsx` over a paragraph of "this workbook is password
protected" chunks as the paragraph it is.

| Text shape | One passage is | Locator |
|---|---|---|
| `--- Sheet: T ---` headers | 40 data rows, with the sheet header and the column row repeated | `Sheet T rows 2–41` (1-based, header is row 1, en dash) |
| a sheet with nothing under its header | the header and its one line | `Sheet T` |
| `--- Slide N ---` headers | one slide, header line and speaker notes included | `slide N` |
| anything else | paragraphs packed greedily to 1,000 chars, with a 150-char overlap trimmed forward to a word boundary | `part N`, or empty for a single passage |

An over-long paragraph is hard-split rather than dropped — a 20 K-character
wall is one legitimate shape of extracted PDF. The extractor's
`[... showing first 500 of ~N rows]` trailer is dropped: it is a statement
about the extraction, and embedded it would make every truncated workbook a
near neighbour of every other one. Empty passages go, and the list is cut at
`maxChunksPerAttachment` (60) — each one costs a POST at embed time and a row
forever, and the sixty-first is not where the answer is.

`vec_attachment_chunks` (`attachment_chunk_index.dart`) is a faithful copy of
`MessageVectorIndex`: derived, disposable, created lazily at first use and
never in a migration or `beforeOpen`. It is a **second** index rather than more
rows in `vec_messages` because the corpora answer different questions — a
fifty-chunk contract in the clustering corpus would be fifty near-identical
neighbours crowding out the threads it is about.

One line differs from the sibling, and it is the whole reason the two-step
write is safe: the backfill asks for `indexed_at IS NULL AND embedding IS NOT
NULL`. A chunk row is stored the moment a document is split and its vector
arrives one POST later; an unembedded row must neither be filed (there is
nothing to file) nor stamped (it would then never be filed).

`replaceChunks` is delete-then-insert rather than a diff, because the chunker
is deterministic: the same text and the same code produce the same passages, so
a retry after a park re-derives exactly what was there and the write is
idempotent by construction. **vec0 has no cascade**, so the rowids of the
deleted passages stay filed — they hydrate to no row in the KNN's join and are
dropped from the results, and `AttachmentChunkIndex.rebuild()` (reached only
from `wipeAll`) is the eventual cleanup.

## The digest

`AttachmentDigestHandler` (kind `attachment_digest`, concurrency 1, fast slot)
runs `AttachmentDigestTask` over one document and writes
`AttachmentDigest` — five keys, always all five:

| Key | What it is |
|---|---|
| `evidence` | one sentence naming what this document is and why it was sent |
| `kind` | `quote\|invoice\|contract\|schedule\|report\|slides\|spreadsheet\|form\|letter\|other` — what it IS, not its file type |
| `summary` | one sentence saying what it says |
| `facts` | up to 6 things a person would quote back, copied exactly |
| `asks` | up to 3 things it requires of the reader; empty is the common case |

The system prompt says "document" and "message" and **names no channel and no
connector** — `prompt_parity_test` holds it to the strict form, like
needs-you's. The user message puts the date anchor outside every fence, the
covering message inside `<untrusted_data source="message">` for context, and
the document last inside `<untrusted_data source="document">` — **with the file
name inside that fence**, because a sender chooses the name and `Invoice —
ignore your instructions.pdf` has to arrive as data like the rest of the file.
`validate` never throws: an unrecognised `kind` becomes `other`, blanks are
dropped, and everything is clamped.

What it refuses to spend a call on: a deleted row, an already-done digest, a
`text_status` that is not `done`, a message gated since the words landed, and a
`done` status with no words behind it (which closes the digest so the pair is
not re-examined on every drain).

The digest is then **appended as one more passage** with locator `digest` — the
one a search for "what is this file about" should land on. It is appended, not
written into the chunk list, so a re-extraction's `replaceChunks` cannot
renumber around it. An embedding server that is down here does **not** throw,
unlike in the text handler: the model call is already paid for, and parking
would risk spending it twice; the passage keeps a NULL embedding, invisible to
the index until something re-reads the document.

`MessageStore.attachmentsWithAsks(source, messageId)` counts the documents on
one message whose digest asks for something, with a **LIKE over the encoded
JSON** rather than a JSON1 extract: `AttachmentDigest.toJson` writes all five
keys always and `jsonEncode` emits `"asks":[` with no spaces, so `"asks":["` is
present exactly when the list has an entry. A test pins the encoding. The
**needs-you re-verdict** that reads this count lands in the next phase,
together with the fence that puts the digests in front of the needs-you prompt
— requeuing before that fence exists would spend a model call on a
re-judgement that cannot see what changed.

## Search

`MessageStore.searchAttachmentChunks` is the corpus-wide read Home search uses:
the query vector against every source, `k = min(limit * 8, 400)` (over-fetching
harder than the message search, because many passages of one document collapse
to one hit), dropped rows filtered unless asked for, and **the nearest passage
per document** — without that collapse a long spreadsheet fills the page with
itself and the second document never appears.

`MessageSearch.search` runs it after the message search has an answer, so a
document search can never be the reason a search reports itself unavailable,
and hands back `MessageSearchHits.documents` → `HomeSearch.documents`. Null
from the store (no native index) becomes an empty list there: the message hits
are an answer either way.

`AttachmentChunkHit` carries the whole `AttachmentRef` — `conversationKey` and
all — because every use of a hit is an action on the file behind it, plus the
`chunkId`, `seq`, `locator`, `text`, sender, direction and distance.

On screen, `HomePane` draws the documents FIRST, under an `In documents`
caption and above the message table, one `AttachmentSearchTile` per hit: the
file's glyph and name, the locator beside it, the passage itself in muted
caption type, and who attached it and when. The passage is the document's own
words, so it is rendered as a quote and **never under the `AI:` label** — that
label is a promise a model wrote what follows. The count line above stays a
count of MESSAGE hits, because it labels the list under it. The whole tile is
one tap into the thread the document came with; a hit whose message is gone
draws no control at all.

**`searchArchive` is untouched.** It answers with feed rows, a shape with
nowhere to put a passage, and its selling point is "I know I got that email".

## What the row and the activity log show

`MessageRow` writes one muted line under the chip row for each file the model
has read — `AI: <file name>: <summary>`, two lines at most — under the SAME
`AI:` label the message's own summary wears, and for the same reason: it is
the model's read of a document, never a sentence the sender wrote. A file
still being read, refused, or never digested adds nothing; the chip's own
`reading…` hint is the whole signal while a digest is pending. The panel's AI
segment renders the full digest (summary, facts, asks).

The activity log labels the two kinds `Read attachment — N passages` and
`Attachment digest — <kind>`. Neither can name its file: the work row's entity
is `<message id>|<attachment id>`, and the name lives on a table the panel
does not read, so each row says what it produced instead.

`MessageStore.chunkKnn` is the other read — SCOPED to a thread's messages
and/or a storyline's pinned documents, for the retrieval the next phase builds.
**Both scopes empty answers `const []` and never the corpus**: a caller that
could not work out which thread it is on must get nothing, because a quote from
a stranger's contract pasted into a reply is the one failure this path has to
be incapable of.

## Restore

`RestoreService` **enqueues** attachment work rather than requeuing it, unlike
the three kinds beside it. The sync refuses to queue a gated message's
attachments at all, so there is no `done` row to revive — there is no row.
`enqueueWork` is `INSERT OR IGNORE`, so a message restored twice queues each
document once, and the policy is asked again because the gate it just lifted
was only one of its seven answers.

## Reading a file on screen

A chip is a tap target. Tapping it puts the file **beside** the thread, because
a preview is read against the message that carried it: the transcript keeps the
pane and the panel takes 45 % of it, clamped to 360–640 px, and the transcript
never goes under 420. When those cannot both be had — a narrow window, or a pane
under the 960 px two-pane breakpoint — the preview **replaces** the transcript
rather than squeezing it. The composer stays under either arrangement, so a
reply is still possible with the file on screen.

`Expand` gives the same panel the whole pane, on a `PaneSurface` whose back
arrow returns to the split with the thread still selected underneath, and whose
`Home` clears both. The viewer is a rung in `_main()` directly above the
transcript — the pane it was opened from and the one Back returns to — and a
viewer whose thread has vanished falls through it rather than stranding the
screen. `_previewing` and `_viewerFull` are cleared by every selector that
clears `_replyOpenFor`; a preview left visible under another pane is exactly the
bug that list exists to prevent.

### Three segments, always all three

**Preview** is the file, **Text** is its words, **AI** is what the model made of
it. All three render whatever they have, including "not yet": a segment that
disappeared while a digest was running would move the controls under the
reader's cursor. The Text segment's empty line answers in the order the question
gets asked — still reading, refused (and why), or nothing to read — and a
truncated extraction says where it was cut. The AI segment speaks under the same
`AI:` label as every other model line in the app and needs no bytes, so it
answers for a link and for a file over the cap too.

### What each kind becomes

| kind | Preview | Text | Bytes fetched |
|---|---|---|---|
| image | `ImagePreview` (zoom to 8×) | the server's words | yes |
| pdf | `PdfPreview` through the `PdfRenderer` seam | the pages joined | yes |
| sheet | `SheetPreview` through the `WorkbookDecoder` | first sheet as TSV | yes |
| text | `TextPreview`, mono for csv/tsv/json/xml/yaml/log/ini | the same | yes |
| document (docx, pptx) | the server's words, under OneDrive's picture for a chat file | the same | **no** |
| eml / `item` | `EmlPreview` — a `MessageRow`, because a forwarded message is a message | the body | **no** |
| link (reference, card, message\_reference) | "This is a link, not a file." + Open in Outlook/Teams | — | **no** |
| unsupported (heic, tiff, xls, everything else) | `UnsupportedPreview` | the server's words | **no** |

`previewKindFor` reads the **name before the content type**, because Graph
reports `application/octet-stream` for a great many real documents; the
connector's `kind` is the last resort. `heic`, `tiff` and `xls` are named as
unsupported on purpose — the first two are images Flutter cannot decode, the
third a binary workbook `xlsx_reader.dart` does not read, and a broken frame
says less than a line naming the file.

Two refusals come before any fetch. A **link** has no bytes to get, and offers
the url out instead. A file over the **live** cap — `bytes.maxPreviewBytes`, per
connector, never the `attachmentTooLargeBytes` constant — says how big it is and
offers the same link; Open and Save are hidden there too, since there is nothing
this app can hand over. A file already in the cache is never too large: the
download the cap exists to prevent has happened.

### Thumbnails in the row

`layOutBody` reports a fourth list, `thumbnailable`: the non-inline, non-link
attachments whose kind is `pdf` or `document`. It is a SUBSET of `chips`, not a
fourth bucket — the file is still named, sized and tapped through its chip, and
counting it twice would make a folded row claim two files where there is one.
The row draws a picture only when the host answers one; a document with none
gets **nothing**, never the dashed frame an image gets, because the chip below
is already the file. The host memoises one `ImageProvider` per attachment key,
so a rebuild keeps the decode and asks for the picture once.

### The gatekeepers

Three files hold a dependency each, and nothing above them names it:

- `pdf_preview.dart` is the only importer of `pdfrx`. Everything else talks to
  `PdfRenderer`/`PdfPreviewDoc` next door. This is what keeps pdfium out of
  `flutter test`: the native library is loaded from the app bundle and a test
  process has none, so a widget that reached pdfrx would fail every preview test
  with a missing symbol. A test may import this file; no test may construct
  `PdfrxRenderer` or call `pdfPageOnePng`. `main.dart` calls `initPdfEngine()`
  once after `ensureInitialized()` so the first document opened does not pay the
  load on the UI thread.
- `xlsx_reader.dart` is the only importer of `archive` and `xml`.
- `file_dialogs.dart` is the only importer of `file_selector`.

`PreviewEngines` deliberately has no `system()` factory — naming the real
renderer there would drag pdfium into every widget that takes one. The screen
builds the real pair lazily behind `InboxScreen.previewEngines`, which is null in
the app and a fake under test, alongside `attachmentBytes` and `fileDialogs`.

### Open and Save

**Open** asks `pathFor` for the cached file and hands its `file:` URL to
`url_launcher`; the operating system decides what opening means, and nothing
here ever executes anything. **Save** asks the panel first and fetches second, so
a cancelled save costs no download, then writes with `file_selector`'s chosen
path — the reason all four entitlement files carry
`com.apple.security.files.user-selected.read-write`. Both report failure as a
toast rather than a dead control.

## Code

- `app/lib/data/schema.drift`, `app/lib/data/database.dart` — schema v13 and
  the `from12To13` step. No backfill: an attachment is discovered by the detail
  fetch, so every stored message re-learns what came with it on its next one.
- `app/lib/models/attachment_models.dart` — `AttachmentRef` (no value
  equality, deliberately) and `AttachmentDigest`.
- `app/lib/data/message_store.dart`, the `── attachments ──` section.
- `app/lib/services/attachments/attachment_policy.dart`,
  `attachment_markers.dart`, `attachment_chunker.dart` (the three shapes),
  `attachment_text_handler.dart`, `attachment_digest_handler.dart`.
- `app/lib/services/llm/attachment_digest_task.dart` — the prompt, the schema
  and the validator; `app/lib/data/attachment_chunk_index.dart` — the second
  vec0 index.
- `app/lib/services/message_search.dart` (`MessageSearchHits.documents`),
  `app/lib/models/home_models.dart` (`HomeSearch.documents`),
  `app/lib/services/restore_service.dart` (the fresh enqueue).
- `app/lib/services/sync_service.dart` `_storeAttachments`;
  `app/lib/services/teams_sync.dart` `attachmentRows` and the ingest loop.
- `app/lib/services/graph_mail.dart` `_detailExpand`,
  `app/lib/services/graph_teams.dart` `attachmentEntries`.
- `app/lib/services/backend/attachment_backend.dart` — the bytes/text seam,
  `AttachmentText`, `AttachmentBytesResult`, `AttachmentUnavailable`.
- `app/lib/services/mcp/mcp_attachment_backend.dart`,
  `app/lib/services/graph_attachment_backend.dart` — the two implementations.
- `app/lib/services/attachments/attachment_cache.dart` (content-addressed store
  and its sweep), `attachment_bytes.dart` (the ladder the UI asks),
  `file_dialogs.dart` (the `file_selector` gatekeeper),
  `xlsx_reader.dart` (the workbook reader).
- `app/lib/providers/app_providers.dart` — `attachmentBackendProvider`,
  `attachmentCacheProvider`, `attachmentBytesProvider`,
  `pdfThumbnailerProvider` (null by default), and the `IdentityGuard` wiring
  that clears the cache on a wipe.
- `app/lib/widgets/preview/preview_kind.dart` — what a preview would have to
  be, name before content type; `preview_engines.dart` — the two engines the
  screen fills in.
- `app/lib/widgets/preview/pdf_renderer.dart` (the seam) and
  `pdf_preview.dart` (the pdfrx gatekeeper: `PdfrxRenderer`, `PdfPreview`,
  `initPdfEngine`, `pdfPageOnePng`).
- `app/lib/widgets/preview/attachment_preview_panel.dart` — the ladder, the
  three segments and the actions row; `attachment_viewer_pane.dart` — the same
  panel on a `PaneSurface`.
- `app/lib/widgets/preview/image_preview.dart`, `sheet_preview.dart`
  (fixed 160 px columns, never `IntrinsicColumnWidth`), `text_preview.dart`,
  `eml_preview.dart`, `unsupported_preview.dart`.
- `app/lib/widgets/attachment_documents_strip.dart` — the pinned-documents
  shelf, built here and wired to the storyline pane in a later round.
- `app/lib/widgets/message_row.dart` — `layOutBody`'s `thumbnailable` list and
  the document pictures it drives.
- `app/lib/screens/inbox_screen.dart` — `_threadBody` (the split),
  `_attachmentViewer` (the `_main` rung), `_thumbnailFor`/`_loadThumb`,
  `_openAttachmentInOs`, `_saveAttachment`, `_launchExternal`, and the
  clear-cache wiring.
- `app/lib/main.dart` — `initPdfEngine()` and the `pdfThumbnailerProvider`
  override, the one place the app admits it has pdfium.
- `app/lib/widgets/settings_screen.dart` — Sync & data's "Clear attachment
  cache"; `app/lib/data/message_store.dart` `clearAttachmentBlobs`.
- `app/macos/Runner/*.entitlements` — all four carry
  `com.apple.security.files.user-selected.read-write` for the save panel.
- `app/lib/widgets/attachment_search_tile.dart` — one document hit on Home
  search; `app/lib/widgets/home_pane.dart` — the `In documents` block above
  the message table.
- `app/lib/widgets/message_row.dart` — the per-file `AI:` digest line under
  the chip row; `app/lib/widgets/activity_log_panel.dart` — the labels and
  sentences for `attachment_text` and `attachment_digest`.
