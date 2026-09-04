# 11 · Needs-you verdict

**Model judgment and every reader of this verdict land in later phases of this
round.** As of this phase the stage stores a verdict and computes only the
deterministic floor; nothing in the app reads `needs_you_verdict` yet.

**What happens.** `NeedsYouHandler`
(`app/lib/services/needs_you_handler.dart`, run by `AiWorker`) answers one
question about one message — does this want the owner? — and writes the answer
onto the message's own row. It runs after triage and **before** extraction, so
the verdict is on the row by the time anything downstream asks about it.

**No model call, yet.** The only judgement this phase makes is
`needsYouFloor(row)` in `app/lib/services/needs_you.dart`: an inbound Teams
message with `addressed_me = 1`. Teams ingest (`teams_sync.dart`'s
`messageRow`) sets that bit for a 1:1 chat *or* an @mention, so for chat the
one bit is the whole floor. Mail's `addressed_me` — sole To: recipient — is
deliberately outside it: being the only address on an envelope is a hint, not
a verdict, and those rows are what the model branch will read.

The floor can only **raise** the verdict. A message it says nothing about is
left NULL rather than written down as a no.

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

**Queueing.** `MessageStore.enqueueNeedsYouBacklog` is
`enqueueExtractBacklog`'s twin — same filter, same caps, same `OR IGNORE`
idempotence, one shared private statement — and both syncs call the two side
by side (`sync_service.dart`, `teams_sync.dart`, counted as `queued_needs_you`
on the sync activity row). The symmetry is the guarantee that the verdict set
covers exactly the rows extraction will read.

**Handler position and failure behavior.** First in the `aiWorkerProvider`
handler list, ahead of extraction; `concurrency` 3, since an item touches only
its own row. It early-returns *done* on the shapes the queue can hand over
stale — deleted, outbound, gated (with the `teams_source` tolerance every
post-triage stage keeps) — and records the reason on its activity row.

It has **no arm** in `AiWorker`'s `_park` / `_recordFailure` per-kind ladders,
deliberately. Those ladders exist to re-note a `message_progress` stage state
when the worker rather than the handler decides how an exception ended;
needs-you has no stage column, so an arm there would write nothing.
