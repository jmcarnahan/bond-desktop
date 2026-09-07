# 3 · Triage

**What happens.** The first model read of a message. `TriageQueue`
(`app/lib/services/triage_queue.dart`) claims ungated messages newest-first,
loads the prior messages on the conversation (cut off at this message's
`received_at` so the model never sees the future), runs `TriageTask`, and
folds the result into `triage_status`, the conversation's CTA rollup, and an
activity row.

**The model call.**

| | |
|---|---|
| Task | `TriageTask` — `app/lib/services/llm/triage_task.dart` |
| Prompt | `_triageRules` at the top of that file, composed with the shared untrusted-data fence (`prompt_guard.dart`) |
| Schema | `triage` — flat; **key order is load-bearing** (the doc comment above the schema explains why) |
| Output | urgency, category, 2–4 word label, one-sentence summary, `needs_action`, action items, `addressed_me`, `reply_expected`, `deadline` |
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

**Shared prompt across sources.** Mail and Teams run the *same* system prompt
per task, pinned by parity tests (PR #8) — a change to the triage prompt is a
change for both connectors.
