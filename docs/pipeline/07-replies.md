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

## What a send writes

`DraftNotifier.send` (`app/lib/providers/draft_provider.dart`) is the only
path to the network, and both of its arms put the reply in the transcript
before returning — the user watched it leave, and a minute of invisibility
reads as a send that failed.

- **Teams.** Graph answers a chat post with the message it stored, so the row
  is written from that answer through `TeamsSync.messageRow`, id and all. The
  next pull recognises the id and folds nothing twice. The row, the fold and
  the storyline recap are `writeOutboundChatRow`
  (`app/lib/services/outbound_chat.dart`), shared with compose so a composed
  chat message and a chat reply write the same database.
- **Mail.** `sendDraft` answers with `SentDraft` — the ids read off the draft
  just before it went. The row is a `local:<draftId>` echo built by
  `mailEchoRow`, which the Sent Items copy replaces on the next drain, matched
  on `internet_message_id`. See [01-sync-ingest.md](01-sync-ingest.md) for the
  reconciliation and its race guard.

Both arms then call `MessageStore.foldOutboundSend`, which applies
`foldMessage` to the stored conversation row and recomputes its counts.
Counts alone are not enough: the rail orders by `last_message_at` and shows
`last_message_preview`, so recounting left an answered thread sitting where it
was, previewing the question — and nothing would ever have corrected it, since
the row these sends write is one no ingest will announce.

Until the stored row is on screen, `DraftState.inFlightBody` keeps the
optimistic bubble up; the screen's `_reloadOpenThread` is what swaps it for the
row, on the send path and after each poll's sync.

## Composing a new message

`ComposeNotifier.send` (`app/lib/providers/compose_provider.dart`) is the
other path to the network, and the difference from a reply is that it CREATES
the conversation row rather than folding one the sync wrote.

- **Mail** goes through the draft path, not `send_email`: `createDraft` then
  `sendDraft`, so the capability ladder, the `webLink` hand-off and the ids the
  echo needs are all the ones replies already use. The conversation row is
  written **before** the `local:` echo — `foldOutboundSend` is a no-op without
  a row, `recomputeConversationCounts` needs one, and `insertLocalEcho` may
  decline outright if a poll already landed the Sent Items copy. Every field is
  written fresh (participants, state `waiting`, both stamps, the preview),
  because `upsertConversation`'s conflict clause overwrites rather than merges.
- **Teams into an existing chat** reuses `writeOutboundChatRow`, then makes the
  same three needs-you writes the reply arm makes.
- **A new Teams chat** calls `ensureChat` first. A 1:1 is idempotent; a GROUP
  is created on every call, so the chat id is held in `ComposeState.groupChatId`
  the moment `ensureChat` answers and a retry after a failed post reuses it
  instead of leaving an empty group behind. A 1:1 `ensureChat` can answer with
  a chat the app already stores — the person was picked by name rather than
  the thread from the list — and that chat takes the existing-chat writes
  above, a fold rather than a fresh row, so its state, category and roster
  survive and its needs-you chip clears. For a chat that is genuinely new the
  roster comes from `chatMembers` minus the owner, falling back to the picked
  people when Graph answers with nobody, and the subject follows `TeamsSync`'s
  own rule (the topic when the pick was a group, else the names, three then
  `…`).

After a send the screen AWAITS `conversationsProvider.load(syncFirst: false)`
**before** requesting `OpenThreadIntent`. The order is load-bearing: the inbox
resolves a selection against the loaded list and falls through to Home when the
key is not in it.

Each send records one `compose` activity event — the channel, the recipient
count and the outcome, and deliberately no addresses.

The directory scope (`User.ReadBasic.All`) gates only the recipients
typeahead's org search. Recents, typed addresses, drafts, sends and chats all
work without it. A tenant that granted the wider `User.Read.All` or
`Directory.Read.All` satisfies it too — Entra's consent hierarchy puts the
basic read inside both, and the app reads them that way rather than insisting
on the narrow name an admin rarely picks.
