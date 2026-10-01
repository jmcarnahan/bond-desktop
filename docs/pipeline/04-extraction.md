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
   when the assign pass this stage queues writes the new vector
   (it re-stamps `conversation_ai`), and otherwise by the attention
   recompute after the drains and on every list load.
   `label` is never written: NULL on every new row.
2. `extraction_json` (`message_ai`, `writeExtraction`) as
   `{topics, project, intent, importance}` — topics and project from the text
   call (topics LOWERCASED by `validate`), intent and importance from the
   stored decision (`message_decisions`;
   a message decided before the decision model reads the quiet middle, `fyi` /
   `normal`). `evidence`, `people` and `organizations` are ABSENT on new rows
   (`ExtractionResult.toJson` leaves an empty one out); old rows keep theirs
   and the Why panel still shows them there.
3. The row is READ BACK, so every reader below (the bucket filing, the card,
   the message embedding, the draft pre-gates) sees the text this call just
   wrote.
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
2. **The storyline recap** (`_queueRecap`) — a message landing in a thread
   that is already in a storyline requeues that storyline's recap.
3. **The storyline assign** (`_queueAssign`) — first HOLDS while the
   thread's NEWEST kept inbound message has no summary and no extraction AND
   its text is still coming: it is untriaged (`pending`/`processing`, which
   reads as kept), or its `extract` row is `pending`/`processing`. An older
   message of the thread that finishes first then queues nothing and notes
   nothing, because the card would be the pre-extraction card the ledger
   rejected (45–47/98). The hold releases when the newest message's own
   extract item runs: its extraction calls this check, and so does the gated
   early return if triage dropped it meanwhile (the older message is then the
   newest kept); either pass closes the older message's storyline stage too
   (`noteStoryline` is per conversation). A newest message whose text is not
   coming (its extract row ended `error` or `skipped`, or none was queued)
   holds nothing, and the check runs on the card there is. The one hold
   nothing releases is a newest message whose extraction ends in a terminal
   `error` after an older message was held: the thread is not assigned until
   its next message arrives (rare, and no worse than that errored extraction
   already is). Otherwise it builds the
   thread's clustering card from the STORED facts through `clusteringCardFor`
   (the entry the assign pass builds through, so the two hashes agree) and
   compares its `cardHash` and `EmbeddingsClient.modelTag` with
   `conversation_ai`. Unchanged: the storyline stage closes `done` with the
   storyline the thread is already in, and no pass is queued. Changed or
   missing: `requeueWork('storyline', …)` and `onStorylineQueued`, which the
   app wires to pump the storyline lane, so the assign runs as each thread's
   card lands rather than after the whole extraction backlog. No embedding
   here: the assign pass (`StorylineService._keptVectorFor`) is the one
   writer of a conversation vector, and it re-checks the card when its lap
   ends ([06-storylines.md](06-storylines.md)). No conversation row: the
   stage closes `skipped`. Nothing in it throws; the text is already
   stored.
4. **Draft pre-gate** (`_queueDraft`) — decides whether a `draft` work row is
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

**Why the assign still waits for this stage.** On 2026-09-30 the assign was
moved to triage with cards buildable before extraction (`text`, the thread
text; `excerpt`, the newest message's words), and `make golden-sweep` read
45 and 47 of 98 against the `topics` card's 60: every pre-extraction card
proposed junk storylines, so the summary and topics this stage writes are
what make a cluster clean, and the assign went back behind it. What stayed
from that round: the card is embedded in the assign pass (`_keptVectorFor`, until
then `_refreshCard` here), and this stage wakes the storyline lane per
queued assign ([06-storylines.md](06-storylines.md)).

**The model call.**

| | |
|---|---|
| Task | `MessageTextTask` — `app/lib/services/llm/message_text_task.dart` |
| Prompt | `_messageTextRules` at the top of that file (the retired triage prompt's summary / action-item / deadline rules and the retired extraction prompt's topics / project rules, and nothing about the fields the decision model answers), composed with the shared untrusted-data fence (`prompt_guard.dart`); one prompt for mail and chat, pinned by `prompt_parity_test.dart` |
| Schema | `message_text` — flat, `summary` FIRST (the model states what the message is about before anything that follows from it), then `action_items` (≤3), `deadline`, `topics` (≤3), `project` |
| Caps | summary 500, action item 200, deadline 40, topic 80 (lowercased), project 60 — enforced in `validate` / `MessageTextResult.fromJson`, not the schema (this llama-server build turns the schema into a grammar and a `maxLength` it cannot convert costs the request) |
| Slot | the **generative** role (`stageLlmClientProvider('message_text')`, see [10-model-routing.md](10-model-routing.md)) |
| Params | **temperature 0** (set in `extract_handler.dart`: the same email must yield the same facts twice), maxTokens 512 |
| Concurrency | the target's text width, `LlmTargetSpec.textParallel`, read on every claim (`ExtractHandler(textParallel:)`, the `DraftHandler` shape): 8 on Your server, whether its URL follows the build or was typed (the owner's own server either way, and one with fewer slots queues the extra requests; the compiled box's prose-only profile is vLLM at `--max-num-seqs 16`; with a bulk slot the prose slot has 8 and vLLM queues the extra requests against the client's 90 s `LlmClient.proseTimeout` — on a one-slot server the eighth text waits ~7 calls, so a server slower than ~11 s per text would time out, and the box is ~4 s; a typed address was 3 until the 2026-10-01 replay), this Mac's `proseParallel` but never under 3; 3 with no closure (tests, benches). A triage yield now waits on up to 8 in-flight text calls instead of 3 — about one call's latency, since they run concurrently. `make bench-pipeline` has no text-width knob yet, so the 8 is unmeasured on the wall — see [10-model-routing.md](10-model-routing.md) |

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
