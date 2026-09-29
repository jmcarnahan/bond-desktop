# 4 · The text stage (work kind `extract`) and its fan-out

**What happens.** After triage, `ExtractHandler`
(`app/lib/services/extract_handler.dart`, run by `AiWorker` on the fast lane)
writes each kept message's TEXT with ONE generative call, `MessageTextTask`,
then fans out cheap follow-ons. It replaced two language-model calls in the
decision-model round's Phase 6: the retired triage call's summary / action
items / deadline and the retired extraction call's topics / project. The
classification that used to ride on both (urgency, category, the booleans,
intent, importance, the label) is the decision model's
([03-triage.md](03-triage.md)).

**The kind stays `extract`, and the class keeps its name.** A rename would
need a work-kind migration of every queued row and a requeue, and would move
the activity kind, the progress stage (`extract_state`, which the settle
machine waits on — [09-notifications.md](09-notifications.md)) and the
activity panel's words with it, for a label. The kind names the stage's slot
in the pipeline, not the task it runs.

**What it writes, in order.**

1. `MessageStore.writeMessageText` — `summary`, `action_items_json`,
   `deadline` (NULL when empty) on `messages`, narrow SQL. It DOES stamp
   `updated_at`, as triage did when the summary was triage's: the word index
   (`fts_messages`, which files `summary`) re-files a row by that watermark.
   The settle's freshness check (attention newer than the message) is met
   because the card refresh right after re-stamps `conversation_ai`.
   `label` is never written: NULL on every new row.
2. `extraction_json` (`message_ai`, `writeExtraction`) as
   `{topics, project, intent, importance}` — topics and project from the text
   call (topics LOWERCASED by `validate` — a one-time card re-embed churn on
   threads whose newest message is re-run), intent and importance from the
   stored decision (`message_decisions`;
   a message decided before the decision model reads the quiet middle, `fyi` /
   `normal`). `evidence`, `people` and `organizations` are ABSENT on new rows
   (`ExtractionResult.toJson` leaves an empty one out); old rows keep theirs
   and the Why panel still shows them there.
3. The row is READ BACK, so every reader below (the card, the message
   embedding, the draft pre-gates) sees the text this call just wrote.
4. The conversation CTA, recomputed WHEN THE TEXT LANDS: `foldCtaUp`
   (`app/lib/services/conversation_cta.dart`) with the row's urgency and
   category and the text's action items, summary and deadline — only on a row
   triage decided (`triaged`; an `error` row has no urgency to fold with), and
   under the fold's two guards (newest inbound, not already answered). See
   [03-triage.md](03-triage.md), "The CTA rollup".
5. `extract_state = done`, then the fan-out below. The activity row notes
   intent, importance, up to five topics, the project, the action-item COUNT
   and the deadline — never the summary.

**Claim order.** The text is the one per-message generative call left, so the
backlog claims `extract` items in the order the owner most wants them read
(`MessageStore._textClaimOrder`, used by `claimPendingWork` for this kind
only), over a WINDOW of the newest `textClaimWindow` (500) eligible items by
`created_at DESC` — so a Clear AI results backlog of tens of thousands is not
sorted per claim inside the write transaction:
1. an item stamped in the last `textClaimRequestedWithin` (5 minutes) — what
   an owner-asked requeue (`requeueWork(refreshCreatedAt: true)`: Retry,
   Restore) looks like; mail that arrived in the last few minutes rides with
   it;
2. a message that needs the owner (`needs_you_p` at or above their Needs You
   slider, `needsYouAtSql`);
3. everything not filed Later before what is;
4. the decision's importance, high > normal > low (from
   `message_decisions.answers_json`, else an older build's `extraction_json`;
   neither reads as normal);
5. the queue's own `created_at DESC`.

ORDER only: which items are claimable is the WHERE below, unchanged, and
every other kind keeps `created_at DESC`. The priority lane (`claimWorkItem`,
the refs triage just wrote) is a named claim and has no order. Tests:
`app/test/text_claim_order_test.dart`.

**A text stage that fails for good.** Triage keeps the thread's current ask
until the text refolds it, so when the `extract` item ends in `error`
(attempts spent, or a schema 400) the worker's fatal path calls
`MessageStore.clearStaleAskAfterTextFailed`: for the thread's newest inbound,
triaged, with no summary and not answered, `cta_text` is cleared (the
decision's `cta_urgency` and `category` stay). Until then the stale ask is
neither counted nor quoted as this message's: `ownsCta` (notify-worthy, the
toast) and `needsYouSql` both require the message's own summary to be
present.

**A retired gate re-pended.** `rependGatedTriage` (the `teams_source` /
label-rule one-shots) requeues each re-pended message's `extract` item in the
same transaction, as Restore does — triage writes no text any more.

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

Work the sync window can no longer reach is re-offered at sync by
`MessageStore.reviveOwedMessageStages`: a kept inbound whose triage is done
and whose extract stage is still pending, typically mail triaged inside the
bootstrap window that the rolling floor overtook. It files `extract`,
`needs_you` and `embed_message` rows with `INSERT OR IGNORE`, at most 150 per
kind per pass for mail (`backlogEnqueueCap`) and 100 for Teams
(`TeamsSync._extractCap`), so a restart or a narrowed window loses
nothing (see [01-sync-ingest.md](01-sync-ingest.md)).

**The thread tail.** The text call reads the block the retired triage call
read: the attachments line, the newest three earlier messages (300 characters
each) in a `thread` fence, then the judged message — see
[03-triage.md](03-triage.md) and `MessageTextTask.buildUserMessage`. The
2026-09-17 ladder that kept the retired EXTRACTION call message-alone (the
tail cost it 12 points of people and 13 of project) measured fields this call
no longer has, except project; project is re-read against the golden judge
flow on this call (the Phase 6 measurement in `docs/model-bakeoff.md`).
`GOLDEN_EXTRACT_CTX` went with that call.

1. **Bucket filing** (`_fileBucket`) — the decision's intent and importance
   (stored in the extraction blob) file low-value mail into Later, unless a standing per-sender rule or an
   explicit "keep this in my inbox" overrides it. Nothing automatic overturns
   a person. A thread holding an **open ask** — an unanswered message the
   needs-you stage judged yes, anywhere in the thread, not only the newest one
   — is never filed to Later by this rule either (see
   [08-attention.md](08-attention.md)).
2. **Conversation card + clustering embedding** (`_refreshCard`) — builds the
   thread card, hash-guards it against no-op rewrites, embeds it under the
   clustering prefix, and requeues `storyline` work for the conversation. It
   runs after the text is written and builds the card from the STORED
   facts (`clusteringCardForConversationRow` over `newestInboundCardData`),
   not from the result in hand, so the hash it writes is the hash the heal
   path in `StorylineService._reembed` computes for the same thread.
3. **Draft pre-gate** (`_queueDraft`) — decides whether a `draft` work row is
   written or the draft stage closes as `skipped`, under the user's
   **Suggested replies** setting. `DraftPolicy` is one of three (see
   [07-replies.md](07-replies.md), "When a draft is written"): `onDemand`
   queues nothing, `needsYou` — the default — queues what `prefetchWorthy(row)`
   admits while fewer than ten drafts are in flight, and `all` queues whatever
   `asksForAReply(row)` admits. Either way these pre-gates run behind the
   reply decision (the decision model's stored `reply_expected`, see
   [07-replies.md](07-replies.md)), and the reason for a skip goes on the activity row
   as `draft: on_demand | automated_sender | no_reply_needed | not_prefetched |
   prefetch_cap | no_cue`. `no_reply_needed` is the reply decision itself
   (`replyVerdict` in `app/lib/services/reply_policy.dart`), asked right after
   `automated_sender` so a message nobody is waiting on never takes a queue
   row or a prefetch slot.

   `automated_sender` is asked right after `onDemand` and ahead of every
   other mode, because it is not a preference: `replySuppressed`
   (`app/lib/services/reply_policy.dart`) says a machine wrote the
   message, from an automated `gate_reason` or `classificationOf` answering
   `automated_notification`. It is the same authority the draft handler and
   the composer ask, so the three cannot disagree (see
   [07-replies.md](07-replies.md)).

   `asksForAReply` takes five signals off the row, any one enough: the
   message needs the owner (`needsYouAt(needs_you_p, threshold)` at their
   Needs You slider), `reply_expected`, `needs_action`, an urgent/high
   urgency, or a named deadline (the deadline this call just wrote — the row
   is read back first). The deadline arm still admits any non-empty
   `deadline`, a plan-relative "Day 1" included (it does not go through
   `showableDeadline`); that is a recorded follow-up. `prefetchWorthy` is ONE
   signal, the needs-you predicate itself, and drops the four that fire on
   ordinary mail, which a receipt, a reminder and a calendar invitation trip
   between them. The probability is the decision model's whole-message read
   (see [11-needs-you.md](11-needs-you.md)) rather than one of triage's
   fields; triage writes it, and `NeedsYouHandler` drains ahead of this
   handler to settle any it left missing. A message over the slider is put in
   front of the drafting model even when triage saw no reply cue at all; an
   undecided one (NULL) adds nothing, and each gate degrades to the
   triage-only shape it had.

It also embeds the message's own document vector on the fast path
(`_embedMessage`) — see [05-embeddings.md](05-embeddings.md).

**The model call.**

| | |
|---|---|
| Task | `MessageTextTask` — `app/lib/services/llm/message_text_task.dart` |
| Prompt | `_messageTextRules` at the top of that file (the retired triage prompt's summary / action-item / deadline rules and the retired extraction prompt's topics / project rules, and nothing about the fields the decision model answers), composed with the shared untrusted-data fence (`prompt_guard.dart`); one prompt for mail and chat, pinned by `prompt_parity_test.dart` |
| Schema | `message_text` — flat, `summary` FIRST (the model states what the message is about before anything that follows from it), then `action_items` (≤3), `deadline`, `topics` (≤3), `project` |
| Caps | summary 500, action item 200, deadline 40, topic 80 (lowercased), project 60 — enforced in `validate` / `MessageTextResult.fromJson`, not the schema (this llama-server build turns the schema into a grammar and a `maxLength` it cannot convert costs the request) |
| Slot | the **generative** role (`stageLlmClientProvider('message_text')`, see [10-model-routing.md](10-model-routing.md)) |
| Params | **temperature 0** (set in `extract_handler.dart`: the same email must yield the same facts twice), maxTokens 512 |
| Concurrency | 3 (the handler's `concurrency` override) |

The `inbound_message` fence is `buildMessageBlock`
(`app/lib/services/llm/message_block.dart`), so the body is link-stripped
(`stripLinkTargets`, keeping each label) before its cap.

**What the prompt instructs.** Write the text for one message: a summary that
carries the specifics (the rule and its measurement are in
[03-triage.md](03-triage.md), "The summary rule"), the READER's action items
as the model's own judgement (with the wire-fraud rule: never copy a payment
or "reply to confirm" demand — the action is independent verification), the
deadline in the sender's words, up to three lowercase topics, and a stable
project label. It asks nothing a classifier answers.
