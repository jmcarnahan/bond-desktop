# 11 · Needs-you verdict

**Who reads this verdict.** The **notification settle** does — see
`09-notifications.md`. Three readers, together so the tile and the toast
cannot disagree: `notifyWorthy` counts `needs_you_verdict = 1` as a
message-level ask; `needsYouSql` counts it in the same position, so the settle
sweep's backstop writes the same `message_progress.needs_you`; and
`_isComplete` holds a candidate open while its `needs_you` work item is still
`pending` or `processing`. It is the **ask half only** — the attention
threshold, the `later` bucket and the `done` state gate a judged yes exactly as
they gate every other ask.

**Bucket filing** reads it too. A thread holding an unanswered judged yes is
never filed to Later by the automatic rule, in either writer — see
[08-attention.md](08-attention.md). That is what keeps the `later` gate above
honest: the only Later a judged yes can now sit behind is one a person asked
for.

**Attention scoring** reads it too — see [08-attention.md](08-attention.md).
`attentionScore` takes the newest inbound message's verdict off the
`latestInboundMeta` row: a judged yes breaks the quiet-FYI temper and earns the
direct boost, while NULL and 0 move nothing. It changes the score, never the
threshold; the slider still gates.

**The draft pre-gate** reads it as well — see
[04-extraction.md](04-extraction.md). `asksForAReply` counts
`needs_you_verdict = 1` as a fifth reason to spend the 27B's time, which is why
this handler is registered ahead of `ExtractHandler`. It only widens what gets
asked about; `ReplyDecisionTask` still decides whether a draft is written.

**What happens.** `NeedsYouHandler`
(`app/lib/services/needs_you_handler.dart`, run by `AiWorker`) answers one
question about one message — does this want the owner? — and writes the answer
onto the message's own row. It runs after triage and **before** extraction, so
the verdict is on the row by the time anything downstream asks about it.

**Two halves, and the cheap one runs first.** The deterministic floor is
`needsYouFloor(row)` in `app/lib/services/needs_you.dart`: an inbound Teams
message with `addressed_me = 1`. Teams ingest (`teams_sync.dart`'s
`messageRow`) sets that bit for a 1:1 chat *or* an @mention, so for chat the
one bit is the whole floor, and where it fires no model is asked. Mail's
`addressed_me` — sole To: recipient — is deliberately outside it: being the
only address on an envelope is a hint, not a verdict, and those rows are what
the model reads.

The floor can only **raise** the verdict. A message it says nothing about is
handed on rather than written down as a no.

**The model branch.** Everything below the floor goes to `NeedsYouTask`
(`app/lib/services/llm/needs_you_task.dart`) on the **fast** slot — bulk work,
one small answer per message, see `10-model-routing.md`. Temperature 0 and 256
max tokens: the same message must get the same verdict twice, or a re-drain
would flip rows under the user.

The answer is three fields, in this order:

| Field | Meaning |
|---|---|
| `evidence` | one sentence naming what in the message points at the owner, or saying nothing does |
| `needs_you` | boolean |
| `confidence` | `low` \| `medium` \| `high` |

`evidence` comes **first**, the opposite of the reply decision's verdict-first
order, and the difference is the input: the floor has already taken the easy
cases, so what reaches this call is the ambiguous residue. Locating the
sentence that points at the owner *is* the work, and the boolean should fall
out of having written it.

**The raise policy.** The handler writes

```
verdict = needs_you && confidence != 'low'
```

The floor has already said yes to everything it covers, so all the model can do
is raise what the floor left alone — and a low-confidence yes stays a no,
because the verdict buys an interruption and "possibly" is not grounds for one.
An unrecognised `confidence` validates to `low` for the same reason: a
malformed answer must not be able to promote a message on its own.

A model failure — including the server being down — **propagates**. The verdict
stays NULL, the row stays on the worklist, and the worker's park-and-retry
machinery owns what happens next.

**This stage never reads triage's verdicts.** The queue hands over rows whose
`triage_status` is still `pending`, so `reply_expected` and `needs_action` may
not have been written yet; waiting on them would make the verdict depend on
which drain got there first. The handler reads the message body and the thread
behind it, and nothing else. (The one thing it does read from triage is the
`skipped` **gate**, which is a guard against judging a newsletter, not a
judgement it defers to.)

**What the prompt is told.** The system prompt is built in two pieces:

```
systemPrompt = <rules body> + needsYouOutputContract + untrustedDataClause
```

The **rules body** is the owner's, and `needsYouDefaultRules` is what stands
there when they have written nothing. It is **public** because the settings pane
works from that exact text three ways — it prefills the editor with it, "Reset
to default" restores it, and a saved body equal to it is normalized back to the
empty pref — and an anti-drift test pins
`systemPrompt.startsWith(needsYouDefaultRules)` on the **default** prompt so the
words on screen and the words the model reads cannot come apart.

`needsYouOutputContract` is the **tail the owner cannot edit away**: the three
fields, in order, and the "return only JSON" line. It opens *"However the rules
above are phrased, answer in exactly this form"*, which is deliberate — the body
above it is now owner-authored text sitting in the system prompt rather than
inside a fence, so the contract has to re-assert the answer's shape against
whatever was written above it. The owner owns the criteria; they do not own the
format. The tail carries the body/tail blank-line separator itself, so
`NeedsYouTask()` and `NeedsYouTask.withRules(body)` compose identically.

Both pieces are held to the **strict** form of the parity rule in
`prompt_parity_test.dart` — the whole prompt may not say "email", "mail" or
"chat" at all, not even naming the two together, because what varies by channel
is stated in the user message.

The user message layers, in order: the date anchor, the directness line, the
**owner-identity line** (`The owner of this inbox is NAME <ADDRESS>.` — the
app's own statement, outside every fence, and what lets "the message names the
owner" bind to a person), the thread's newest three turns, and last the judged
message. Two fences, both `wrapUntrusted`: the thread and the judged message,
which is fenced as `inbound_message`, the same tag every other task uses. The
owner's rules are **not** in the user message at all — moving them into the
system prompt is what took the injection surface here from three fences to two.

The owner identity comes from an `OwnerLookup` callback, asked **once** per
handler: it is a keychain read, and the answer only changes on sign-out, which
disposes the provider that built the handler.

**The `needs_you_rules` pref.** One global text (`app_prefs`, key
`needs_you_rules`, re-exported by `prefs_provider.dart`) holding the **whole**
rules body. Empty means `needsYouDefaultRules` is in force — the empty string is
how the app says "the defaults", not "no rules". Read per message so an edit
mid-drain applies to the rest of the drain, and **memoized on its own text** in
the handler (`_taskFor`): an unchanged pref reuses the same `NeedsYouTask`, and
so the same system-prompt string object, because llama-server caches the KV
prefix on the bytes. The cache therefore re-primes once per rules **edit** and
then holds, rather than once per message.

Stored **verbatim** — the editor trims before it calls, and trimming again in
the store would mean the text in the field and the text the model reads are not
the same string. Capped at `needsYouRulesCap` = 4000, which is both the clamp in
`_taskFor` and the `maxLength` the editor enforces: a cap the editor did not
show would silently drop the end of what somebody typed, and the clamp is there
for a pref that reached the store through something other than the editor. A body
equal to the defaults takes the const default path either way. It is one
person's text, so `wipeAll` clears it alongside `about_me` — inherited by the
next identity it would decide what *they* get interrupted about.

**Where it is edited.** Settings → the **Needs You** section, whose body is the
threshold slider above `NeedsYouRulesEditor`
(`app/lib/widgets/needs_you_rules_editor.dart`). The two belong together: the
slider says how much gets through, the rules say what "needs you" means in the
first place. There is no separate pane to open and no dialog to pop — Settings
is itself a full screen with a back arrow (see [../settings.md](../settings.md)).

**Save is the only thing that commits**: Cancel puts the last saved text back in
the field and stays, and being disposed discards. The about-me field beside it
keeps the same contract now — neither text is written on the way out.

The field is **prefilled with `needsYouDefaultRules`** rather than left blank,
because those defaults are the text actually in force; what the owner edits is
the real thing. **"Reset to default"** puts them back, and like every other edit
in the section it is local until Save. Saving a body identical to the defaults
stores the **empty** pref — otherwise the same words would arrive as an
equal-but-not-identical string and fork the const prompt (and the identity pin
on it) for no change in what is asked. The editor trims, the store keeps the
result verbatim.

A collapsed disclosure, **"What Bond adds after your rules"**, shows
`needsYouOutputContract` **verbatim** (left-trimmed only, since it opens with
the separator blank line). Somebody who may replace every word of the body and
not one word of the tail is owed the sight of it.

The owner's about-me text is deliberately **not** in this prompt. Two
owner-authored free-texts in one call is the charter-versus-summary confusion
this app avoids elsewhere; the needs-you rules are the one owner text this
judgement reads.

**Storage.** Two columns on `messages`, added in schema v10:

| Column | Meaning |
|---|---|
| `needs_you_verdict` | tri-state INTEGER — NULL never judged, 0 judged no, 1 judged yes |
| `needs_you_reason` | why: `teams_direct` from the floor, or the model's evidence sentence |

The tri-state is load-bearing. NULL is not "no" — the unjudged rows *are* the
worklist, so nothing may read the two as one. The v10 migration adds the
columns and backfills nothing for exactly that reason: a stored mailbox is
entirely unjudged, which is what the pass is looking for.
`MessageStore.upsertMessage`'s conflict branch does not name these columns, so
a re-sync cannot clobber a verdict.

**The chip follows the verdict.** `message_progress.needs_you` is a snapshot
taken at settle time from `notifyWorthy` — the same call that decided whether
to interrupt — so a verdict written *afterwards* would leave the home screen's
chip and tile showing an answer the pipeline has changed its mind about. When,
and only when, the stored verdict MOVES (`null`→0/1, 0↔1), `NeedsYouHandler`
hands the message to `PipelineProgress.refreshNeedsYou`, which re-asks
`notifyWorthy` and rewrites the flag through
`MessageStore.refreshNeedsYouFlag`. Four rules make that safe. A re-verdict
that returns the **same** answer writes nothing, so a chip cleared by a reply
or by a Done stays cleared. Only a **settled** row is touched; an unsettled one
takes its snapshot at settle from the same predicate. A **dropped** row is left
alone, because the feed hides it and the tile counts it. And the path adds an
outbound guard `notifyWorthy` has no need of — the coordinator settles before
any reply can exist — so a false→true re-verdict never re-chips a thread the
user has already answered or marked done. Reading is deliberately *not* a
clearing condition: a chip once earned survives being read.

**The one-shot flag backfill.** Rows that settled before the v11 verdict column
existed took a snapshot that never saw it, so a message later judged yes sits
at `needs_you_verdict = 1` beside `needs_you = 0`.
`MessageStore.backfillNeedsYouFromVerdicts` raises those chips once, behind the
`needs_you_flag_backfill` pref in the mail sync, reported as
`backfilled_needs_you` on the activity row (absent, not zero, when it did not
run). Raise-only, and carrying the same guards as the live path — both guard on
`dropped = 0`, so a gate cascade, which also writes `settle_state = 'done'`,
stays dropped either way.

**Queueing.** `MessageStore.enqueueNeedsYouBacklog` is
`enqueueExtractBacklog`'s twin — same filter, same caps, same `OR IGNORE`
idempotence, one shared private statement — and both syncs call the two side
by side (`sync_service.dart`, `teams_sync.dart`, counted as `queued_needs_you`
on the sync activity row). The symmetry is the guarantee that the verdict set
covers exactly the rows extraction will read.

**The one-shot revive.** The build that shipped only the floor completed its
below-floor items as `done` with a NULL verdict, and `INSERT OR IGNORE` will
never offer those rows again. `MessageStore.reviveUnjudgedNeedsYou` puts them
back to `pending` with `attempts` reset; the mail sync runs it once, behind the
`needs_you_model_revive` pref, and reports it as `revived_needs_you` on the
activity row (absent, not zero, when it did not run — "did not run" and "ran
and found nothing" are different facts). One run covers both sources: the SQL
has no source filter, which is why `teams_sync.dart` does not repeat it. The
predicate is deliberately simple, and the price is that gated and outbound rows
with a NULL verdict are revived too and leave again through the handler's own
guards — one queue row each, once.

**Handler position and failure behavior.** First in the `aiWorkerProvider`
handler list, ahead of extraction; `concurrency` 3, since an item touches only
its own row. It early-returns *done* on the shapes the queue can hand over
stale — deleted, outbound, gated (with the `teams_source` tolerance every
post-triage stage keeps) — and records the reason on its activity row.

It has **no arm** in `AiWorker`'s `_park` / `_recordFailure` per-kind ladders,
deliberately. Those ladders exist to re-note a `message_progress` stage state
when the worker rather than the handler decides how an exception ended;
needs-you has no stage column, so an arm there would write nothing. The generic
parking above those ladders still applies: a fast server that is not running
parks the whole kind rather than burning attempts on it.

## Activity tabs on the overview

The Needs You overview is five lenses on one pile, as a
`BondFilterPillRow<NeedsYouTab>` (`Key('needs-you-tabs')`) above the list:
**All · Asked of me · Waiting on others · Deadlines · Suggested drafts**.

`All` leads and is the default, so arriving at the stop shows exactly what the
stop always showed — the ranked list, at the same threshold as the rail, so the
`+N more` row opens the list it promised. The other four are **filters over that
same list** (`needsYouTabRows`, pure, in
`app/lib/widgets/needs_you_tabs.dart`), never a second query: the ranking was
decided once, and a tab that re-read the store would eventually rank differently
from the column beside it. The order survives every tab, so the third row on
Deadlines is the same thread it was on All.

Asked of me and Waiting on others are **complements of one predicate**
(`isWaitingRow`), the same way Needs You itself partitions the inbox — every row
is on exactly one of the two, and their counts add back up to All.

The other two read **two read-time columns on `loadConversations`**, and no
schema changed for either:

- `latest_deadline` — the newest inbound message's `deadline`, in the sender's
  own words. The newest one's and nobody else's: a date named three replies ago
  has already been answered or overtaken.
- `pending_draft_count` — suggestions in `('suggested','edited')` against that
  same newest inbound message. The subselect is `getDraft`'s, so a thread this
  counts and a thread whose composer is full are the same thread.

Both are null/zero on any read that does not run the subqueries, which reads as
"no date named" and "nothing suggested" rather than inventing either.

On the Deadlines tab each row's second line becomes `Deadline · <the text>`
(`ConversationListPane.captionFor` → `ConversationRow.caption`), replacing the
ask. On a list the reader picked BECAUSE every row has a date on it, the date is
worth more than another copy of an ask the row's title already carries.

## What the documents on a message say

`NeedsYouInput.attachmentDigests` is one line per digested document on **this
message** — `<name>: <summary>` plus ` Asks: <a; b>` when the digest recorded
any — built by `attachmentDigestLines`
(`app/lib/services/attachments/attachment_digest_lines.dart`) from
`MessageStore.digestsForMessages(source, [id])`. Rows with no readable digest
are skipped: "not read yet" and "says nothing" are different states, and only
the second is worth a line.

It sits in the user message after the thread block and before `Judge ONLY this
message:`, inside `<untrusted_data source="attachment_digests">`, clamped to
600 characters in total (each line to 300 of its own). The judged message stays
last, as it always has. The fence count in `needs_you_task_test` went from two
to three deliberately — what a file says is the sender's text like any other,
so it arrives fenced rather than as a line the app appears to be asserting.

The digests and not the documents: this judgement turns on what a file *asks
for*, which is one sentence. The file's own words are the retriever's business
(see `07-replies.md`), and a contract in this prompt would drown the message it
is about. The system prompt does not change.

## The re-verdict

**Saving the Needs You rules is a trigger.** The editor replaces the whole
prompt body, so every verdict on disk was written under words the owner has
just replaced. `MessageStore.requeueNeedsYouRejudge` therefore re-queues the
last **7 days** of kept inbound messages — newest first, capped at **200** —
through the ordinary `needs_you` work kind, and the chip follows each new
verdict per **The chip follows the verdict** above. Older verdicts stay as they
are: those rules were the rules when those messages landed, so they are history
rather than mistakes. Saving text identical to what is stored queues nothing.
The Settings section's summary reads "judging N messages" while the queue
drains, and one `needs_you_rejudge` activity row records the count.

A document that asks for a signature can change whether its message wants the
owner — and the first needs-you pass ran before anything had read it. Whatever
triggers a re-judge, the chip on the home screen follows it: see **The chip
follows the verdict** above.
`AttachmentDigestHandler` therefore requeues the message once, right after the
digest chunk is embedded:

```
digest.asks.isNotEmpty
  && message.direction == 'inbound'
  && message.needs_you_verdict != 1
  && attachmentsWithAsks(source, messageId) == 1
```

`== 1` is the whole guard against one requeue per file: `setAttachmentDigest`
has already written this row by the time the count is taken, so the first
document on a message to carry an ask sees exactly 1 and every later one sees 2
or more. The other three each refuse their own case — the owner's own message
is never judged, a verdict already at `1` cannot be raised, and asks are the
only part of a digest that can move the verdict.

Needs-you drains ahead of `attachment_digest`, so the pass that would have
picked the requeue up has already gone by — which is why the handler also
**wakes the worker**: its `onRequeue` callback is wired in `app_providers.dart`
to `AiWorker.pump()`, which on a running drain only sets the re-pump flag and
returns that drain's future (never awaited inside the handler, since that
future is the drain the handler is running in). The drain then makes one more
full pass, and the re-verdict lands in the **same** drain. That matters for the
notification settle, which holds a message's candidate open while its
`needs_you` item is pending: without the wake, a document that asks for
something would cost its message up to the six-minute settle deadline.
`requeueWork` revives only `done` and `error` rows, so a message still waiting
for its first verdict keeps its place in the queue rather than being reset.
The activity row for the digest notes `requeued: needs_you`
(`ActivityLog.note` merges, so it lands beside the digest's own facts).

This was deferred out of Phase 3 on purpose: a re-verdict before the
`attachment_digests` fence existed would have spent a model call on a
re-judgement that could not see what changed.

## The Why panel

This section supersedes the position this file took until now, that
`needs_you_reason` was stored against a future reader: it has one. The Why
panel (`lib/widgets/why_panel.dart`, `WhyPanelBody`) is the explanation beside
a message, and the reason is the first thing on it.

**What it reads.** Five blocks, in this order.

| Block | Source |
|---|---|
| Verdict | `Message.needsYouVerdict` / `needsYouReason`, now parsed in `Message.fromRow`; `gateReason` when the gate took the message |
| Triage | the message's `triageStatus`, `summary`, `urgency`, `category`, `label` |
| Asks | `needsAction`, `replyExpected`, `deadline`, `addressedMe`, `actionItems` |
| Attention | the thread's `attentionScore` against the reader's own threshold, then `conversation_ai`'s `bucket`, `bucket_reason` and `snoozed_until` |
| What it is about | `MessageStore.extractionFor(source, messageId)` — `getExtraction` decoded through `ExtractionResult.fromJson`, and null on a blob that will not parse |

The facts come from `whyFactsProvider` (`lib/providers/why_provider.dart`), a
`FutureProvider.autoDispose.family` keyed by the record
`({source, conversationKey, messageId})`. Deliberately not a slice of the open
thread: the panel has to work for a message whose transcript is not the one
loaded — opened from a side thread, from a room — and a provider that depended
on the thread provider would show an empty panel exactly then.

**The tri-state survives into the copy.** `true` reads *Needs you*, `false`
reads *Not flagged*, and NULL reads *Not judged yet* with the line "The
needs-you pass has not reached this message." Three answers, never two: a panel
that rendered NULL as "not flagged" would be claiming a judgement the pass has
not made, which is exactly the confusion the tri-state column exists to
prevent.

**How it opens.** Two gestures, both in `ThreadDetailPanel`. Hovering an
inbound transcript row gives a third button on the strip, **Why**
(`HoverActions.whyKeyFor(messageId)`), beside Reply and Suggest. And the CTA
banner above the transcript now opens Why on the **newest inbound** message
rather than focusing the composer — the box is docked and always visible, so
"put the cursor in it" was a click nobody needed help with, while "where did
this ask come from" had no answer anywhere. With no Why wired, or on a thread
with nothing inbound in it, the banner falls back to focusing the composer as
it always did. Every per-message ask line still focuses the box.

**What it never does.** It feeds nothing back. This reads model OUTPUT that
has already been through the untrusted-data fence upstream; it writes nothing,
sends nothing and prompts nothing, so there is no second fence here. And it
renders sentences, never stored shapes — no JSON, no enum names dressed as
prose, no field names. `teams_direct` reads "A direct message to you on
Teams."; `sender_pref` reads "a rule about the sender". `why_panel_test`
asserts no brace and no underscore ever reaches the screen.

**The door to the history.** `WhyPanelBody.onWhatHappened` draws one final
quiet `What happened ›` button (`WhyPanelBody.whatHappenedKey`) when it is set,
and nothing at all when it is null — a dead link is worse than no link. The
shell wires it to the message's history, which opens in the SAME side slot in
place of the Why panel: Why is the verdict in a paragraph, the history is every
stage, judgement and queue row behind it, with the levers — see
[README.md](README.md#finding-out-what-happened-to-a-message). The two read the
same rows (`needs_you_verdict`, `needs_you_reason`, the extraction, the
attention row) through their own reads, by decision: `whyFactsProvider` is
three store calls and `messageHistoryProvider` is eight, and the smaller one
is what makes Why cheap enough to open from a hover.
