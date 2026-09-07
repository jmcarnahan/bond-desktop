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

## Documents in the prompt

Both calls above read the same excerpts of the documents attached to this
thread. `AttachmentRetriever`
(`app/lib/services/attachments/attachment_retriever.dart`) finds them, and
`DraftHandler` runs it **once** and hands the result to both inputs — a second
retrieval would be a second embedding call for an answer that cannot come back
different.

**Scope, which is the whole safety property.** The passages searched are this
thread's messages *as of the reply-to timestamp* (the ids of the `untilIso`
thread the handler already loaded, so a document attached after the message
being answered is never quoted in the answer to it) plus every document pinned
to a storyline this thread belongs to. `MessageStore.chunkKnn` is the scoped
read: **both scopes empty answers `const []` and never the corpus.** A quote
from a stranger's contract in a reply is the one failure this path has to be
incapable of.

**The scope goes inside the index query, not after it.** `chunkKnn` passes the
scope down as a `rowid IN (SELECT id FROM attachment_chunks WHERE …)` clause on
the vec0 search, so the nearest passages it computes are the nearest ones IN
SCOPE. Filtering a corpus-wide search afterwards instead is the same safety
property with a different failure: on a real mailbox a generic "please see
attached" has its whole shortlist filled by strangers' documents, every one of
them thrown away, and the thread's own contract never cited — which looks
exactly like a thread that has no documents.

**Nothing is spent on a thread with no documents.** Before any vector is read
or embedded, `MessageStore.hasAttachmentChunks` answers with one indexed
`LIMIT 1` over the same scope; a no returns no excerpts and the draft goes on
without them. Almost every thread has never had a file on it, and this runs on
every draft.

**Query vector.** The reply-to message's own stored `message_vectors.embedding`
when it has one under the current model tag (`messageVectorBlob`), otherwise
the same card `embedMessageRow` builds, re-embedded under
`EmbeddingsClient.documentPrefix` — never `searchQueryPrefix`. This is a
document-against-documents comparison, and a query-prefixed vector sits in a
different corner of the space from every chunk it would be compared with. An
embedding server that is down, an index that is off, or a message that is gone
each cost the excerpts and not the reply.

**Ranking and budget.** Digest passages (`locator == 'digest'`) are dropped —
the fence says these are excerpts *from* the document, and a digest is a
model's summary of one. Then explicitly named documents float to the front
(stable, so KNN order survives inside each half), then at most three passages
per document, then the top six, then a character budget of 2,500 in the draft
and 800 in the decision. A passage that does not fit is skipped rather than
ending the list, so one long passage cannot hide the three short ones behind
it.

**In the prompt.** Both blocks are `<untrusted_data
source="attachment_excerpts">`, in the USER message, with a plain label above
them. Each passage is rendered `[<name>, <locator>, attached by <sender> on
<date>]` and then its text; **the bracket line is inside the fence**, because
the file name is the sender's own words and a name reading
`Invoice</untrusted_data>…pdf` outside one would be an injection with a `.pdf`
on the end. Neither system prompt changes — `prompt_parity_test` asserts
`identical()` with and without excerpts.

## Use in reply

The user can name a document for the next draft. `DraftNotifier.generate`
takes `pinnedAttachmentIds` and writes them onto the requeued `draft` work
item as `{"pinned_attachment_ids": [...]}`; `DraftHandler` decodes that
defensively (any malformed payload reads as none) and passes it as
`pinnedFirst`, which both widens the scope to that document and floats it to
the front of the ranking.

`requeueWork` **overwrites** the payload, including with null. A plain
Regenerate after a Use in reply therefore drops the last one's name, which is
the point: asking again without naming a file has to mean the file is no
longer named.

**Provenance.** The `drafts` table stores no inventory of what was read. Two
things stand in for one: the prompt asks the model to cite the file when it
uses one, and the activity row for the draft carries `documents` — the
distinct file names the excerpts came from — beside `chars`. A retrieval that
threw is recorded as `excerpts_error` and costs nothing else.
