# 3 · Triage

**What happens.** The first model read of a message — and since the
decision-model round's Phase 6, the ONLY one triage makes. `TriageQueue`
(`app/lib/services/triage_queue.dart`) claims ungated messages newest-first,
loads the prior messages on the conversation (cut off at this message's
`received_at` so the model never sees the future), runs the DECISION PASS,
and writes the row from the decision alone: `triage_status`, the
conversation's urgency/category rollup, and an activity row. No language
model is called here: the message's TEXT (summary, action items, deadline,
topics, project) is the message-text stage's, one generative call behind it
on the fast lane ([04-extraction.md](04-extraction.md)). So the rail and
notify-worthy react to a new message without waiting for a generative call,
and the text fills in when it lands. (Bucket filing is not at triage time: it
is the text handler's `_fileBucket` and the attention sweep. And the triage
pump still shares the fast lane's drain gate, so it can wait behind a text
call already in flight — [10-model-routing.md](10-model-routing.md).) A claim that ends in a gate skip instead
refolds the thread down through `refoldThreadState` before it emits, because
the state machine folded `needs_reply` on at ingest and the gate is only
speaking now — see [02-gates.md](02-gates.md).

**The decision pass (schema v20).** One forward pass of the fine-tuned
decision model (`app/lib/services/decision/`) answers all nine
classification heads from the message's rendered state:
`DecisionInput.fromRows(message, thread, attachments, owner)` →
`DecisionClient.decide`. The answers are stored in `message_decisions` (one
row per message, every option's probability in `answers_json`, the four p's
the pipeline reads lifted into `gate_p`, `needs_you_p`, `needs_action_p`,
`reply_expected_p`; derived, so Clear AI results empties it; `answers_json`
also records `owner_known`, whether the state carried an owner line — the
account is asked without waiting at each pump, so the first claims after
launch may lack it). Then:

- the learned gate may drop the message (see
  [02-gates.md](02-gates.md#the-learned-gate));
- otherwise the row is written ONCE, `triage_status = 'triaged'`, from the
  decision:

| Field | From |
|---|---|
| `urgency`, `category` | the decision heads' choices |
| `needs_action`, `reply_expected` | the decision heads' p(yes) ≥ `DecisionPolicy.booleanYes` / `replyYes` (both 0.50) |
| `summary`, `action_items_json`, `deadline` | NOT written here — the message-text stage writes them (`MessageStore.writeMessageText`); `writeTriage` writes the classification only and never touches them, so they are NULL on a new row and a re-triaged message keeps the text it already had |
| `label` | nothing writes it any more; NULL on every new row (old rows keep theirs, and the Why panel shows it only where present) |
| `needs_you_p`, `needs_you_reason` | the decision's p(needs_you = yes) and its templated reason (`writeNeedsYouP`), only when the decision was made with the owner line; an ownerless decision leaves them NULL for the needs-you pass (see [11-needs-you.md](11-needs-you.md)) |

The activity row carries `urgency`, `category`, `needs_action`,
`reply_expected` (the decision's values) and `decision`: `gate=keep
urgency=<u> category=<c> na=<p> re=<p> ny=<p> (<ms> ms)`; its `llm_*` tally
is the decision call's (`llm_label: decision`). There are no `action_items`
or `deadline` keys any more — those ride on the text stage's `extract` row. A
decision server that is down (or a heads file that is not installed) throws
`DecisionUnavailableException`, which PARKS the drain under
`decision_unavailable` without spending an attempt; an unusable vector is a
format failure that spends one. `decisionClient` is a REQUIRED constructor
argument: there is no triage without the decision model (tests pass a
`FakeDecisionClient` / `ScriptedDecisionClient`).

**The heads file and the question set.** The nine message heads live in
`decide-heads.json` beside the three storyline questions' heads (schema 2,
question set v5): `questions` lists the nine message fields in
`decisionFields` order, renderer `message`, then `same_effort` (`pair`),
`member_of` (`membership`) and `charter_specific` (`charter`), each with its
options, weight, bias and temperature. `DecisionHeads.fromJson` checks all of
it, plus `pooling: mean`, `max_tokens`, 1024-wide weight rows, the renderer
set `bond-state/2` (`decisionRendererVersion`) and the question hash
`f495a7dc48aa34d5` (`decisionQhash` in `decision_questions.dart`). Triage reads
only the nine message fields (`DecisionHeads.apply`). The message state's bytes
did not change from `bond-state/1`; the new version names the whole renderer
set, storyline texts included ([06-storylines.md](06-storylines.md#storyline-questions-bond-state2)).
A schema-1 file, meaning the first decision model's nine-field heads, is
refused under `decision_misconfigured` with its own sentence: the installed
decision model is the older version, so install the new one with `make
decide-install`. **On this branch that is every install:** `DECIDE_SRC` still
names the v2 export, which is schema 1, so the decision pass parks until
the v3 decision model is installed (the v3 install updates `make
decide-install` and its manifest). A stored `message_decisions` row whose `qhash` is not
`decisionQhash` came from another model, so `MessageStore.decisionFor` reads it
as no decision.

**The install-time re-decide.** So a new model does not leave the recent
mailbox undecided, the mail sync starts `TriageQueue.redecideStale` once per
question-set hash (the pref `decision_redecide_qhash` holds the hash it last
finished for). It runs the decision pass again — the same `decisionInputFor`
state and the same writers — for the kept inbound (`triaged`) messages of the
last 30 days whose decision row is under another hash or missing, newest
first, at most 2,000 (`MessageStore.staleDecisionRefs`). It rewrites the
`message_decisions` row, the four triage fields (urgency, category,
needs_action, reply_expected, through the narrow `writeDecidedTriage`),
`needs_you_p` with its sentence, and the intent and importance inside an
extraction that already ran (`rewriteExtractionDecision`, topics and project
untouched), and folds the thread's CTA as the claim does (`foldCtaUp`), so a
quiet thread's urgency and category follow the new decision. It never
touches the text, the gate verdict or `triage_status`, and it never gates.
Started unawaited so new mail's sync is not held behind it; a decision park,
the processing switch, or a run whose skipped (4xx) messages are at least as
many as its re-decided ones ends it incomplete, the pref stays open, and the
next sync resumes, since what was re-decided has left the list. While triage
itself is parked on the decision model it asks nothing, and a re-decide park
is logged once per question set and reason per app run. Not in `derivedOneShotPrefs`: Clear AI results re-triages every message
under the current model anyway. Older rows outside the window still read as
undecided, and the raw SQL readers (the claim order's importance,
`requeueOwnerlessNeedsYou`) read them as they stand.

**The CTA rollup.** `foldCtaUp` (`app/lib/services/conversation_cta.dart`) is
the ONE fold, called twice per message. Triage calls it with the decision's
urgency and category: on a new message (no summary on the row yet) it writes
`cta_urgency` and `category` and LEAVES the thread's current `cta_text` as it
is, because clearing it for the seconds the text call takes would drop the
thread out of Needs You and back. The message-text handler calls it again
when the text lands, and that call writes the ask: the first action item (or
the summary, when the message needs something and names no item), with the
deadline appended as "— by <deadline>" before the 200-character clamp —
cleared when the message asks for nothing. The deadline goes through
`showableDeadline` (`app/lib/services/deadline_parse.dart`) first, because
this WRITES the banner: a plan-relative word such as "Day 1" stamped here
would outlive every display-time filter (see
[08-attention.md](08-attention.md)). Both calls keep the two guards: only the
thread's newest inbound message folds, and never onto a thread the owner has
already answered (ties go to the reply, as `outboundResolves` reads them).
While the text has not landed, the ask left standing is an older message's:
`ownsCta` and `needsYouSql` do not count or quote it for this message (both
require the message's summary), and a text stage that fails for good clears
it ([04-extraction.md](04-extraction.md)).
Tests: `app/test/conversation_cta_test.dart`.

**What the retired `TriageTask` did.** Until Phase 6, triage ran a language
model call (`TriageTask`, schema `triage`) for urgency, category, a 2–4 word
label, the summary, the booleans, action items and the deadline. Phase 5 moved
the classification to the decision model; Phase 6 deleted the call. Its
summary / action-item / deadline rules, its user block (date, directness,
attachments line, digest, thread tail, message) and its caps moved to
`MessageTextTask` unchanged. The measurements below were taken on
`TriageTask` and are kept because the rules they justified are the ones
`MessageTextTask` carries now.

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

**The tail and the digest, measured (2026-09-16/17, on `TriageTask`; the
message-text call reads the same block).** What the text call reads is: the newest three messages before this one, each cut to 300
characters, in the `thread` fence. Link targets come off first
(`stripLinkTargets` from `html_text.dart`, applied in `message_block.dart`'s
`_tailBody` and `buildMessageBlock`), before the
300-character tail cap and before the message block's own body cap, so a
hundred characters of tracking query cannot spend a quoted turn. A Teams
quote-reply adds one line above the body, `↪ replying to <sender>: <preview>`
(`quotedReplyLines`, the preview cut to 200 characters), so the model can see
which turn the reply answers. What the prompt gained is an optional
`MessageTextInput.threadDigest` (then `TriageInput.threadDigest`). When a caller passes one it is rendered as its own
`thread_digest` fence between the attachment line and the thread fence, under
the line "A digest of the thread before those messages, oldest first, for
context:", capped at 900 characters by `fitThreadDigest` — whole lines dropped
from the OLD end, the header line kept. Nothing in the app builds a digest, so
the shipped prompt never carries that fence; the message-text handler passes
the tail and nothing else, pinned by `the text reads the thread tail before
it, and never a digest` in `app/test/extract_handler_test.dart`. The ladder that decided it ran three rungs
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

**The Attachments line** (now `MessageTextTask`'s). When the message carries
non-inline attachments, the user message gains one line after the directness line and OUTSIDE every
fence: `Attachments: ` followed by the names and sizes. Names and sizes only —
no contents, no download, zero added latency. The sentence is the app's own
statement, like the directness line, so it sits outside; the FILE NAMES are as
attacker-controlled as a body, so they ride inside an `attachment_names`
fence on the same logical line. At most five names, clamped to 120 characters,
and a size of 0 (unknown, which is every chat attachment) is left unsaid
rather than printed as `(0 B)`. `_attachmentLine` skips a Teams quote-reply's
`message_reference` row the way it skips an inline one: a quote is no file,
and it already reaches the prompt as the `↪ replying to` line.

The line is present when it can be. `_triageClaimed` calls `ensureBody` inside
the claim, and that is `_fetchDetailInto`, so a mail attachment is on the row
before triage writes its verdict — and the text call, which only runs after
triage has spoken, reads the rows then; chat rows are written at ingest. A
failed detail fetch costs the line and never the triage.

**Failure behavior.** The queue's header comment in `triage_queue.dart`
documents the degrade-vs-park policy and the concurrency economics. An
unreachable decision server parks the queue; the backlog resumes when the server
comes up, with the `Triaging N remaining…` counter in the rail. `pump` emits
its counts first, inside its `try`, and an empty queue returns there without
taking the drain gate, so a pump over nothing never waits behind a long worker
drain with its `_running` latch held (see [02-gates.md](02-gates.md)).

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
per task, pinned by parity tests (PR #8; `prompt_parity_test.dart` holds
`MessageTextTask` to it) — a change to the message-text prompt is a change
for both connectors.

**The model's `notification` verdict as a gate — measured 2026-09-16 on the
retired `TriageTask`, not shipped.** The golden set was joined against five 4B bulk run files (counts
only): triage's `category = notification` fires on 0 of 24 gold-drop items in
every run and on 1 of 76 gold-keep items (the same item every time, outside
the `gate-keep-trap` stratum; the trap's 12 items are clean). The stricter
rule (`notification` and `needs_action = false` and no `reply_expected`) gives
the identical 0 / 1; the 4B calls 23 of the 24 drops `work`. The gate would
catch nothing and lose one keep, so there is no `notification` gate reason and
no code path. The offline gate replay (`make golden-gate
GOLDEN_RUN=<bulk run file>`) reports the proxy on every run, so a prompt
change can be re-read against it.
