# 9 · Notification settle

**What happens.** Every message *settles* — notified or suppressed — exactly
once, within six minutes of arrival. `NotificationCoordinator`
(`app/lib/services/notification_coordinator.dart`) waits for the triage
(decision model), needs-you, message-text (`extract` kind) and storyline
verdicts, then emits at most one `MessageSettled` per message (the
`message_notify` state machine, schema v6, PR #9).

**The toast body and the text stage (decision-model round, Phase 6).** The
settle waits on the text stage exactly as it waited on extraction: the text
is the `extract` kind's work, so `extract_state` is still the stage
`_isComplete` holds for — no longer and no shorter. What changed is where the
summary comes from: triage writes the row from the decision model with no
text, and the message-text stage writes `summary` later. So a COMPLETE settle
always has the summary, while a DEADLINE settle may fire before the text
lands (a slow or parked text server). `NotificationCoordinator.toastSummary`
puts the summary on the event when it is present and the message's own
`body_preview` otherwise (both candidate projections select `body_preview`);
the desktop toast's body stays `ctaText ?? summary` — and for a MEETING
message that CTA never ends in "— by <time>": a meeting message's time is the
event's, never the reader's deadline (the clean-up round, 2026-10-04;
[14-calendar.md](14-calendar.md), Deadlines). The thread's CTA is
quoted, and counted as an ask, only by a message that OWNS it: `ownsCta`
requires the message triaged AND its summary present, because until the text
lands the CTA on the thread is an older message's. The text write stamps
`messages.updated_at` (the word index needs it), and the handler's card
refresh right after it re-stamps `conversation_ai`, so the freshness check
below is met as it was when triage stamped the row.

**No model call.** Worthiness is ONE predicate over stored rows, and the toast
rule is exactly it: `notifyWorthy` (`app/lib/services/notify_worthy.dart`) is
true when the message's `needs_you_p` is at or above the owner's Needs You
slider (`needsYouAt`), AND its thread is not `done`, AND its thread is not
bucketed `later`. Nothing else asks: not triage's `reply_expected` or action
item, not an urgency word, not a deadline, not the thread's CTA, and the
attention score, which orders Needs You, gates nothing (see
[11-needs-you.md](11-needs-you.md)). A NULL probability is a message not
decided yet, which needs nobody. A message settled before it is decided is
corrected by `refreshNeedsYou` when the probability lands.

**Waiting for the probability — from the record, not the queue.**
`_isComplete` reads `message_progress.extract_state` and `storyline_state`
(terminal = `done`/`skipped`/`error`) plus a `needs_you_judged` flag that
`openNotifyCandidates` projects as "`needs_you_p` is written, or a `needs_you`
work row reached `done`/`error`". The work-row EXISTS flags this replaced were the
wrong answer: extract, needs-you and embed rows are enqueued *after both
drains* of a sync while triage claims `messages.triage_status` the instant a
page commits, and a sweep can land at any instant of a sync. In that gap a
freshly triaged message had no work rows at all, read as finished, and settled
— and the storyline stamp that arrived a minute later was refused, freezing the
row at `storyline_state = 'pending'`, `outcome = 'pending'` for good.

The flip has a price and it is paid on purpose: an **absent or pending stage
now reads as open**, so a message past the 150-per-pass backlog cap settles on
the six-minute deadline rather than immediately. A re-drain is not news. The
second arm of `needs_you_judged` is not redundant either — the handler ends an
item `done` on each of its own guards (deleted, outbound, gated) without
writing a probability, and waiting past that would be waiting on nobody. A
probability left *stale* by a re-decision also reads as judged, so a candidate
can settle on the old answer; `PipelineProgress.refreshNeedsYou` moves the chip
when the new one crosses the slider (see [11-needs-you.md](11-needs-you.md)).

`MessageStore.writeStorylineProgress` is guarded `(settle_state <> 'done' OR
storyline_state = 'pending')` so a stage that was still **owed** at settle time
finishes normally; only a stage already terminal when the row settled is frozen
as history. `MessageStore.reviveOwedStorylineStages`, called by both syncs,
hands the rows the old rule stranded back to the queue.

`needs_you` also joins the debounce's wake set, so a drain that settles
probabilities sweeps in 750 ms rather than waiting out the 30-second timer.

The sweep re-reads the row it is about to settle, so a probability that landed
between the candidate capture and the settle is the one the snapshot takes.

**Waiting on a score.** A deadline settle with no `attention_score` would score
zero and never be revisited, so a scoreless candidate is held for one more
deadline's grace before it settles on what it has. The score is stamped by the
list load's attention sweep, which runs every minute the app is open.

**Stamps.** `_isComplete` also holds a row open while `ai_updated_at` sorts
before `message_updated_at` — a score older than the message is a verdict
about an older version of it. Those are compared as **strings**, which only
works when every stamp has the same width: Dart's `toIso8601String` prints
three fractional digits when the microseconds happen to be zero and six
otherwise, and `Z` sorts after any digit, so a stamp on the millisecond used
to sort *after* one a few hundred microseconds later and the row never
settled. Every stamp the store writes now goes through `MessageStore.isoStamp`
(UTC, six fractional digits, padded), and the coordinator's deadline and
stale-claim cutoffs use the same helper. Six digits and not three, because
two writes in the same millisecond still have to say which came second.

**Timing.** Six-minute settle deadline, 30-second sweep, 750 ms event
debounce. The header comment in `notification_coordinator.dart` documents the
settle budget and — importantly — why `deadline` and `read` are *not* drop
reasons.

**Surfaces.** A settled-and-worthy message announces itself per the three-way
Off / In-app / Native setting: the in-app ribbon (with burst coalescing and
navigation to the right thread) or a macOS/Windows OS toast. While the model
is still working, the row shows a per-row "thinking…" indicator; the home
screen's fifth stage-bar segment ("settle") renders this stage per row.

**Progress plumbing.** Stage transitions across the whole pipeline are
recorded by `pipeline_progress.dart` and broadcast on `progress_bus.dart`
(writes tick the bus; bursts coalesce into one batch read). The header comment
in `pipeline_progress.dart` states the store/stream separation rule.

**The tile and the toast are one predicate.** `notifyWorthy` (Dart) decides the
toast and stores the `needs_you` that goes with it; `needsYouSql`
(`app/lib/data/progress_sql.dart`) writes the same column for the rows no
coordinator ever saw, the settle sweep's backstop. Both are the predicate
(`needsYouAtSql('m.needs_you_p', threshold)` in the SQL) plus not `done` and not
`later`, and `test/needs_you_settle_test.dart` pins that they agree. The
documented divergence stays: only the SQL carries `is_read = 0`, because the
decision table suppresses a read message before worthiness is asked. The **v8
backfill is the exception**: `from7To8` interpolates `needsYouSqlV8Frozen`, the
text it ran with, byte for byte (`progress_sql_test` pins it), because it
replays on v1..v7 databases where neither needs-you column exists yet.
