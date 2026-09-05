# 9 · Notification settle

**What happens.** Every message *settles* — notified or suppressed — exactly
once, within six minutes of arrival. `NotificationCoordinator`
(`app/lib/services/notification_coordinator.dart`) waits for the triage,
extraction, and storyline verdicts, then emits at most one `MessageSettled`
per message (the `message_notify` state machine, schema v6, PR #9).

**No model call.** Worthiness is computed from stored verdicts: a
message-level ask AND thread-level volume.

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
