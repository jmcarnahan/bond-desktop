# The message pipeline

Every synced message moves through the same ordered pipeline: cheap gates
first, then a chain of model calls that classify it, extract facts from it,
group its conversation into storylines, decide whether it deserves a reply,
and draft one. This directory documents each section — what happens, what the
prompt says, and which model serves it.

**Maintenance rule: these files describe the code, and the code moves. Any
change to a pipeline stage — its ordering, its prompt, its schema, its model
slot, its failure behavior — must update the corresponding file here in the
same PR.** File and symbol references are the pointers into source; the source
is always the authority when they disagree.

## The stages, in order

| # | Stage | LLM | Doc |
|---|-------|-----|-----|
| 1 | Sync / ingest — Graph delta pull, upsert, enqueue downstream work | no | [01-sync-ingest.md](01-sync-ingest.md) |
| 2 | Tier-1 gates — sender-only checks on delta fields | no | [02-gates.md](02-gates.md) |
| 3 | Detail fetch (mail) — full body + headers | no | [02-gates.md](02-gates.md) |
| 4 | Tier-2 gates — list/auto-generated header checks | no | [02-gates.md](02-gates.md) |
| 5 | **Triage** — urgency, category, summary, action items | **yes** | [03-triage.md](03-triage.md) |
| 6 | **Needs-you verdict** — does this message want the owner | **yes**† | [11-needs-you.md](11-needs-you.md) |
| 7 | **Extraction** — evidence, topics, people, intent, importance | **yes** | [04-extraction.md](04-extraction.md) |
| 8 | Bucket filing — low-value mail to Later, unless the thread holds an open ask | no | [04-extraction.md](04-extraction.md) |
| 9 | Embeddings — clustering + per-message search vectors | no* | [05-embeddings.md](05-embeddings.md) |
| 10 | Attachments — text extraction and chunk embeddings, then one digest per document | **yes**‡ | [12-attachments.md](12-attachments.md) |
| 11 | **Storylines** — assign, sweep, refresh, recruit, recap | **yes** | [06-storylines.md](06-storylines.md) |
| 12 | **Reply decision** — does this message need an answer | **yes** | [07-replies.md](07-replies.md) |
| 13 | **Draft generation** — the suggested reply itself | **yes** | [07-replies.md](07-replies.md) |
| 14 | Attention rescore — Needs You ranking | no | [08-attention.md](08-attention.md) |
| 15 | Notification settle — one verdict per message | no | [09-notifications.md](09-notifications.md) |

\* embeddings call the embedding server, but no chat model.

The attachment row sits here because this is where the two handlers register:
`AttachmentTextHandler` and `AttachmentDigestHandler` go on the drain between
Embed and StorylineAssign (`app_providers.dart`), so a document is read before
the storylines and the drafts that quote it are.

‡ Three stages, and only the last dials a chat model. The METADATA stage runs
inside stage 1: both syncs write `attachments` rows and queue `attachment_text`
work, and triage reads the names and sizes. `attachment_text` then fetches the
words through Graph and embeds their passages on the embedding server — no chat
model, so a park there is a park on `make embed`. `attachment_digest` is the
one fast-slot call: one record per document, queued by the text handler and
only once there are words.

The arrow also runs backwards, once. A digest that records something the
document ASKS for sends its message back to stage 6 — a file saying "sign by
Thursday" can change whether the owner is needed, and the first verdict was
written before anything had read it. One requeue per message, and the drain
makes one more pass so it lands before the settle asks. Stages 12 and 13 read
documents too: the passages nearest the message being answered, scoped to its
own thread and its storyline's pinned files. See
[12-attachments.md](12-attachments.md) and [07-replies.md](07-replies.md).

† a deterministic floor (an inbound Teams @mention or 1:1) answers without any
model call; everything below the floor gets the fast-slot judgment. See
[11-needs-you.md](11-needs-you.md).

Cross-cutting concerns — which client serves which task, ports and defaults,
parking and retry policy, and the untrusted-data fence around every prompt —
live in [10-model-routing.md](10-model-routing.md).

## The two-model split at a glance

| Task | Slot | Default server (compile-time) |
|------|------|----------------|
| Triage | fast / bulk | `:8082` Qwen3-4B-Instruct (`make fast`) |
| Needs-you verdict | fast / bulk | `:8082` |
| Extraction | fast / bulk | `:8082` |
| Attachment digest | fast / bulk | `:8082` |
| Storyline membership confirm | fast / bulk | `:8082` |
| Storyline naming | prose / 27B | `:8080` Qwen3.8-27B (`make model`) |
| Storyline refresh | prose / 27B | `:8080` |
| Storyline recap | prose / 27B | `:8080` |
| Reply decision | prose / 27B | `:8080` |
| Draft generation | prose / 27B | `:8080` |
| Embeddings | embed | `:8081` embeddinggemma-300M (`make embed`) |

Both chat slots can be re-pointed at runtime in Settings → Models; the mapping
above does not change. See
[10-model-routing.md](10-model-routing.md#runtime-overrides).

The home screen's five-segment stage bar (triage · extract · storyline ·
draft · settle) is this pipeline rendered per row; `pipeline_progress.dart`
records the transitions it draws.
