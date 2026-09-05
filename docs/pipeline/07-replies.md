# 7 · Reply decision and draft generation

Drafts run at the grain of the *message*, not the thread (schema v9, PR #10):
each draft is keyed to the message it answers. `DraftHandler`
(`app/lib/services/draft_handler.dart`) runs both calls, on the **prose /
27B slot**, and only for messages that passed the cheap `asksForAReply`
pre-gate in extraction (see [04-extraction.md](04-extraction.md)).

That pre-gate has a fifth signal: a `needs_you_verdict` of 1, the needs-you
stage's read of the whole message (see [11-needs-you.md](11-needs-you.md)).
`NeedsYouHandler` drains before extraction, so the verdict is on the row by the
time the gate reads it. It only ever **widens** what reaches this file — the
`ReplyDecisionTask` below still owns the actual reply decision, and a "no" from
the 27B closes the draft stage `skipped` however the message got here.

## Reply decision — should we spend drafting time at all

| | |
|---|---|
| Task | `ReplyDecisionTask` — `app/lib/services/llm/reply_decision_task.dart` |
| Schema | `reply_decision` |
| Slot | **prose / 27B** |
| Params | temperature 0, maxTokens 256 |

The 27B reads the actual conversation and answers exactly one question: does
the inbox owner need to write a reply. The prompt carries explicit yes-lists
(asks a question, requests action, awaits a decision, pushes on an unanswered
thread) and no-lists (FYI, receipt, acknowledgement, group broadcast, already
answered, mere courtesy), asks the model to judge from the sender's point of
view, and requires a one-sentence reason. The doc comment above the prompt
explains why it asks only one question. A "no" closes the draft stage
`skipped` — no drafting tokens are spent.

## Draft generation

| | |
|---|---|
| Task | `DraftTask` — `app/lib/services/llm/draft_task.dart` |
| Schema | `draft_reply` |
| Slot | **prose / 27B** |
| Params | temperature 0, maxTokens 1536 |

Writes a first-person reply on the owner's behalf: an evidence sentence, one
or two genuinely different short options with imperative stances, and a full
plain-text reply body. The load-bearing rule is **invention**: never fabricate
facts, numbers, dates, names or commitments — if the thread lacks what's
needed, ask the single clarifying question instead.

**A prompt-cache constraint worth knowing before editing:** channel style
rules (email vs chat) live in the *user* message (`_emailChannelNote` /
`_chatChannelNote`), **not** the system prompt, so the system prompt stays
byte-identical across sources and the 27B's single-slot KV prefix cache
survives crossing between mail and Teams. Moving channel text into the system
prompt would silently destroy that cache hit.

An empty drafted body throws `LlmFormatException`, which earns the worker's
one retry. Nothing sends on its own: a draft is text in a box until somebody
presses Send.
