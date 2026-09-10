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

## Search

**Three corpora, and each of them is indexed twice.** The document corpus
(messages), the passage corpus (attachment chunks) and the directory corpus
(the passages of the owner's own registered folders,
`13-context-directories.md`) each have a `vec0` index for meaning and an FTS5
index for words: `vec_messages` beside `fts_messages`,
`vec_attachment_chunks` beside `fts_attachment_chunks`,
`vec_context_chunks` beside `fts_context_chunks`. A search runs both halves
over all three and fuses the six rankings into three lists — messages,
documents and directories.

**The keyword indexes are FTS5 with the porter tokenizer**
(`app/lib/data/keyword_index.dart`), never LIKE: substring matching has no
ranking, so there is nothing to fuse a LIKE result INTO. They obey the vec
indexes' rules, for the vec indexes' reasons — created lazily on first read,
never in `schema.drift` and never in a migration (drift's `SchemaVerifier`
diffs the whole of `sqlite_master`), derived and therefore dropped and rebuilt
by `wipeAll`, and failing soft: a table that will not create makes the word
pass ABSENT, not the search broken.

- `fts_messages` has `rowid = messages.rowid` and columns `source UNINDEXED,
  source_message_id UNINDEXED, indexed_updated_at UNINDEXED, subject, sender,
  summary, body`. `sender` is the name and the address in one column, so a
  search for a domain finds it. The watermark IS `indexed_updated_at`: a
  backfill re-files every message whose `updated_at` is at or past the highest
  one filed — every writer that touches text (`upsertMessage`,
  `updateMessageDetail`, `writeTriage`) stamps `updated_at` with the current
  time and none accepts a stamp from outside, so the column only moves forward
  and a row below the mark is a row already filed. The one door a past value
  could come through is `upsertMessage`'s `row['updated_at']`, which must never
  be handed one. Filing is paged at 500 rows in watermark order (`updated_at`,
  then `rowid`, keyset style), one transaction per page, one `INSERT … SELECT`
  inside SQLite — no body text crosses into Dart, and a first pass over a
  whole mailbox that dies partway has still made progress. The order is what
  makes that true: a pass that stops early leaves a prefix whose highest stamp
  is below every row it never reached, so the next pass resumes exactly there.
  Paged by rowid alone, an interrupted first build would set the mark to the
  newest stamp among the rows it did file and exclude the rest forever.
  `messages.rowid` is not stable across a `VACUUM`; the app never runs one, and
  `rebuild()` is the fix if a tool ever does.
- `fts_attachment_chunks` has `rowid = attachment_chunks.id`, which IS stable
  (`INTEGER PRIMARY KEY`), and columns `name, body, chars UNINDEXED`. It is
  filed by a TEXT DIFF, not by presence: `replaceChunks` deletes a document's
  passages and SQLite hands the replacement the id just vacated, so a presence
  test would serve the old text forever. The diff is a join over every stored
  passage and it runs on every search, so it is fenced behind three numbers
  read from each side — row count, highest id, and total `chars`. That is what
  `chars` is in the index for. All three agreeing means no work, and the
  residual it accepts is a re-chunk landing on the same ids at the same total
  length with different words: `rebuild()` is the fix. Past the fence the
  filing is paged at 500 like the message index. Digest chunks are excluded at
  READ time, the vec pass's rule, so filing stays a straight copy.
- Both sweeps for rows whose source has been deleted run only when the two
  tables disagree about how many rows they hold — a scan each, skipped on
  almost every search.

**The FTS query is built, never passed through** (`buildFtsQuery` in
`app/lib/services/search_fusion.dart`). Tokens are `[\p{L}\p{N}']+`
lowercased; a const stopword list of English function words plus
`message/messages/email/mail` is removed unless that empties the query
("how are you" is a real query for someone who remembers those words); at most
8 terms survive; each is double-quoted with `"` doubled inside it; they are
joined with `OR`, because `AND` finds nothing for a question-shaped query. The
quoting is what keeps `retool -test`, `crm:login` and `NOT` from being read as
FTS5 syntax. The embedding still sees the whole untouched query.

**One score, from both halves.** Per candidate:

- `vr = clamp((0.80 − d) / (0.80 − 0.45), 0, 1)` over cosine distance `d`. A
  ramp and not `1 − d`, because the useful range is narrow: measured on the
  live mailbox, true hits sit at 0.43–0.64, noise starts around 0.65, and the
  best row for a query the mailbox contains nothing about was 0.77.
- `kr = (bm25 / the best bm25 this query found) × sqrt(matched content terms /
  content terms)`. bm25 is FTS5's score negated so bigger is better, and it has
  no absolute scale — only a scale against this query. The coverage factor is
  what stops a row that matched only "12" from scoring 1.0.
- `score = 0.5·vr + 0.5·kr`, a missing signal counting 0. Keep `score ≥ 0.25`;
  order by score descending, then `received_at` descending.

A row strong in both outranks a row strong in one; a row strong in one alone
still shows, in proportion. bm25 column weights are `subject 4, sender 2,
summary 2, body 1` for messages and `name 2, body 1` for chunks — passed
positionally against EVERY declared column, UNINDEXED ones included, which is
the trap in `bm25()`. Documents use the same formula over passages, but the
passages are grouped per FILE (`blobSha256 ?? '<name>|<size>'` — the same PDF
is attached to two messages) BEFORE anything is scored: a file's numbers are
the nearest distance and the strongest bm25 any of its passages reached, the
score is computed once from those, and the passage shown is the one behind
whichever half scored higher. Grouping after scoring would have left a file the
two halves found in different passages as two single-signal entries, each
earning half a score — so a file both halves matched moderately could fall
under a floor a message in the identical position clears. Kept at `≥ 0.25`, and
capped at 6. Every constant lives in `SearchTuning`; RRF was tried and
rejected, because a mediocre row in both lists beat the rows only words could
find.

**The third corpus is the owner's own work, and it is searched over EVERY
registered directory.** `MessageSearch` takes an optional `ContextStore`; both
passes ask `allDirIds()` and hand the whole list to `chunkKnn` /
`keywordChunks` as a scope, because a scope belongs INSIDE the query — a
corpus-wide match narrowed afterwards is what the two scoped reads exist to
prevent, and the caller entitled to name every directory still names them.
Digests are excluded at read time (`excludeDigests: true`), the attachment
index's own rule: a search result promises the file's own words, and a digest
is a model's summary of them. The reply retriever does the opposite — a digest
is very often the only passage that answers a question about a FINDING — which
is why the flag defaults to off.

`fuseDirectories` is `fuseDocuments`'s arithmetic, grouped per FILE before
anything is scored and for exactly its reasons. It is a twin rather than one
generic function over both, because the two corpora disagree about IDENTITY: a
document is a blob and needs `blobSha256` with a name-and-size fallback, where
a directory file is a row and `context_files.id` is already on the hit. Kept
at `≥ 0.25` and capped at 6, like the documents.

Both directory reads sit in their own `try`/`catch` that yields null rather
than a notice: a directory index that cannot be read must never make a search
of the MAILBOX report itself unavailable or narrowed. The list is shown as
**In your directories**, above `In documents` and above the message rows —
that order is an order of answers, since a question about a project is
answered better by the project than by a document that arrived about it.

**What the floor can and cannot suppress.** Only the VECTOR half. `kr` is
normalised against the best bm25 in this query, so the top keyword row always
scores `1 × sqrt(coverage)` — for a single-term query that is 0.5, twice the
floor. A literal word match therefore always shows, whatever `minScore` is set
to, and `invoice → 0` in the table below reflects a mailbox in which no message
contains the word rather than a floor that cut them. Anyone re-tuning
`minScore` is tuning the meaning half alone.

**What the floor bought** (probe, 2026-09-08; every query used to return 49–50
messages, whatever it asked):

| Query | Messages kept | Documents |
|---|---|---|
| lunch | 4 | — |
| what messages are about lunch plans | 9 | — |
| invoice | 0 | the order-confirmation PDF at 0.67 |
| notion workspace invite | 6, the two invites on top by words alone | — |
| september 12 meeting | 13, the three real threads at 0.84–0.93 | 0 (8 before coverage) |
| pub crawl tickets | 3 | the PDF once, was 4 copies |
| retool | 3 | — |
| sparrow kidney | 1 | the paper once, was 41 chunks |
| crm login problems | 12 | — |

**Search degradation.** The search UI distinguishes "nothing matches" from
"half the search could not run" — the floor above is what makes the first of
those a real answer. Both halves failing is `MessageSearchUnavailable`, which
never swaps the feed away. One half failing is a result with a notice ON it,
and there are exactly two sentences: *Words only — …* when the embedding
server or the vector index is down (the sentence names which), and *Meaning
only — the keyword index could not be built.* when FTS is unavailable. They
never coexist; that pair is the unavailable case.

**Search grammar.** Home's box takes facets — `from:`, `in:`, `has:file`,
`before:`, `after:` — parsed by `parseSearchQuery`
(`app/lib/services/search_grammar.dart`) before anything is embedded. Only
`in:` reaches this layer: it travels down as `sources` to all four reads —
`semanticSearch`, `searchAttachmentChunks`, `keywordSearchMessages` and
`keywordSearchChunks` — because the connector is a column on every row each
read touches and narrowing there stops the index spending its whole budget on
hits the reader excluded. Everything else filters the hits afterwards. A query
of nothing but facets is refused before the embed call — there is no sentence,
and embedding the empty string would rank the whole mailbox by its distance from
nothing at all. The facet table and the client-side half are in
[../shell.md](../shell.md#finding-things).
