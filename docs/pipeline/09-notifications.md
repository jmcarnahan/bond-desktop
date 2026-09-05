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

**Waiting for the verdict.** `openNotifyCandidates` projects a `needs_you_open`
flag beside `extract_open`, keyed by message, and `_isComplete` holds the row
open while a `needs_you` work item is `pending` or `processing` — settling
first would judge the message on an answer that had not arrived. An **absent**
work row is terminal, as everywhere else in this stage: the gated and
beyond-cap rows are never queued for the pass at all. `needs_you` also joins
the debounce's wake set, so a drain that finishes verdicts sweeps in 750 ms
rather than waiting out the 30-second timer.

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
