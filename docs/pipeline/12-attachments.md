# 12 · Attachments

**What happens.** Every message records what came with it. The mail sync
learns an attachment list from the per-message detail fetch; the Teams sync
learns one at ingest, because chat has no detail step. Both write
`attachments` rows and queue the eligible ones for text extraction.

**No model call at this stage.** Discovering an attachment costs one already-
planned Graph read and a local write. Triage sees names and sizes; nothing
waits for a download.

> **Phase 1 of the attachments round.** The metadata stage below is live. The
> `attachment_text` and `attachment_digest` stages that read the rows this one
> writes arrive in Phase 3 — `attachment_text` work rows are already being
> queued and simply wait `pending` until their handler exists, which is
> harmless: `AiWorker` drains only kinds it has a handler for.

## The data model

Three tables, split by lifetime and size (`app/lib/data/schema.drift`, schema
v13).

| Table | Holds | Written by |
|---|---|---|
| `attachments` | the metadata a row draws and the text policy judges on | both syncs, on every sighting |
| `attachment_text` | the extracted words, up to 200 K chars | the text handler (Phase 3) |
| `attachment_chunks` | the embedded passages, and the source of truth for the chunk vectors | the text handler (Phase 3) |

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

## Code

- `app/lib/data/schema.drift`, `app/lib/data/database.dart` — schema v13 and
  the `from12To13` step. No backfill: an attachment is discovered by the detail
  fetch, so every stored message re-learns what came with it on its next one.
- `app/lib/models/attachment_models.dart` — `AttachmentRef` (no value
  equality, deliberately) and `AttachmentDigest`.
- `app/lib/data/message_store.dart`, the `── attachments ──` section.
- `app/lib/services/attachments/attachment_policy.dart`,
  `attachment_markers.dart`.
- `app/lib/services/sync_service.dart` `_storeAttachments`;
  `app/lib/services/teams_sync.dart` `attachmentRows` and the ingest loop.
- `app/lib/services/graph_mail.dart` `_detailExpand`,
  `app/lib/services/graph_teams.dart` `attachmentEntries`.
