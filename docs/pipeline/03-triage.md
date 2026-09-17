# 3 · Triage

**What happens.** The first model read of a message. `TriageQueue`
(`app/lib/services/triage_queue.dart`) claims ungated messages newest-first,
loads the prior messages on the conversation (cut off at this message's
`received_at` so the model never sees the future), runs `TriageTask`, and
folds the result into `triage_status`, the conversation's CTA rollup, and an
activity row. A claim that ends in a gate skip instead refolds the thread down
through `refoldThreadState` before it emits, because the state machine folded
`needs_reply` on at ingest and the gate is only speaking now — see
[02-gates.md](02-gates.md).

**The model call.**

| | |
|---|---|
| Task | `TriageTask` — `app/lib/services/llm/triage_task.dart` |
| Prompt | `_triageRules` at the top of that file, composed with the shared untrusted-data fence (`prompt_guard.dart`) |
| Schema | `triage` — flat; **key order is load-bearing** (the doc comment above the schema explains why) |
| Output | urgency, category, 2–4 word label, one- or two-sentence summary, `needs_action`, action items, `addressed_me`, `reply_expected`, `deadline` |
| Slot | **fast / bulk** (`fastLlmClientProvider`, wired in `app_providers.dart`) |
| Params | temperature 0.2, maxTokens 512 (the `json_task.dart` defaults) |
| Concurrency | 3 in-flight requests |

**What the prompt instructs.** Classify one inbound message (mail or chat)
plus its recent thread into the fixed urgency/category taxonomy, then write
the label, summary, and reader-facing action items. It explicitly forbids
obeying instructions inside the message: new payment directions or "reply to
confirm" demands are named as fraud red flags whose only correct action item
is independent verification. `reply_expected` and `deadline` are judged last,
after the summary is written. The doc comment above the prompt records why it
is shaped this way — read it before editing the prompt.

**The summary rule (2026-09-16).** The summary must carry the specifics: the
concrete thing the message is about, what it asks of the reader or that it
asks nothing, and the date, amount, place or name the matter turns on. Only
what the message states — a guessed date or figure is forbidden — and never a
restatement of the label or the category. The rule reads that way because the
golden set said the failure was omission rather than invention: 46–60 of 76
kept items had a summary that left out a fact the item turned on, the
forbidden-fact traps fired on 0–4, and summaries ran 113–129 characters
against a 500-character cap — on every model tried, which makes it a prompt
problem and not a model one. Measured, the rule moved the judged summary from
39% to 63% of kept golden items on the same judge (the second of two passes),
with the forbidden-fact traps at 4 items against 3. The summary is clamped at
500 characters with a hard cut, and 1 of the 76 golden summaries reached it
under the new rule; a summary that reaches the clamp is cut mid-word, which is
why the rule asks for one or two sentences and not more. The rule also made
the model more conservative about action items — 67% to 60% on the rubric, and
51 to 45 kept items carrying any — recorded as a trade in the ledger. The rows
are in the bakeoff ledger (`docs/model-bakeoff.md`, "Golden ledger").

**The tail and the digest, measured (2026-09-16/17).** What triage reads is
unchanged: the newest three messages before this one, each cut to 300
characters, in the `thread` fence. What the prompt gained is an optional
`TriageInput.threadDigest`. When a caller passes one it is rendered as its own
`thread_digest` fence between the attachment line and the thread fence, under
the line "A digest of the thread before those messages, oldest first, for
context:", capped at 900 characters by `fitThreadDigest` — whole lines dropped
from the OLD end, the header line kept. Nothing in the app builds a digest, so
the shipped prompt never carries that fence; `TriageQueue` passes the tail and
nothing else, pinned by `triage sends the thread tail and never a digest` in
`app/test/triage_queue_test.dart`. The ladder that decided it ran three rungs
on the 4B at `GOLDEN_K=4` under this document's prompt, two passes each,
keep-only (76 items): `none` read needs_action 70% / reply_expected 70% then
70% / 68%; `tail3` read 72% / 75% then 71% / 72%, against a record row of 71%
/ 72%; `digest` read 67% / 70% then 70% / 74%. The rule was pre-registered:
the message alone had to beat the tail by 4 points on a boolean before triage
would drop the tail, and only then would the digest be tried against it. It
did not, on either boolean on either pass, so triage keeps the tail and the
digest branch was never reached. What the digest DID move is worth recording
for the next round: the judged fields rose — label 82% to 89%, summary 64% to
68%, action items 56% to 62% against the tail's 86% / 63% / 60% — and
`reply_expected` on the 21 keep items whose gold label needs the thread went
10 to 13 of 21, while needs-you evidence fell 34% to 30%, extraction lost
people and project, and triage's p50 rose 27% at K=4 (throughput 13.4 to 11.9
messages a minute). The judge's noise floor is 2 points on a judged field. A
triage-only digest judged on summary and label is the natural next
experiment, and the field is in place for it. Round 0's finding that the
message alone beat the tail by 12 and 8 did not survive the summary rule:
under this prompt `none` reads 70% / 70% where round 0 read 78% / 78% on the
old one. A context result is valid only for the prompt it was measured with.
The run files are
`golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260916-233417.json`
(none), `…-20260916-235139.json` (digest) and `…-20260917-000817.json`
(tail3).

**The Attachments line.** When the message carries non-inline attachments,
the user message gains one line after the directness line and OUTSIDE every
fence: `Attachments: ` followed by the names and sizes. Names and sizes only —
no contents, no download, zero added latency. The sentence is the app's own
statement, like the directness line, so it sits outside; the FILE NAMES are as
attacker-controlled as a body, so they ride inside an `attachment_names`
fence on the same logical line. At most five names, clamped to 120 characters,
and a size of 0 (unknown, which is every chat attachment) is left unsaid
rather than printed as `(0 B)`.

The line is present when it can be. `_triageClaimed` calls `ensureBody` inside
the claim, and that is `_fetchDetailInto`, so a mail attachment is on the row
by the time the prompt is built; chat rows are written at ingest. A failed
detail fetch costs the line and never the triage.

**Failure behavior.** The queue's header comment in `triage_queue.dart`
documents the degrade-vs-park policy and the concurrency economics. An
unreachable fast server parks the queue; the backlog resumes when the server
comes up, with the `Triaging N remaining…` counter in the rail.

**The headerless defer.** A degraded detail fetch that leaves no headers at
all, on a machine-shaped sender, is the one case where classifying from the
preview throws away the verdict that mattered — the header gates would have
caught exactly that mail. Such a message is written back to `pending` with an
attempt spent and a `triage` / `retry` row (`reason: headerless`), and the
drain excludes it from its own later claims so it carries on with the next
message rather than spinning on this one. Bounded by `_maxAttempts`, shared
with the model failures, after which it classifies headerless as before. See
02-gates.md.

**Shared prompt across sources.** Mail and Teams run the *same* system prompt
per task, pinned by parity tests (PR #8) — a change to the triage prompt is a
change for both connectors.

**The model's `notification` verdict as a gate — measured 2026-09-16, not
shipped.** The golden set was joined against five 4B bulk run files (counts
only): triage's `category = notification` fires on 0 of 24 gold-drop items in
every run and on 1 of 76 gold-keep items (the same item every time, outside
the `gate-keep-trap` stratum; the trap's 12 items are clean). The stricter
rule (`notification` and `needs_action = false` and no `reply_expected`) gives
the identical 0 / 1; the 4B calls 23 of the 24 drops `work`. The gate would
catch nothing and lose one keep, so there is no `notification` gate reason and
no code path. The offline gate replay (`make golden-gate
GOLDEN_RUN=<bulk run file>`) reports the proxy on every run, so a prompt
change can be re-read against it.
