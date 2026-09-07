# 9 · Notification settle

**What happens.** Every message *settles* — notified or suppressed — exactly
once, within six minutes of arrival. `NotificationCoordinator`
(`app/lib/services/notification_coordinator.dart`) waits for the triage,
needs-you, extraction, and storyline verdicts, then emits at most one
`MessageSettled` per message (the `message_notify` state machine, schema v6,
PR #9).

**No model call.** Worthiness is computed from stored verdicts: a
message-level ask AND thread-level volume. `needs_you_verdict = 1` is one of
the asks — the only one decided about the whole message rather than read off a
triage field — and it is the ask half **only**: a judged yes is still gated by
the attention threshold, the `later` bucket and the `done` state, like every
other ask. NULL and 0 add nothing.

**Waiting for the verdict — from the record, not the queue.** `_isComplete`
reads `message_progress.extract_state` and `storyline_state` (terminal =
`done`/`skipped`/`error`) plus a `needs_you_judged` flag that
`openNotifyCandidates` projects as "a verdict is written, or a `needs_you` work
row reached `done`/`error`". The work-row EXISTS flags this replaced were the
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
writing a verdict, and waiting past that would be waiting on nobody. A verdict
left *stale* by a re-judge also reads as judged, so a candidate can settle on
the old answer; `PipelineProgress.refreshNeedsYou` moves the chip when the new
one lands (see [11-needs-you.md](11-needs-you.md)).

`MessageStore.writeStorylineProgress` is guarded `(settle_state <> 'done' OR
storyline_state = 'pending')` so a stage that was still **owed** at settle time
finishes normally; only a stage already terminal when the row settled is frozen
as history. `MessageStore.reviveOwedStorylineStages`, called by both syncs,
hands the rows the old rule stranded back to the queue.

`needs_you` also joins the debounce's wake set, so a drain that finishes
verdicts sweeps in 750 ms rather than waiting out the 30-second timer.

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
coordinator ever saw — the settle sweep's backstop and the v8 backfill. Both
read the verdict, and `test/needs_you_settle_test.dart` pins that they agree.
The one documented divergence stays: only the SQL carries `is_read = 0`,
because the decision table suppresses a read message before worthiness is
asked. The **v8 backfill is the exception** — it interpolates the SQL with
`verdict: false`, frozen at the shape it ran with, because `from7To8` replays
on v1..v7 databases where `needs_you_verdict` (v10) does not exist yet.
