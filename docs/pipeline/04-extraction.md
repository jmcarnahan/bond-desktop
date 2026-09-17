# 4 · Extraction and its fan-out

**What happens.** After triage, `ExtractHandler`
(`app/lib/services/extract_handler.dart`, run by `AiWorker`) pulls stable
facts out of each message, then fans out three cheap follow-ons:

"After triage" is enforced, not hoped for. `extract` and `needs_you` rows are
enqueued at sync time, while every fresh message is still `pending`, and the
triage drain and the FAST worker drain race for the same drain gate — so the
rule lives at the claim. `MessageStore.claimPendingWork` will not hand the worker
an `extract` or `needs_you` item whose message row is still `pending` or
`processing`: the item is claimed only once `triage_status` is `triaged`,
`skipped` or `error`, or the message row is gone. `error` counts as spoken
because both gate tiers passed and only the model failed — the bar is "the
gates have decided", not "the model succeeded" — and a missing row counts
because nothing is coming for it, which is what the handler's `deleted`
branch closes. Whichever drain wins the gate, the gates decide first. The
handler's own `skipped` check stays as the belt, for an Ignore that lands
between the claim and the run and for rows an older build enqueued. Every
other work kind is untouched by the clause.

**A thread for extraction, measured and not given (2026-09-17).** The task can
take one. `ExtractionInput(message, now, {thread, threadDigest})` renders, in
order, the date line, a `thread_digest` fence when a digest is passed, a
`thread` fence built by the shared `buildThreadTailText` (newest three, 300
characters each) when a thread is passed, the line "Extract from ONLY this
message:" when either of those was written, and then the `inbound_message`
fence. With neither the prompt is byte-identical to what this task has always
built — the date line and one fence, no label between them — which is what
keeps every prior 4B row comparable. `make golden GOLDEN_EXTRACT_CTX=none`,
`=tail3` or `=digest` measures the three rungs on extraction's own axis. It
was measured on the 4B at `GOLDEN_K=4`, two passes each, keep-only (76 items),
and the five fields read intent / importance / project / topics / people: with
nothing, 75% / 39% / 66% / 26% / 87%; with the tail, 78% / 39% / 53% / 25% /
75%; with the digest and the tail, 76% / 37% / 53% / 30% / 66%. The tail buys
3 points of intent and costs 12 of people and 13 of project; the digest costs
21 of people and 13 of project. Neither is a trade worth making, so extraction
stays message-alone: `ExtractHandler` builds `ExtractionInput(message,
DateTime.now())` and passes neither field, pinned by `extraction sees the
message alone even when the thread has history` in
`app/test/extract_handler_test.dart`. The fields stay because the ladder will
be re-run against a future prompt, not because anything calls them.

1. **Bucket filing** (`_fileBucket`) — the extraction's read of the message
   files low-value mail into Later, unless a standing per-sender rule or an
   explicit "keep this in my inbox" overrides it. Nothing automatic overturns
   a person. A thread holding an **open ask** — an unanswered message the
   needs-you stage judged yes, anywhere in the thread, not only the newest one
   — is never filed to Later by this rule either (see
   [08-attention.md](08-attention.md)).
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
