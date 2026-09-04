# 10 · Model routing, failure policy, and the prompt fence

## Routing is decided at construction, not per call

There is no per-call router. Each queue/handler is handed one `LlmClient`
instance when the providers are built, and that wiring — with the prose
explaining it — lives in `app/lib/providers/app_providers.dart`:

| Provider | Slot | Default | Served by |
|----------|------|---------|-----------|
| `llmClientProvider` | prose / 27B | `LLAMA_URL` → `http://localhost:8080/v1/chat/completions`, `LLAMA_MODEL` → `qwen3.8` | `make model` (Qwen3.8-27B) |
| `fastLlmClientProvider` | bulk / fast | `FAST_LLAMA_URL` → `http://localhost:8082/v1/chat/completions`, `FAST_LLAMA_MODEL` → `qwen3.8` | `make fast` (Qwen3-4B-Instruct) — note **8082**, not 8081 |
| `embeddingsClientProvider` | embed | `EMBED_URL` → `http://localhost:8081/v1/embeddings` | `make embed` (embeddinggemma-300M) |

All are `--dart-define`-overridable; adopting a bakeoff winner is config in
`local.mk`, not code (see `docs/model-bakeoff.md`). llama-server ignores the
model name field, but MLX-style runtimes route on it — which is why each
client carries its own name constant (doc comment in `llm_client.dart`).

Assignment: triage, extraction, and storyline membership-confirm get the fast
client; storyline naming (`storyline_name`), storyline refresh
(`storyline_refresh`), storyline recap (`storyline_recap`), reply decision, and
drafting get the 27B. Changing which slot serves a task is one line in
`app_providers.dart` — and an update to that task's page here.

## Failure policy: park, never fall back

- **No fallback between servers.** A down server throws
  `LlmUnavailableException`; `AiWorker` (`app/lib/services/ai_worker.dart`)
  parks only that *kind* of work, and a dead session parks the whole drain.
  Work resumes when the server comes up.
- Per-request timeout 120 s (`llm_client.dart`). 5xx → unavailable/park;
  timeout → counted against the item; HTTP 400 → fatal, never retried.
- `TriageQueue` and `AiWorker` share one `DrainGate`
  (`app/lib/services/drain_gate.dart`) so the two drains never compete for the
  fast server's slots. The worker's header comment explains handler ordering
  as a data dependency and per-kind vs whole-drain parking.

## Every prompt is fenced

Every task's system prompt is `rules + untrustedDataClause`
(`app/lib/services/llm/prompt_guard.dart`), and all sender-supplied text is
wrapped by `wrapUntrusted` with `&`-first escaping so a message body cannot
forge a closing tag. A new task must compose its prompt the same way — no
raw interpolation of message content into a prompt, ever.

## Task plumbing

All eight chat tasks implement `JsonTask` (`app/lib/services/llm/json_task.dart`):
a schema-constrained call whose defaults are temperature 0.2 / maxTokens 512,
overridden per call site (see each stage's page). Decoding is
grammar-constrained; `make bench-verify` asserts the server honours the
schema before any bench run trusts it.
