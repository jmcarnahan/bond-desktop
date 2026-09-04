# 5 · Embeddings

**What happens.** Two distinct vector corpora, one embedding server, and they
are never mixed:

1. **Clustering corpus** — one vector per *conversation card*, used by the
   storyline sweep to find threads about the same thing. Written by
   `ExtractHandler._refreshCard`.
2. **Document corpus** — one vector per *message*, used by semantic search
   (sqlite-vec, PR #10). Written on the fast path by
   `ExtractHandler._embedMessage` and healed by the `embed_message` work queue
   in `EmbedHandler` (`app/lib/services/embed_handler.dart`) for anything the
   fast path missed.

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
