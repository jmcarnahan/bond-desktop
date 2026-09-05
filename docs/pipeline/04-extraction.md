# 4 · Extraction and its fan-out

**What happens.** After triage, `ExtractHandler`
(`app/lib/services/extract_handler.dart`, run by `AiWorker`) pulls stable
facts out of each message, then fans out three cheap follow-ons:

1. **Bucket filing** (`_fileBucket`) — the extraction's read of the message
   files low-value mail into Later, unless a standing per-sender rule or an
   explicit "keep this in my inbox" overrides it. Nothing automatic overturns
   a person.
2. **Conversation card + clustering embedding** (`_refreshCard`) — builds the
   thread card, hash-guards it against no-op rewrites, embeds it under the
   clustering prefix, and requeues `storyline` work for the conversation.
3. **Draft pre-gate** (`_queueDraft`) — `asksForAReply(row)` decides whether a
   `draft` work row is written or the draft stage closes as `skipped`. This is
   the cheap filter before the 27B's reply decision (see
   [07-replies.md](07-replies.md)). Five signals off the row, any one enough:
   `needs_you_verdict = 1`, `reply_expected`, `needs_action`, an urgent/high
   urgency, or a named deadline. The first is the needs-you stage's
   whole-message verdict (see [11-needs-you.md](11-needs-you.md)) rather than
   one of triage's fields, and it is on the row because `NeedsYouHandler`
   drains ahead of this handler in the worker. A judged yes puts a message in
   front of the drafting model even when triage saw no reply cue at all; NULL
   and 0 change nothing, and the gate degrades to its old four-signal shape.

It also embeds the message's own document vector on the fast path
(`_embedMessage`) — see [05-embeddings.md](05-embeddings.md).

**The model call.**

| | |
|---|---|
| Task | `ExtractTask` — `app/lib/services/llm/extract_task.dart` |
| Prompt | top of that file, fenced by `prompt_guard.dart` |
| Schema | `extraction` |
| Output | evidence sentence (written first), topics, people, organizations, a stable project label, an intent enum, an importance enum |
| Slot | **fast / bulk** |
| Params | **temperature 0** (set in `extract_handler.dart`), maxTokens 512 |
| Concurrency | 3 (the handler's `concurrency` override) |

**What the prompt instructs.** Pull the stable facts out of one message, with
the evidence sentence first to force grounding. The prompt's bullets restate
the schema in prose deliberately: the grammar already guarantees shape, so the
words exist to make each field *mean* something. The doc comment above the
prompt explains this.
