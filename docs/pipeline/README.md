# The message pipeline

Every synced message moves through the same ordered pipeline: cheap gates
first, then a chain of model calls that classify it, extract facts from it,
group its conversation into storylines, decide whether it deserves a reply,
and draft one. This directory documents each section — what happens, what the
prompt says, and which model serves it.

**Maintenance rule: these files describe the code, and the code moves. Any
change to a pipeline stage — its ordering, its prompt, its schema, its model
slot, its failure behavior — must update the corresponding file here in the
same PR.** File and symbol references are the pointers into source; the source
is always the authority when they disagree.

## The stages, in order

| # | Stage | LLM | Doc |
|---|-------|-----|-----|
| 1 | Sync / ingest — Graph delta pull, upsert, enqueue downstream work | no | [01-sync-ingest.md](01-sync-ingest.md) |
| 2 | Tier-1 gates — sender-only checks on delta fields | no | [02-gates.md](02-gates.md) |
| 3 | Detail fetch (mail) — full body + headers | no | [02-gates.md](02-gates.md) |
| 4 | Tier-2 gates — list/auto-generated header checks | no | [02-gates.md](02-gates.md) |
| 5 | **Triage** — urgency, category, summary, action items | **yes** | [03-triage.md](03-triage.md) |
| 6 | **Needs-you verdict** — does this message want the owner | **yes**† | [11-needs-you.md](11-needs-you.md) |
| 7 | **Extraction** — evidence, topics, people, intent, importance | **yes** | [04-extraction.md](04-extraction.md) |
| 8 | Bucket filing — low-value mail to Later, unless the thread holds an open ask | no | [04-extraction.md](04-extraction.md) |
| 9 | Embeddings — clustering + per-message search vectors | no* | [05-embeddings.md](05-embeddings.md) |
| 10 | Attachments — text extraction and chunk embeddings, then one digest per document | **yes**‡ | [12-attachments.md](12-attachments.md) |
| 11 | **Storylines** — assign, sweep, refresh, audit, recruit, recap | **yes** | [06-storylines.md](06-storylines.md) |
| 12 | **Reply decision** — does this message need an answer | **yes** | [07-replies.md](07-replies.md) |
| 13 | **Draft generation** — the suggested reply itself | **yes** | [07-replies.md](07-replies.md) |
| 14 | Attention rescore — Needs You ranking | no | [08-attention.md](08-attention.md) |
| 15 | Notification settle — one verdict per message | no | [09-notifications.md](09-notifications.md) |

\* embeddings call the embedding server, but no chat model.

The attachment row sits here because this is where the two handlers register:
`AttachmentTextHandler` and `AttachmentDigestHandler` go on the drain between
Embed and StorylineAssign (`app_providers.dart`), so a document is read before
the storylines and the drafts that quote it are.

‡ Three stages, and only the last dials a chat model. The METADATA stage runs
inside stage 1: both syncs write `attachments` rows and queue `attachment_text`
work, and triage reads the names and sizes. `attachment_text` then fetches the
words through Graph and embeds their passages on the embedding server — no chat
model, so a park there is a park on `make embed`. `attachment_digest` is the
one fast-slot call: one record per document, queued by the text handler and
only once there are words.

The arrow also runs backwards, once. A digest that records something the
document ASKS for sends its message back to stage 6 — a file saying "sign by
Thursday" can change whether the owner is needed, and the first verdict was
written before anything had read it. One requeue per message, and the drain
makes one more pass so it lands before the settle asks. Stages 12 and 13 read
documents too: the passages nearest the message being answered, scoped to its
own thread and its storyline's pinned files. See
[12-attachments.md](12-attachments.md) and [07-replies.md](07-replies.md).

† a deterministic floor (an inbound Teams @mention or 1:1) answers without any
model call; everything below the floor gets the fast-slot judgment. See
[11-needs-you.md](11-needs-you.md).

Cross-cutting concerns — which client serves which task, ports and defaults,
parking and retry policy, and the untrusted-data fence around every prompt —
live in [10-model-routing.md](10-model-routing.md).

## The two-model split at a glance

| Task | Slot | Default server (compile-time) |
|------|------|----------------|
| Triage | fast / bulk | `:8082` Qwen3-4B-Instruct (`make fast`) |
| Needs-you verdict | fast / bulk | `:8082` |
| Extraction | fast / bulk | `:8082` |
| Attachment digest | fast / bulk | `:8082` |
| Storyline membership confirm | fast / bulk | `:8082` |
| Storyline naming | prose / 27B | `:8080` Qwen3.8-27B (`make model`) |
| Storyline refresh | prose / 27B | `:8080` |
| Storyline recap | prose / 27B | `:8080` |
| Reply decision | prose / 27B | `:8080` |
| Draft generation | prose / 27B | `:8080` |
| Embeddings | embed | `:8081` embeddinggemma-300M (`make embed`) |

Both chat slots can be re-pointed at runtime in Settings → Models; the mapping
above does not change. See
[10-model-routing.md](10-model-routing.md#runtime-overrides).

The home screen's five-segment stage bar (triage · extract · storyline ·
draft · settle) is this pipeline rendered per row; `pipeline_progress.dart`
records the transitions it draws.

## What the Inbox shows

Every row's verdict is TWO CELLS. The **Result** cell is the label — `Needs
you`, `Newsletter`, `Filed in <storyline>`, `Stalled` — and the **Ask ·
Summary** cell beside it carries the words. `resultLine` in
`app/lib/widgets/home_result.dart` picks the first label that matches, in this
order, and writes the reason clause into `HomeResult.detail`; the whole
sentence, both halves joined, is the tooltip.

| Result | Detail / Ask | Columns behind it |
|--------|--------------|-------------------|
| `Filtered`, `Newsletter`, `Nothing to do` (dropped) | the gate words, or the not-worthy reason | `message_progress.drop_reason`, plus `messages.gate_reason` for a gated drop; for `not_worthy` the judge's `needs_you_reason` when the verdict was a no, or "the thread is in Later" / "below the attention threshold" when it was a yes |
| `Failed at <stage>` | `The <stage> stage ended in an error.` | the first `message_progress.<stage>_state` that is `error` |
| `Stalled` | `No progress for 15 minutes and nothing is queued — waiting on <stage>.` | `message_progress.outcome = 'pending'`, no open `work_items` for the message, its thread or its documents, `messages.triage_status` neither pending nor processing, and `message_progress.updated_at` older than 15 minutes |
| `Triaging…` / `Waiting on <stage>` | `Not queued yet` when nothing is | the five stage states, and whether any `work_items` row is open |
| `Needs you` | the thread's `conversations.cta_text`, else `messages.needs_you_reason` | `message_progress.needs_you` |
| `Filed in <storyline>` | the membership's `evidence`, or "filed by you" | the row's storyline pointer, or the thread's newest `storyline_members` row |
| `Later` | the bucket reason in words | `conversation_ai.bucket` with `conversation_ai.bucket_reason` |
| `Draft ready` | — | `message_progress.draft_state = 'done'` |
| `Nothing to do` | `needs_you_reason` when the verdict was a no | nothing above matched |

The Ask · Summary cell prefers the THREAD's ask on a needs-you row and the
MESSAGE's `messages.summary` everywhere else — an ask is per thread and a
summary is per message, which is why they are two columns in the store and one
on screen — and falls back to the Detail column above when a row has neither.
That fallback is what a gate-dropped message shows: it never reached triage, so
it has no summary, and "sender muted" in that space is worth more than a blank.
`askLine` is the one place that order is written down.

**The eight tiles are the filter.** They read the same columns over the last
seven days (`homeMetricsWindow`, `app/lib/models/home_models.dart` — a day made
a quiet Sunday look like a broken pipeline), the bar says the window in a
caption beside the numbers, and the hot strip uses the same window. Pressing a
tile narrows the table to what that tile counted; pressing it again widens back
to everyone else's messages, and one filter is in force at a time
(`HomeFilter`, with `MessageStore.homeFilterSql` as the single definition of
what each one admits). A tile filter is bounded by that same seven-day window,
so **the number on the tile is the number of rows under it**. Emails and Teams
are the two tiles that write elsewhere: they move the list column's source
chips, which every pane reads.

**The pulse strip** under the tiles narrates the work a filter may be hiding,
in three segments joined by `·` (`app/lib/widgets/home_pulse.dart`):

- what is moving — `triaging 2 · grouping 1`, in pipeline order, off
  `work_items.task_kind` for every stage and off `messages.triage_status` for
  triage, which has no queue row of its own;
- what just finished — `Last 10 min: 5 settled · 2 dropped · 1 needs you`, from
  `message_progress.updated_at` inside `homePulseWindow`;
- where the mail is coming from — `Syncing mail…` while a pull is out, else
  `Mail 2m ago · Teams 4m ago · Sweep 12m ago` from the stored stamps, with
  `never` for a pass that has not run.

It has no timer of its own: `pipelinePulseProvider` re-reads behind the feed's
metrics epoch, the activity log's events, and the screen's own sixty-second
invalidate. Words and one dot, never a spinner — the stage bar's rule.

Retry (`PipelineRepairService`) puts back exactly the stages a row still owes —
never one that finished, and never a dropped row, which is Restore's.

## Finding out what happened to a message

Every sentence above is a summary, and the reason a row got the sentence it
did is spread across eight tables. `MessageHistoryScreen`
(`app/lib/screens/message_history_screen.dart`) is where all of it is read at
once, behind `messageHistoryProvider`, which folds those eight reads into one
`MessageHistory` and re-reads it behind the progress ticks the message's own
stages publish. `MessageHistoryHost` (`app/lib/widgets/message_history_host.dart`)
is the one place that provider is read and every lever below is wired; the
screen itself is prop-driven. The shell seats it BESIDE the main pane, as the
`HistoryPanel` kind of side panel inside a `SidePanelHost` (`chrome: false`, the
host draws the header), so whatever the question was asked from — the home
table, a thread, the archive — stays on screen, and the storyline picker its
`Add to storyline…` opens draws in the main pane while the story stays beside.
See [../shell.md](../shell.md#what-opens-where).

Four doors reach it, and all four hand it the same `(source,
source_message_id)` pair:

- **A home row's stage bar or its Result cell.** Two targets on the row rather
  than one, because those are the two places a reader looks when the sentence
  is not the one they expected. They nest inside the row's own tap and outside
  the storyline link and Retry, so each gesture fires exactly one thing.
- **A home search result.** Home search runs a meaning pass and a word pass
  and fuses them into ONE ranking, best first — no *Text matches* heading, and
  one count that is the rows on screen. Gate-dropped mail has no vector at all
  and is unreachable by meaning, so the words are the only way it is ever
  found, whenever *Show dropped* is on. A notice above the rows says when only
  one of the two halves ran. See [05-embeddings.md](05-embeddings.md).
- **An Archive row**, in the Dropped pile or in an archive search.
- **"What happened" on a message in a thread**, the fourth button on an
  inbound row's hover strip, after Why — and the `What happened ›` door at the
  foot of the Why panel, which swaps the history into the same side slot. Per
  message and not per thread: the pipeline decides one message at a time. The
  strip is drawn on inbound rows only, so the owner's own messages reach their
  history through the home feed.

The screen is one column of sections, in the order the question gets asked:
the header (subject, sender, source, age, and a link into the thread); the
**outcome**, which is `resultLine`'s own sentence with its explanation under
it; the five **stages**, each with what it did, when, and what that means, in
`HomeStageBar`'s own words so the rail and the tooltip cannot disagree; the
**judgements** (needs-you verdict and reason, attention bucket with its score
against the threshold in force, triage urgency/category/summary, the gate and
whether the owner has overridden it, and the triage status with its error);
the **storylines** the thread is in and the ones it was kept out of; the
**work** still queued with its attempts and errors; and every **activity** row
either the message or its thread wrote, described by `ActivityLogPanel`'s own
sentences.

The levers come last, and each one is a write with a way back:

| Lever | What it writes | How it is undone |
|-------|----------------|------------------|
| Restore (dropped rows only) | `RestoreService` — `messages.gate_override = 'user'`, the progress cascade reset, the stages requeued | Ignore |
| Ignore this message (kept rows, two taps) | `MessageStore.dropMessage` — a `user` gate, see [02-gates.md](02-gates.md#ignoring-a-kept-message) | Restore |
| Retry owed stages (stalled or failed rows) | `PipelineRepairService.retryOwed` — exactly the stages still owed, never a terminal one; when nothing at all is owed it runs the settle sweep, which is what a row stuck with every stage terminal and `outcome = 'pending'` is waiting for | nothing to undo; it re-runs work that was owed |
| Re-judge Needs You (kept rows) | `PipelineRepairService.rejudgeNeedsYou` — requeues `needs_you` on a row that was already judged | press it again after changing the rules |
| Add to storyline… / Remove (two taps) / Allow again / Add back | `StorylinesNotifier.addThread` / `removeThread` / `unblockThread` — the same methods the storyline's own About block calls | each other; a removal is a block, and Allow again lifts it |
| Keep in inbox / Send to Later | `ConversationsNotifier.keepThreadInInbox` / `sendThreadToLater` | each other |
| Edit Needs You rules | nothing — it opens Settings, where the rules live | the editor's own Save |
| The storyline link | nothing — it opens the storyline, where the charter is edited | the charter editor's own Save |

Every write is followed by a re-read of the screen, because a thread-level
decision moves rows here without moving any stage and so ticks nothing.
