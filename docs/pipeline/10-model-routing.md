# 10 · Model routing, failure policy, and the prompt fence

## Routing is decided at construction; the TARGET is resolved per call

There is no per-call router. Each queue/handler is handed one `LlmClient`
instance when the providers are built, and that wiring — with the prose
explaining it — lives in `app/lib/providers/app_providers.dart`. Which
*server and model* that client dials is resolved at call time instead, so a
settings change moves the next request without rebuilding the client or
anything watching it (see **Runtime overrides** below):

| Provider | Slot | Compiled default | Served by |
|----------|------|---------|-----------|
| `llmClientProvider` | prose / 27B | `LLAMA_URL` → `http://localhost:8080/v1/chat/completions`, `LLAMA_MODEL` → `qwen3.8` | `make model` (Qwen3.8-27B) |
| `fastLlmClientProvider` | bulk / fast | `FAST_LLAMA_URL` → `http://localhost:8082/v1/chat/completions`, `FAST_LLAMA_MODEL` → `qwen3.8` | `make fast` (Qwen3-4B-Instruct) — note **8082**, not 8081 |
| `embeddingsClientProvider` | embed | `EMBED_URL` → `http://localhost:8081/v1/embeddings` | `make embed` (embeddinggemma-300M) |

All are `--dart-define`-overridable, and the two chat slots are also
overridable at runtime in **Settings → Models**; adopting a bakeoff winner is
config in `local.mk` or a setting, not code (see `docs/model-bakeoff.md`).
llama-server ignores the model name field, but MLX-style runtimes route on it
— which is why each slot carries its own name (`model_slots.dart`).

Assignment: triage, extraction, and storyline membership-confirm get the fast
client; storyline naming (`storyline_name`), storyline refresh
(`storyline_refresh`), storyline recap (`storyline_recap`), reply decision, and
drafting get the 27B. Changing which slot serves a task is one line in
`app_providers.dart` — and an update to that task's page here.

## Runtime overrides

The table above is what a build is COMPILED with. Either chat slot can be
pointed somewhere else while the app runs, from Settings → Models, without a
restart and without interrupting work in flight.

- **Per slot, not per stage.** The stage→slot mapping is fixed in
  `app_providers.dart`; the settings screen only displays it, from the authored
  `pipelineStages` table in `app/lib/services/llm/model_slots.dart`. Moving a
  stage between slots is still a code change and still an edit to this file.
- **Late binding.** `LlmClient` holds an optional `LlmTarget Function()` and
  resolves it ONCE at the top of every request (`_post`), so the URL and the
  model name can never come from two different settings. The client providers
  therefore still watch only `activityLogProvider`: a model change rebuilds
  nothing, and a drain already running finishes on the server it started with,
  request by request.
- **Where it is stored.** Four prefs — `fast_llm_url`, `fast_llm_model`,
  `prose_llm_url`, `prose_llm_model` — in `app_prefs`, read into `AppPrefs` and
  composed by `AppPrefs.fastTarget` / `proseTarget`. **Empty means "follow the
  build"**, deliberately unlike `mcp_server_url`, which resolves its default on
  read: a model default is a fact about this machine's `local.mk`, and freezing
  today's value into the database would make a changed dart-define invisible.
  They survive `wipeAll` for the same reason the backend mode does — machine
  configuration, not one account's data.
- **Discovery.** `ModelServerProbe` (`app/lib/services/llm/model_probe.dart`)
  turns a completions URL into its `/v1/models` listing and GETs it with a 5 s
  timeout. It never throws: reachable means HTTP 200 with a readable list.
  llama-server answers with the single model it loaded; MLX-style runtimes list
  several, which is what makes the model NAME worth setting.
- **Embeddings are not switchable.** Stored vectors are tagged
  `embeddinggemma-300M/clustering` and `…/document` and are only comparable
  within a tag, so the embed slot is displayed and probed but never moved.
- **What a wrong model name costs.** A runtime that routes on the name answers
  HTTP 400 for one it does not have, and a 400 is fatal — never retried (see
  below). Pick from the probe's list rather than typing.
- **A note on the KV cache.** Switching a slot's server sends the next request's
  byte-identical system prompt to a cold prefix cache — one slower call per
  task, then back to normal. Pointing BOTH slots at one server is worse and
  permanent: two prompts evicting each other, which is the thing the split
  exists to avoid.

Every call records which model answered it: `LlmCallRecord` carries `model` and
`baseUrl`, and the activity log folds the model into the row as `llm_model`
(shown on the `t/s` cell's tooltip and in the expanded detail).

## Failure policy: park, never fall back

- **No fallback between servers.** A down server throws
  `LlmUnavailableException`; `AiWorker` (`app/lib/services/ai_worker.dart`)
  parks only that *kind* of work, and a dead session parks the whole drain.
  Work resumes when the server comes up.
- Per-request timeout 120 s (`llm_client.dart`). 5xx → unavailable/park;
  timeout → counted against the item; HTTP 400 → fatal, never retried — which
  is what a model name the server does not have looks like.
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
