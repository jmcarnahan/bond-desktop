# 11 · Needs You

**The rule.** A message needs the owner when the decision model's calibrated
probability that it does, `messages.needs_you_p`, is at or above the owner's
**Needs You slider** (`needs_you_threshold`, Settings → Needs You). That is the
whole rule. No band hands a middle probability to a language model, there is no
cold-outreach bar, no Teams 1:1 or @mention floor, no attachment-digest requeue
and no owner-written rules text. **No generative model is asked about needs-you
at all**, on any path. The slider is the owner's control over the cut, and
moving it re-reads stored probabilities without asking any model anything. The
owner's other control, **their own answers** (below), is already inside the
probability, so the rule never reads it separately.

The rule is ONE predicate with two spellings, in
`app/lib/services/decision/needs_you_predicate.dart`: `needsYouAt(p, threshold)`
for Dart and `needsYouAtSql(column, threshold)` for a query, pinned to agree by
`needs_you_predicate_test`. NULL is a message not decided yet. It needs nobody in
either spelling, and it is never shown as a low probability.

**The owner's answer.** "Remove from Needs You" and "Add to Needs You" on a
thread (`NeedsYouEdits`, `app/lib/services/needs_you_edits.dart`) store the
owner's word as a LABEL: a `question = 'needs_you'` row of `decision_labels`
with `answer` `no` or `yes`, `origin` `remove` or `add`, the message, and the
decision model's raw pooled vector of that message with the model tag it came
from. A removal labels every message of the thread's Needs You window (the
kept inbound after the last outbound, the messages the thread's number is the
max over); an addition labels the newest one. The label is then applied where
every decision is written, `applyDecision` (`triage_queue.dart`), through
`NeedsYouExemplars` (`app/lib/services/decision/needs_you_exemplars.dart`):
before the decision is stored, its `needs_you` becomes the owner's answer with
certainty (p 1.0 or 0.0) when the message itself carries a label (EXACT; the
newest row for a message wins) or when its vector is within cosine
`NeedsYouExemplarTuning.matchCosine` = **0.97** of a label's vector under the
same model tag (SIMILAR; the nearest wins). The 0.97 is measured on the
owner's audit: templated duplicates sit at 0.99 or above, unrelated mail at a
median of 0.27, and at 0.97 two presses cleared 125 of 185 wrong threads with
no correct thread caught (`docs/model-bakeoff.md`, "Needs You audit"). Because
the override lands in the stored number, every path inherits it with no code
of its own: the triage claim, the needs-you pass's copy step and re-decide,
the install-time re-decide, Re-judge and Clear AI results' re-triage. The
reason says so: "You removed this message from Needs You." / "You removed a
message like this from Needs You." (and "added … to"), from the scalar
`owner_answer` and `owner_exact` keys in `answers_json` beside
`owner_label_id` and `owner_cosine`.

A removal then **sweeps**: every thread still in Needs You at the slider has
every message of its window decided again (not only the highest-p one: a
templated thread often holds several near-duplicates, and the next would
become the driver) through the same `decide` + `applyDecision` path,
unawaited after the pressed thread is written, so the near-duplicates leave
with their chips, and the conversation list reloads once when it ends. It
runs only when a label the press wrote carries a vector. No work kind, no
durable queue: a second press during a sweep makes it run one more pass, a
decision server that cannot answer stops it with one log line, a per-message
fault is logged and that message keeps its current decision, processing
turned off stops it, and a crash mid-sweep costs a second press — the labels
are stored first, so the next sweep, or any later decision of those messages,
applies them. An addition sweeps nothing.

**Undo is a retract, not the opposite press.** `remove` and `add` return a
`NeedsYouPress`: the label ids they wrote and the ONE `created_at` stamp every
one of them carries (empty ids when the window was empty).
`NeedsYouEdits.retract(press)` DELETES those rows (`deleteNeedsYouLabels(ids,
createdAt:)`, the one delete the log takes short of a wipe), then decides
again every message whose stored decision cites one of them
(`owner_label_id`, `messagesCitingNeedsYouLabels`): the pressed thread AND
every thread the sweep removed take the model's number back, unless another
label still matches. The stamp is there because `decision_labels.id` has no
AUTOINCREMENT: a deleted highest id is handed out again, and an Undo retried
with stale ids must not delete a newer press's label (an id a newer press
holds is left to that press entirely). A sweep still running from the press
can have matched a label before the delete and write its 0.0 after it, so the
retract waits out the sweep's message in flight and then asks again which
messages cite the deleted ids, deciding those again, for at most three rounds.
An opposite label would instead tie the removed one for every
near-duplicate, and the newer `yes` would put the whole template in Needs You.

**Decide first, write second.** A press decides every message of the window
(the one network step) before it writes any label or decision, and a retract
decides the citing messages before it deletes the labels, then writes each
with its fetched result (`applyDecision` looks the owner's answer up at write
time, so the deleted labels no longer match). A decision server that cannot
answer therefore fails a press or an Undo with NOTHING written, so the failure
bar's "the thread is unchanged" holds literally, and a failed retract can be
run again with the same press. Processing turned off refuses all three the
same way, before anything is touched (`StateError('processing is off')`): an
Undo that deleted the labels and then stopped at the switch would leave the
answers in place with no label behind them. Labels are compared only
under their own model tag; a label whose message is decided under another
model (or with no vector) has its vector refreshed from that decision, so a
model swap heals the labels as the install-time re-decide reaches their
messages. **Kev** (the `systemone` backend) returns no vector: on it a label
applies to its own message only, and no sweep runs.

Known limits: a needs-you pass that read the model's decision just before a
press rewrote it can copy the model's p back onto `messages` (the decision
row keeps the owner's answer, and the next needs-you item for the message
copies it again); and a message pressed while its triage is still pending can
still be dropped by the learned gate when its claim runs, which takes it out
of the window. An Undo's re-asking covers the sweep of its own
`NeedsYouEdits`; a triage claim, a needs-you re-decide or the install-time
re-decide that matched a label just before the Undo deleted it and writes
after the last round still cites the deleted label until that message is next
decided, and so does a sweep still running on an older `NeedsYouEdits` after
the provider was rebuilt (a decision-client change).

**The slider's default is 0.35.** It is fitted on the golden set, keep-only
needs_you of 76, and it moves with the decision model, because a probability's
scale belongs to the model that gave it. On the v2 model (2026-09-29) the best
cut was 0.30 at 69/76 (one false positive, six misses) against 67/76 at 0.50.
On the shipped v3 model (2026-09-30) 0.35 scores 70/76 with no false positive
and six misses, where 0.30 scores 67/76 (three and six) and 0.20 scores 69/76
(four and three). Both sweeps are in the bakeoff ledger
(`docs/model-bakeoff.md`). The slider runs from 0.05 to
0.95 in 0.05 notches (`NeedsYouTuning`), and a stored value is normalized onto a
notch, so the number the slider shows is the number the queries bind.

**A thread** needs the owner when it is not `done`, is not bucketed `later`, and
its **needs-you probability** is at or above the slider. The thread's
probability is `MessageStore.threadNeedsYouPSql`: the HIGHEST `needs_you_p` over
its KEPT inbound messages received after its last outbound (every kept inbound
when the owner never wrote on it). An older ask still unanswered keeps counting,
so a bystander's reply-all cannot hide it. Once the owner replies, only newer
messages count. `loadConversations` loads it as `Conversation.needsYouP`, and
the `needs_you_reason` it carries comes off the message with that highest
probability (newest on a tie), so the reason names the message whose number is
shown.

**The two buttons.** The thread's action bar (`ThreadActionBar`, built by
`ThreadDetailPanel._actionBar()`) carries exactly one of **Remove from Needs
You** (`thread-action-needs-you-remove`) and **Add to Needs You**
(`thread-action-needs-you-add`), beside Mark done and Later, picked by the
rail's own rule (`isNeedsYou` at the owner's slider): Remove on a thread in
Needs You, Add on one that is not. Add is never drawn on a Done thread
(Reopen is there) or one in Later (Keep in inbox is): Needs You reads
neither, so the press would change nothing the reader could see. Both are
labelled buttons, and the Needs You word gives way to its icon before Mark
done's does when the row runs short. Remove runs `_triageAndAdvance`, like
Mark done: the thread leaves the pile and the reader lands on the next row,
and the bar says **"Removed from Needs You — and anything like it."** with an
Undo; Add leaves the reader where they are and says **"Added to Needs You."**
with an Undo. Each goes through `ConversationsNotifier.removeFromNeedsYou` /
`addToNeedsYou` (the press, then a store-only reload; the sweep reloads again
when it ends). Undo is `ConversationsNotifier.undoNeedsYouPress`, the retract
above — the threads the sweep took come back with the pressed one. A thread
whose window is empty (the owner wrote last) says **"Nothing here is waiting
on you."** with no Undo and moves nobody. A press the decision model could not
answer says **"Couldn't save that just now — the thread is unchanged."** with
no Undo and moves nobody; a failed Undo says "Couldn't undo that just now."
The landing is worked out before the press, and the next row is often a near
duplicate the sweep takes a moment later; while the reader has not moved off
that landing, every list reload that finds it gone steps them on to the
nearest row still drawn (`_followSweptLanding`, over `_stepFromDeparted`).

**Who reads it.** Every reader goes through the one predicate at the owner's
slider:

- **The rail** (`isNeedsYou` in `app/lib/widgets/app_rail.dart`) and **the Home
  tile and Needs You filter** (`_liveNeedsYouThread` in `message_store.dart`,
  the same SQL). The two agree exactly. The attention score only ORDERS the
  pile (see [08-attention.md](08-attention.md)).
- **The notification settle** (see [09-notifications.md](09-notifications.md)):
  `notifyWorthy` is the predicate on the message's own `needs_you_p`, plus a
  thread that is not `done` and not `later`. `needsYouSql`
  (`app/lib/data/progress_sql.dart`) says the same in SQL for the settle
  sweep's backstop, with the read guard the coordinator applies first. The
  frozen v8 migration keeps its own text, `needsYouSqlV8Frozen`, byte for byte.
  `_isComplete` counts a candidate's needs-you as judged as soon as its
  `needs_you_p` is not NULL, whatever work item is pending (or, with the p
  still NULL, once its `needs_you` item is `done` or `error`).
- **Bucket filing and attention scoring** (see
  [08-attention.md](08-attention.md)): a thread holding an unanswered message
  over the slider is never filed to Later by the automatic rule, and the newest
  inbound message's answer breaks the quiet-FYI temper and earns the direct
  boost.
- **The draft pre-gates** (see [04-extraction.md](04-extraction.md) and
  [07-replies.md](07-replies.md)): `prefetchWorthy`, the default **Suggested
  replies** mode's gate, is exactly the predicate; `asksForAReply` counts it as
  one of its five signals. The reply decision (the decision model's stored
  `reply_expected`) still decides whether a draft is written.
- **The mention index** reads a probability below the slider as the decision
  model's no.

**Where the probability comes from.** The triage pass writes it. For every
message it keeps, `TriageQueue` writes `needs_you_p` and a templated
`needs_you_reason` in the same step as the rest of the decision
(`writeNeedsYouP`).

**One ownerless policy.** The head was trained with the owner line in its
state, so a decision made before the keychain answered is UNTRUSTED, but it is
not hidden: its probability is written and shown like any other, and
`message_decisions.owner_known` (inside `answers_json`) records that it was
ownerless. Every mail sync requeues the needs-you pass for each triaged inbound
message whose decision is ownerless (`MessageStore.requeueOwnerlessNeedsYou`,
both sources in one statement, reported as `requeued_needs_you_ownerless` when
it found any), and so does **Retry owed stages** for one message
(`PipelineRepairService.retryOwed`). The pass then decides the message again
WITH the owner once the owner is known. While the owner is still unknown it
keeps the ownerless probability and returns, so a requeue before the keychain
answers is a no-op rather than a model call. A re-decision records the owner,
and the message stops matching.

The reason is templated from the decision, because the heads write no evidence
(`needsYouYesReason` in `app/lib/services/decision/decision_policy.dart`):
intent `approval` → "Asks you to approve something.", `question` → "Asks you a
question.", `request` → "Asks you to do something.", `scheduling` → "Asks you
about a time.", else p(reply_expected) ≥ `DecisionPolicy.replyYes` → "Expects a
reply from you.", else "Names you and needs your attention." It is written
beside the probability whatever its value, because whether it reads as a yes is
the slider's call at read time. Rows from before v21 may still carry
`teams_direct`, the retired Teams floor's token, or an evidence sentence from a
language model. Every surface still words both.

**The Teams floor survives in one place.** `needsYouFloor(row)`
(`app/lib/services/needs_you.dart`, an inbound Teams message with
`addressed_me = 1`: a 1:1 chat or an @mention) no longer raises anything. What
it still does is keep the learned gate off such a message in the triage pass:
somebody wrote to the owner by name, and no learned gate takes that message.

**The needs-you pass only settles the probability.** `NeedsYouHandler`
(`app/lib/services/needs_you_handler.dart`, the `needs_you` work kind on the
fast lane, ahead of extraction, `concurrency` 3) takes no language-model client.
Per message it:

1. early-returns *done* on the shapes the queue can hand over stale (deleted,
   outbound, gated, with the `teams_source` tolerance every post-triage stage
   keeps) and records the reason on its activity row;
2. when the stored decision was made with the owner known, or was made
   ownerless and the owner is STILL unknown, **copies** its probability and
   templated reason onto the row if the row's differs, and otherwise writes
   nothing;
3. when the decision was made **ownerless** and the owner is now known, or
   there is no decision at all (triaged before the decision model),
   **re-decides** the message with the decision model, on the input the triage
   pass builds (`decisionInputFor`), and writes the whole state that decision
   determines through the triage claim's own writer (`applyDecision`): the
   decision row, the four triage fields, the probability, the extraction's
   intent and importance, and the thread's CTA fold. With no decision and the owner still unknown the message is
   decided ownerless anyway and written, because an undecided row is a message
   nobody sees; the ownerless requeue above brings it back once the owner is
   known.

A decision server that is down, or heads the client refuses, THROWS, and the
throw is left to the worker, which parks the kind. Nothing falls back to a
language model. The handler has **no arm** in `AiWorker`'s `_park` /
`_recordFailure` per-kind ladders, deliberately: those re-note a
`message_progress` stage state, and needs-you has no stage column.

**Storage.** `messages.needs_you_p` (REAL, schema v21) is the ONE number every
reader reads; NULL means not decided. `messages.needs_you_reason` says why.
`message_decisions` keeps the decision's own `needs_you_p` beside its other
answers. The owner's answers are `decision_labels` rows (KEPT, so Clear AI
results keeps them and the next decision applies them again; `wipeAll` deletes
them) with three columns added in v23: `source_message_id`, `vector` (BLOB,
float32 little-endian, `encodeEmbedding`) and `vector_model`.
`messages.needs_you_verdict` is INERT since v21: v21 mapped it into
`needs_you_p`, and nothing writes or reads it any more. The pref key
`needs_you_rules` is inert too. Nothing reads it, and `wipeAll` still clears a
stored copy with the rest of one person's text.

**The chip follows the probability.** `message_progress.needs_you` is a
snapshot taken at settle time from `notifyWorthy`. When any decision writer
changes a probability ACROSS the owner's slider (the needs-you pass, and
through `applyDecision` the triage claim, the install-time re-decide and the
owner's Needs You presses and their sweep), the
shared `followNeedsYouChip` hands the message to
`PipelineProgress.refreshNeedsYou`, which re-asks `notifyWorthy` and rewrites
the flag. A probability that moved without crossing the slider is a repeat of
the answer and writes nothing, so a chip cleared by a reply or by a Done stays
cleared. Only a settled, non-dropped row is touched, and a false→true change
never re-chips a thread the owner has already answered or marked done. Reading
is not a clearing condition.

**The one-shots** run once each, behind their prefs in the mail sync.
`needs_you_model_revive` puts back `done` work rows whose message has no
probability. `needs_you_flag_backfill_p` raises settled chips whose message now
clears the slider (and whose thread is open, unanswered and not in Later), and
`needs_you_flag_veto_p` lowers every settled chip `notifyWorthy` would not
grant today: a message below the slider or not decided, or a thread done or in
Later. They are the v21 pair: the older `needs_you_flag_backfill` and
`needs_you_flag_veto` ran under the verdict rule and are set on every machine
that ran an earlier build, so the probability rule reconciles the chips under
keys of its own. Both `_p` keys are in `derivedOneShotPrefs`, so Clear AI
results and a wipe reopen them. `needs_you_hedge_rejudge` requeues every in-window `needs_you_p =
0.0`, which an older build's hedge can have become, so the pass settles each
one again. Each reports its count on the sync's activity row, absent rather than
zero when it did not run.

**The chip follows the thread out of Later, too.** A message that settles while
its thread sits in Later takes a 0 on the strength of the bucket alone, and
lifting the bucket moves no probability. Both ways out of Later for one thread,
a deferral whose date arrived and Keep in inbox, run
`PipelineProgress.raiseNeedsYouForThread`. See [08-attention.md](08-attention.md).

**Queueing.** `MessageStore.enqueueNeedsYouBacklog` is
`enqueueExtractBacklog`'s twin, with the same filter, caps and `OR IGNORE`
idempotence, and both syncs call the two side by side (counted as
`queued_needs_you` on the sync activity row). The standing revive,
`reviveOwedMessageStages`, files `needs_you` beside `extract` and
`embed_message` for kept inbound rows the window stopped reaching before their
work was queued (see [01-sync-ingest.md](01-sync-ingest.md)). Clear AI results
queues the pass for every kept message itself.

## Activity tabs on the overview

The Needs You overview is five lenses on one pile, as a
`BondFilterPillRow<NeedsYouTab>` (`Key('needs-you-tabs')`) above the list:
**All · Asked of me · Waiting on others · Deadlines · Suggested drafts**. A
sixth filter, not a sixth tab, sits under them as a second pill row when the
owner has labels:
the label lens (`NeedsYouLabelFilter`, `needsYouLabelRows`) narrows the same
ranked pile to the threads wearing one label, and a null pick is the whole
pile.

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
  has already been answered or overtaken. The Deadlines tab keeps a row only
  when `showableDeadline` answers for it, so a plan-relative "Day 1" does not
  put a thread there (see [08-attention.md](08-attention.md)).
- `pending_draft_count` — suggestions in `('suggested','edited')` against that
  same newest inbound message. The subselect is `getDraft`'s, so a thread this
  counts and a thread whose composer is full are the same thread.

Both are null/zero on any read that does not run the subqueries, which reads as
"no date named" and "nothing suggested" rather than inventing either.

On the Deadlines tab each row's second line becomes `Deadline · <the text>`
(`ConversationListPane.captionFor` → `ConversationRow.caption`), replacing the
ask. On a list the reader picked BECAUSE every row has a date on it, the date is
worth more than another copy of an ask the row's title already carries.

A row tapped on this overview opens **beside** the list rather than over it,
highlighted here while it is open — the overview is a room the reader is
standing in, and ⤢ on the panel is how a thread gets the whole pane. See
`docs/shell.md`, "What opens where".

### Order

The pile has ONE order everywhere it is drawn — the rail's Needs You section,
this overview, and the row Enter opens from Find — and the reader chooses it:
`By priority` (`needsYouRows`' own ranking: needs-reply first, then attention
score; the default), `Newest first` (`lastMessageAt` descending, stable, an
undated row last), `Quick wins` (a partition: threads `isQuickWin` can see an
end to, meaning triage expected no reply or the thread has no ask and at most
three messages, move above the rest, each half keeping its ranking) or
`Oldest first` (the clock backwards, still stable, an undated row still
last). The choice lives on the overview's order control
(`Key('needs-you-sort')`, a `PopupMenuButton` beside the pills) and is kept in
the `needs_you_sort` preference, so it survives a restart and reaches every
place the pile is drawn.

`sortNeedsYou` (pure, in `app/lib/models/needs_you_sort.dart`, re-exported by
`needs_you_tabs.dart`) is the one implementation. It is applied to the WHOLE
pile — before Find's matching, before the rail's `AttentionTuning.topCount`
truncation, and before the tabs filter — which is what keeps the three views
agreeing: `+N more` opens the list in the order the rail showed, Enter opens the
row under the reader's eyes, and a tab filters an ordered pile rather than
reordering it. It never adds or drops a row, so the badge over the section is
unaffected by it.

## Keys on the overview

The pile is worked from the keyboard through one `Shortcuts` + `Actions` pair
over the list and the thread (`triageKeys` in
`app/lib/screens/inbox_screen.dart`, the intents in
`app/lib/widgets/triage_intents.dart`), so a key, a row's button and the cheat
sheet run the same code. Every single letter is inert while the cursor is in
something that takes typing (`_keysLive`); Escape is not.

- **Walking keys repeat.** `j` / ↓ and `k` / ↑ step to the next and previous
  row, `]` / `[` to the next and previous mention in the open thread, `z` (or
  ⌘Z) replays the last toast's Undo, and `?` opens the cheat sheet beside.
  Escape closes an open picker or quick reply, or with none open clears the
  ticked rows, and hands focus back to the list.
- **Acting keys fire once per press.** `e` marks done and advances, Shift+E
  marks done with a label, `l` labels and keeps the thread, `s` sends it to
  Later, `r` opens the quick reply, `m` drops the sender and `x` ticks the row.
  These set `includeRepeats: false`, so a held key acts once rather than
  clearing rows the reader never looked at.

**One act at a time.** `_triageAndAdvance` works out where the reader lands
before the list moves, runs the act, then lands them. The `_triaging` latch
holds while it runs, and a key or button pressed mid-act is DROPPED: its
surface is still on screen, so the reader sees where the first act landed and
presses again. Three callers whose surface has already gone QUEUE instead
(`queue: true`, waiting on `_triageIdle`): the picker's apply when it marks
done after labelling, its mark-done-without-label way out, and a sent reply's
mark-done. A queued act reads its target and landing after the wait. If the
reader moved to another thread while an act's write was out, that choice
stands and the landing is skipped.

**Where a thread stood.** `_lastPileIds` is the pile as last read while the
open thread was in it, or while nothing was open. A thread that leaves the
pile while open, such as a sent reply that flips it to waiting, still walks
with `j` / `k` from where it stood and lands on the nearest row still drawn
(below it, else above). A thread that was never in the pile, opened from
Archive, Home or a room, goes nowhere on `j`. `_resetPileProgress` clears the
memory whenever the pile on screen changes: the rail moving, a tab pick, the
label lens.

**Bulk keys need the overview on screen.** With rows ticked, `e`, Shift+E,
`l`, `s` and `m` act on the selection only while `_selectionActive`: something
ticked is drawn AND `_highlightedSection` is Needs You AND the overview is
actually drawn (`_overviewCovered` is false). A thread open BESIDE the
overview, with room for both, hides nothing, so the selection stays live
there. Two things hide the ticks. A thread opened in the main pane, Settings,
the composer or the activity log takes the main pane. And a side panel can
take the whole pane: in a window under 1293px, below the two-pane split, at
the narrow width, or as a file opened full-pane. Then the keys act on the
open thread, and `x` ticks nothing, since a tick the reader cannot see is one
the next `e` would act on behind their back. The ticks survive either way, so
the reader can open a thread, look, and come back to the selection. `j`, `k`
and `r` are always about one row.

**A failed act says so and moves nobody.** A Mark done whose write fails,
from `e`, the button or the row, says "Couldn't mark that thread done just
now." with no Undo. `_triageAndAdvance` reads the act's false: the bar is not
counted in the progress line, and the reader stays on the thread. With
Shift+E, a state that saves while the label does not is still done, and the
bar says "Marked done. Couldn't add X just now." with an Undo that reopens
the thread; a failed state write says the Mark done sentence. A bulk Shift+E
whose label fails on some rows marks them done anyway and says "Marked done:
N threads. Couldn't add X to M." The list's own banner has two more:
"Marked done, but the label didn't save." when the label fails during Mark
done, and "The thread is back, but the label is still on it." when the label
fails to come off during Undo, which still brings the thread back.

**A ✕ that removes nothing says nothing.** A second press on a label chip's
✕, landing while the first removal's reload is still out, removed nothing and
raises no bar. So the first press's bar keeps its Undo, and `z` still puts the
label back.

**Find escalates only what Home can read.** Enter in Find on a needle nothing
on the rail answers normally escalates to a Home search. A needle carrying a
facet Home's grammar does not know (`label:`, `-label:`, `is:done`,
`is:external`) stays put instead, because Home would hunt for the literal
"is:done"; the rail's own empty state says nothing matched. `from:` and `has:`
still escalate, because Home's search grammar honours both.

## The Why panel

The Why panel (`lib/widgets/why_panel.dart`, `WhyPanelBody`) is the
explanation beside a message, and the needs-you probability and its reason are
the first thing on it.

**What it reads.** Five blocks, in this order.

| Block | Source |
|---|---|
| Verdict | `Message.needsYouP` / `needsYouReason`, parsed in `Message.fromRow`; `gateReason` when the gate took the message (in `homeDropLabels`' words, lower-cased, when it has one); and, when `message_decisions` has a row, one line "Decision model: gate keep 0.94, needs you 0.71, action 0.66, reply 0.12 · 58 ms" (`WhyPanelBody.decisionLine`). The gate is worded by the verdict: "gate drop 0.91" on a dropped message, "gate keep (drop 0.60)" on a kept one the head leaned against |
| Triage | the message's `triageStatus`, `summary`, `urgency`, `category`, `label` |
| Asks | `needsAction`, `replyExpected`, `deadline`, `addressedMe`, `actionItems` |
| Attention | the thread's `attentionScore` on its own (it orders Needs You and gates nothing), then `conversation_ai`'s `bucket`, `bucket_reason` and `snoozed_until` |
| What it is about | `MessageStore.extractionFor(source, messageId)` — `getExtraction` decoded through `ExtractionResult.fromJson`, and null on a blob that will not parse |

The facts come from `whyFactsProvider` (`lib/providers/why_provider.dart`), a
`FutureProvider.autoDispose.family` keyed by the record
`({source, conversationKey, messageId})`. Deliberately not a slice of the open
thread: the panel has to work for a message whose transcript is not the one
loaded — opened from a side thread, from a room — and a provider that depended
on the thread provider would show an empty panel exactly then.

**The number the slider is set in.** The headline is `Needs you: 72%`, the
message's `needs_you_p` as a floored whole percentage, which is the unit the
Settings slider states its threshold in, so the two read as one number. Under
it come the reason sentence and one line against the reader's own slider: "In
Needs You: at or above your 35% line." or "Not in Needs You: below your 35%
line." NULL reads `Needs you: —` with "The needs-you pass has not reached this
message." An undecided message is never shown as 0%. Message history says the
same in its own words ("Needs you: 72% — <reason>", or "Needs you: not
decided"). The rail's reason chip and the thread header's `Why:` line append
the THREAD's probability (`Conversation.needsYouP`): `Asks you a question. · 72%`
and `Why: Asks you a question. · 72% · <when>`. All of them spell the number
through `needsYouPercentWords` (`app/lib/widgets/needs_you_reason.dart`).

**How it opens.** Two gestures, both in `ThreadDetailPanel`. Hovering an
inbound transcript row gives a third button on the strip, **Why**
(`HoverActions.whyKeyFor(messageId)`), beside Reply and Suggest. And the CTA
banner above the transcript now opens Why on the **newest inbound** message
rather than focusing the composer — the box is docked and always visible, so
"put the cursor in it" was a click nobody needed help with, while "where did
this ask come from" had no answer anywhere. With no Why wired, or on a thread
with nothing inbound in it, the banner falls back to focusing the composer as
it always did. Every per-message ask line still focuses the box.

**The owner's answer.** When the message's stored decision carries the
owner's answer (`StoredDecision.ownerAnswer`), the headline is theirs, with
no percentage: **"Needs you: no — you removed it"** or **"Needs you: yes — you
added it"** — the 0.0 or 1.0 under it is the owner's word, not a model's
confidence. The stored reason ("You removed a message like this from Needs
You.") is shown on EITHER side of the line, since it says what the owner did,
and the line against the slider follows as usual. The rail's chip and the
thread's `Why:` line, which have only the thread's stored reason, tell the
owner's four sentences from a model's by `ownerNeedsYouReasons`
(`decision_policy.dart`, where `ownerNeedsYouReason` spells them once): the
chip reads **You removed it** / **You added it** and neither draws a
percentage.

**What it never does.** It takes no answer: the owner's Needs You answer is
SHOWN here, and taken on the thread's action bar (the two buttons above),
never in this panel. It feeds nothing back. This reads model OUTPUT that has
already been through the untrusted-data fence upstream; it writes nothing,
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
same rows (`needs_you_p`, `needs_you_reason`, the extraction, the
attention row) through their own reads, by decision: `whyFactsProvider` is
four store calls (the fourth is `decisionFor`) and `messageHistoryProvider`
is nine (over eight tables), and the smaller one is what makes Why cheap
enough to open from a hover.
