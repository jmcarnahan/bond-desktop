# 8 · Attention rescore

**What happens.** `AttentionService.recomputeAll`
(`app/lib/services/attention_service.dart`) scores every open thread for the
Needs You rail: thread state, recency of movement, what the model found in it
(triage/extraction verdicts), and how often that sender gets answered. A
Settings slider sets the score threshold for appearing. Threads awaiting the
user's reply rank first; threads waiting on somebody else follow, dimmed.

**No model call.** Pure arithmetic over stored rows — which is why it can be
awaited synchronously right before the list renders (called from
`conversations_provider.dart`).

**Clearing rules.** `needs_you` clears on the user's own exits — a reply from
anywhere, or marking done — never on merely reading (PR #10). Attention v2
(PR #8) added quiet-hours tempering and a direct-address boost.

**The needs-you verdict as an input.** `attentionScore` takes the newest
inbound message's `needs_you_verdict` (see [11-needs-you.md](11-needs-you.md)),
carried to it on the same `latestInboundMeta` row as triage's judgments. It
moves the score in exactly two places: a judged **yes** breaks the quiet-FYI
temper — the thread scores from the needs-reply base and keeps its reply-rate
nudge rather than dropping to the waiting base — and earns the direct boost on
its own, without `addressed_me`. Together those are what lift a 1:1 Teams FYI
the stage read as a real ask over the default threshold.

The two fences are asymmetric on purpose: `!= true` on the temper, `== true` on
the boost, so NULL (never judged) and 0 (judged no) move **nothing** and score
exactly as they did before the stage existed. And the verdict deliberately does
not touch the **threshold** — it raises the score through the same arithmetic
every other signal uses, and the user's slider still gates what reaches the
rail. The one thing it does bypass is **Later**: an open ask on the thread
vetoes the automatic low-value filing in `bucketFor`, between the sender rules
and the quiet-FYI rule, so a thread nobody has answered cannot be quietly
deferred. `MessageStore.openAskThreads` is where "open ask" is spelled — any
inbound message with `needs_you_verdict = 1` received after the thread's last
outbound message — and the sweep reads it once per pass, not once per thread.
A person's standing rule still wins over it, and the threshold is untouched.
The veto has no time bound, on purpose: an unanswered ask holds its thread out
of automatic Later for as long as it stays unanswered, and the only exits are a
reply, Done, or the owner's own Later.

**Known documentation gap.** The code documents ownership rules well, but the
scoring formula itself is under-commented — `recomputeAll` is the place to
add prose if the formula changes. Also a recorded residual from PR #9:
`latestInboundMeta` and attention still key on bare conversation keys rather
than `(source, conversationKey)`.

## Snooze and resurface

`conversation_ai.snoozed_until` — a column that existed with no reader and no
writer since the migration that added it — is now what Later's "when" is stored
in. UTC ISO in `MessageStore.isoStamp`'s exact six-digit shape, because every
comparison against it is lexicographic over that one form.

**Only per-thread deferrals carry a date.** `sendThreadToLater(source, key,
{until})` writes one; `keepThreadInInbox` clears it; `sendSenderToLater`,
`rebucketSender` and `restoreSenderPref` write none at all. A standing rule
about a sender has no "when" in it, and handing its threads back one at a time
would quietly exempt them from the rule the user had just made. A thread a
sender rule swept up that the reader then gives a date to is therefore
**promoted** to a deferral of its own, which is what naming a day for one
thread means.

**The default is the sender's own words.** `snoozeUntilFor` (in
`lib/services/deadline_parse.dart`) reads the thread's `latest_deadline` — the
newest inbound message's `deadline`, in the language triage stored it in — and
returns that day at 09:00 local. Seven days when there is no deadline, when it
does not parse, and when the day it names is **not after today**: a deadline
already past would hand the thread straight back on the next list load, which
is a Later button that visibly does nothing. Nine in the morning rather than
midnight, so a resurfaced thread arrives on the day it names instead of
overnight.

`parseDeadline` is pure and takes `now`, so every answer is testable and the
anchor is the reader's local day. It reads ISO dates, `Month D` / `D Month` in
either order, `M/D` US order, `today` / `tomorrow` / `day after tomorrow`,
weekday names (the next occurrence strictly after today, so today's own weekday
is a week off), `end of week` / `eow`, `end of month` / `eom`, `next week`, and
`eod` / `tonight`. Anything else is null, which reads upstream as "the message
named no date anyone can act on" rather than as a guess.

**Two pills, and one method behind them.** Each Later digest line gains a
`Back <when>` caption when it has a date (`untilLabel` in `time_format.dart` —
`tomorrow`, `in 3 days`, `in 2 weeks`, then the absolute day) and two quiet
buttons, **Tomorrow** and **Next week**. Both call `snoozePreset` and route
through `sendThreadToLater(…, until:)`, so there is exactly one path that means
"this thread, until then". Two presets and not a picker: these sit on every row
of a list the reader is working down, and no dialogs.

**Resurfacing is the user's own decision.** `MessageStore.resurfaceDue(nowIso)`
sets `bucket = NULL, bucket_reason = 'user', snoozed_until = NULL` on every
`later` row **the user deferred by hand** (`bucket_reason = 'user'`) whose date
has arrived, and returns how many moved. The reason is part of the match: a
thread a sender rule owns is the rule's until the rule goes, and a date it
inherited from an earlier hand-deferral must not hand it back behind the
rule's back — so `rebucketSender` also clears `snoozed_until`, in both
directions. The reason it writes is
`'user'` and not a word of its own **because `_sweepBucket` above re-files any
thread whose reason is not `'user'`** — a `'due'` or a NULL would send a
resurfaced thread straight back to Later on the very next pass, and the date
would look ignored with nothing on screen to say why. A date the user set is
the user's instruction; when it fires, the result is exactly what "keep this
thread in my inbox" writes.

It is called from **one** place: `ConversationsNotifier.load()`, immediately
before `recomputeAll` and so immediately before the read that renders the rows.
Every path that refreshes the list runs `load()` — the sixty-second poll, the
refresh button, every Later action — so one call site covers them all, and the
sweep that follows sees the `'user'` reason and leaves the row alone.
