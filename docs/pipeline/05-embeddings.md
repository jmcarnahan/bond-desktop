# 5 · Embeddings

**What happens.** Two distinct vector corpora, one embedding server, and they
are never mixed:

1. **Clustering corpus** — one vector per *conversation card*, used by the
   storyline sweep to find threads about the same thing. Written by
   `ExtractHandler._refreshCard` into `conversation_ai.embedding`.
2. **Document corpus** — one vector per *message*, used by semantic search
   (sqlite-vec, PR #10). Written on the fast path by
   `ExtractHandler._embedMessage` and healed by the `embed_message` work queue
   in `EmbedHandler` (`app/lib/services/embed_handler.dart`) for anything the
   fast path missed.

**Attachment markers and the card hash.** `embedMessageRow` strips
`[[att:…]]` / `[[img:…]]` markers out of the body before building the card, and
it is the ONE place that happens on this path — `ExtractHandler` and
`EmbedHandler` both come through it, and a strip in either alone would give
them different cards and different hashes for the same message. Adding that
strip changes `cardHash` for every marker-bearing Teams message, which costs
one slow re-embed drain and nothing else. A chat message that was nothing but a
shared file embeds as `Shared a file: <name>` rather than as a subject and a
sender. See [12-attachments.md](12-attachments.md).

**Each corpus has its own sqlite-vec index, and the separation above holds
through them.** `MessageVectorIndex` (`vec_messages`, over `message_vectors`)
answers search; `ConversationVectorIndex` (`vec_conversations`, over
`conversation_ai`) answers the sweep. Both are `vec0` virtual tables at
`float[768] distance_metric=cosine`, both are created **lazily on first use and
never in a migration or `beforeOpen`** — drift's `SchemaVerifier` diffs the
whole of `sqlite_master`, so a virtual table appearing during a migration step
fails every migration pair in the suite — and both are derived, so losing one
costs a rebuild and not a single model call.

**A THIRD table, and it is not one of those two.** `attachment_chunks`
(`AttachmentChunkIndex`, `vec_attachment_chunks`) holds the passages of
attached documents: same embedding server, same `documentPrefix`, same
`documentModelTag`, so a query embedded for message search finds documents too.
It is a separate corpus for the same reason the first two are separate from
each other — a document is many passages, and the clustering corpus has to stay
"what people said". Fifty chunks of one contract in `message_vectors` would be
fifty near-identical neighbours crowding out the threads the sweep is about.
Its backfill is the message index's, with one added clause: `embedding IS NOT
NULL`. A chunk row is written when the document is split and its vector arrives
one POST later, so an unembedded row must be neither filed nor stamped. See
[12-attachments.md](12-attachments.md).

Their *bookkeeping* differs, because their durable sides do.
`message_vectors` has an `indexed_at` column, so the message index files the
unstamped rows and stamps them. `conversation_ai` has no such column and does
not gain one for a derived index's convenience: `ConversationVectorIndex`
carries the `(source, conversation_key)` pair and the `embedded_hash` on the
vec0 row itself (sqlite-vec *auxiliary* columns), and its backfill is a **diff**
— insert what is missing, replace what re-embedded under a new hash, delete
what left the corpus or was re-tagged to another model. That diff is a full
scan of both sides, run once per sweep against a few hundred rows; it is worth
revisiting if the clustering corpus ever reaches the tens of thousands.

**No chat-model call.** The server is a third llama-server in embedding mode.

| | |
|---|---|
| Client | `EmbeddingsClient` — `app/lib/services/llm/embeddings_client.dart` |
| Server | `EMBED_URL`, default `http://localhost:8081/v1/embeddings` (`make embed`) |
| Model | embeddinggemma-300M |
| Corpus separation | clustering prefix/tag vs document/query prefixes + tag — constants in `embeddings_client.dart`; EmbeddingGemma is prefix-sensitive, so a vector's corpus is baked in at embed time |

**Failure behavior.** Embed failures park and self-heal instead of silently
dropping storyline work (PR #9): stranded claims are released, heartbeated,
and reclaimed, and terminal errors get one bounded revival a day. The header
comments in `embed_handler.dart` document the queue's contract.

**Search degradation.** The search UI distinguishes "nothing matches" from
"the index is off" — an unavailable embed server degrades honestly rather
than pretending an empty result.
