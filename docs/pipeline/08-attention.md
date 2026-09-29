# 8 · Attention rescore

**What happens.** `AttentionService.recomputeAll`
(`app/lib/services/attention_service.dart`) scores every open thread for the
Needs You rail: thread state, recency of movement, what the model found in it
(triage/extraction verdicts), and how often that sender gets answered. The
score ORDERS Needs You and the rail and never gates either: whether a thread is
on Needs You at all is the decision model's needs-you probability against the
owner's Settings slider (see [11-needs-you.md](11-needs-you.md)). Threads
awaiting the user's reply rank first; threads waiting on somebody else follow,
dimmed.

**Where the verdicts come from.** Since schema v20 the classification the
score reads is the DECISION MODEL's: `urgency` (and the thread's
`cta_urgency`), `needs_action` and `reply_expected` are written by the triage
pass from the decision heads (the booleans at p(yes) ≥ 0.50), extraction's
`intent` and `importance` — which `bucketFor` and the quiet-FYI temper read —
are the heads' choices, and `needs_you_p` is its needs-you probability (see
[11-needs-you.md](11-needs-you.md)). The columns did not
move, so every reader below moved with them (see
[03-triage.md](03-triage.md)).

**No model call.** Pure arithmetic over stored rows — which is why it can be
awaited synchronously right before the list renders (called from
`conversations_provider.dart`).

**Clearing rules.** `needs_you` clears on the user's own exits — a reply from
anywhere, or marking done — never on merely reading (PR #10). Attention v2
(PR #8) added quiet-hours tempering and a direct-address boost.

**Needs you as an input.** `attentionScore` takes `needsYou`: whether the
newest inbound message needs the owner, which the caller
(`AttentionService`) computes with the one predicate, `needsYouAt(needs_you_p,
threshold)` at the owner's slider, off the same `latestInboundMeta` row as
triage's judgments. It moves the score in exactly two places: a yes breaks the
quiet-FYI temper (the thread scores from the needs-reply base and keeps its
reply-rate nudge rather than dropping to the waiting base) and earns the direct
boost on its own, without `addressed_me`. A no moves **nothing**: a message not
decided yet and one below the slider both score exactly as a message with no
needs-you input. The score only orders, so this changes where a thread sits in
the pile, never whether it is in it.

**The one bypass is Later.** An open ask on the thread vetoes the automatic
low-value filing in `bucketFor`, between the sender rules and the quiet-FYI
rule, so a thread nobody has answered cannot be quietly deferred.
`MessageStore.openAskThreads` is where "open ask" is spelled: a kept inbound
message over the slider (`needsYouAtSql('m.needs_you_p', ?)`) received after
the thread's last outbound message. The sweep reads it once per pass, not once
per thread. A person's standing rule still wins over it. The veto has no time
bound, on purpose: an unanswered ask holds its thread out of automatic Later
for as long as it stays unanswered, and the only exits are a reply, Done, or
the owner's own Later.

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

**Three dispositions, two behaviours here.** `sender_prefs.disposition` is
`keep`, `later` or `drop`, and this file knows only two of those apart: `drop`
scores, buckets and sweeps exactly as `later` does, because dropping a sender
quiets the threads already here the same way deferring them would. What the
third one adds is a gate at triage, which is chapter 2's business and not this
one's — `attentionScore`, `bucketFor`, `bucketReasonFor` and `_sweepBucket` all
read the two together.

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

**Plan-relative words are not deadlines.** `isPlanRelativeDeadline` (same
file) matches wording that counts from a start nobody named: a counter word
with a small number ("Day 1", "sprint 2", "week 3", "phase two") or `T+5`. The
number is required, so "day after tomorrow" and "week of May 5" still count as
dates. `showableDeadline` is the deadline worth putting on screen: null for
plan-relative wording, unless the phrase also carries a date `parseDeadline`
can read ("Day 1 (2026-10-05)"), and everything else exactly as stored.
`messages.deadline` keeps the sender's words either way. Its readers are the
triage CTA suffix, which is why a "— by Day 1" banner is never written
([03-triage.md](03-triage.md)); the quiet-FYI temper in `attentionScore`,
where a plan-relative phrase does not stop a thread reading as quiet; the
message-row chip, the Why panel and the Needs You deadlines lens; and
`notifyWorthy`'s deadline ask
([09-notifications.md](09-notifications.md)). The `plan_relative_banner_strip`
one-shot (`stripPlanRelativeBanners`) takes a trailing "— by …" that
`showableDeadline` refuses off the stored `cta_text` written before the fix.

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
sweep that follows sees the `'user'` reason and leaves the row alone. It
returns the `(source, conversation_key)` pairs it moved rather than a count,
because the caller has one more thing to do with them.

**The chips come back with the thread.** `message_progress.needs_you` is a
snapshot taken at settle, and a message that settles while its thread sits in
Later takes a 0 on the strength of the bucket alone — `notifyWorthy`'s Later
clause. Afterwards the snapshot follows the *probability* only (see
[11-needs-you.md](11-needs-you.md)), and lifting a bucket moves no
probability. So both ways out of Later for one thread — a date
that arrived, and Keep in inbox — run
`PipelineProgress.raiseNeedsYouForThread`, which is the one-shot backfill's
own raise-only statement scoped to that thread, under the same guards (the
thread's `done`, its last reply, the owner's slider), ticking each row it
raises. Without it a message over the slider came back to the inbox with no
chip, for good. A sender rule lifting (`restoreSenderPref`) does not yet do this —
recorded as a follow-up.

The opposite repair ran once too. The `needs_you_flag_veto_p` one-shot
(`PipelineProgress.lowerVetoedNeedsYou`) clears the settled chips
`notifyWorthy` would not grant today (a message below the owner's slider or
not decided, or a thread done or in Later), ticking each row so the live screen re-reads it
(see [11-needs-you.md](11-needs-you.md)).
