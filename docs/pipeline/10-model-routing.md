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

Assignment: triage, extraction, the attachment digest
(`attachment_digest`), the directory file digest (`context_file_digest`), the
directory brief (`context_brief`), the directory section pick
(`context_select`), and storyline membership-confirm get the
fast client; storyline naming (`storyline_name`), storyline refresh
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
  `embeddinggemma-300M/clustering-v2` and `…/document` and are only comparable
  within a tag, so the embed slot is displayed and probed but never moved. The
  `-v2` is 2026-09-18, when the people left the clustering card: a change to
  the text a corpus is embedded from is a tag bump and a one-shot re-embed, and
  `05-embeddings.md` has both.
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
(shown on the `t/s` cell's tooltip and in the expanded detail). The record's
`outcome` is decided after the answer has been made usable: a constrained
call whose content is not the JSON object it asked for is recorded as
`format`, never as `ok` — the decode runs inside the same instrumented try as
the request, so a model that overran its budget mid-object counts as a failed
call in every table built from these records.

**Two wires, one client.** `LlmClient` can also carry a bearer token and speak
Bedrock's Converse wire (`LlmWire.bedrockConverse`) alongside the OpenAI one.
Nothing in `lib/` sets either — every provider still constructs the client on
the OpenAI wire with no token — so routing, the slots and the failure policy
below are exactly what they were. The seam exists for the bakeoff
(`docs/model-bakeoff.md`, "Bedrock as a target") and for the speed design's
opt-in cloud drafts. On Converse a JSON answer is a forced tool call rather
than a `response_format`, `temperature` is not sent, and the response carries
no server timings.

**One streamed call.** `LlmClient.completeJsonStreamed` is the same request with
`"stream": true` and `"stream_options": {"include_usage": true}`, read back as
server-sent events and handed to the caller delta by delta. It exists for one
caller — the draft, see [07-replies.md](07-replies.md) — and it is a separate
METHOD rather than a flag on `completeJson` because twenty-two test doubles
override that method with its exact signature. Everything but the delivery is
shared with the plain path: the same status mapping (5xx and 429 park, anything
else non-200 is fatal), the same timeout over the WHOLE read rather than just
the headers, the same `usage` and `timings` readers, the same reasoning
tripwire, the same decode at the end — so a stream that stopped mid-object is
the format failure a truncated plain answer is, and the observer sees exactly
one record. That record carries one field the plain path leaves null:
`firstTokenMs`. Streaming is OpenAI-wire only; on Converse the call degrades to
one plain POST.

## Managed mode: one router

Everything above describes the app talking to servers somebody else started.
It can also start its own — ONE llama-server in router mode, serving all three
models — and that mode is off by default, so a build with nothing changed
behaves exactly as this page has always described.

- **The supervisor.** `ModelServerSupervisor`
  (`app/lib/services/server/model_server_supervisor.dart`), behind
  `modelServerSupervisorProvider`. It writes a preset, spawns the binary
  `LlamaBinary.resolve()` found, watches the child's output for the listening
  line, polls `/models` and `/health` until every model the preset declares is
  resident, and reports a `ServerState`. `ServerBootstrap`
  (`app/lib/widgets/server_bootstrap.dart`) wraps the whole app and calls
  `ensureRunning()` once at launch — a no-op while the preference is off.
- **The restart budget is per failing launch, not per session.** A crash is
  retried on a 1 / 4 / 16 s backoff and then reported as `failed` with the log
  tail. Reaching ready RESETS the count: a launch that came up has proved it
  can, so a server that crashes once a week and recovers gets the whole ladder
  every time rather than being given up on for good on its fourth crash. A
  `couldn't bind` line is the exception that is never retried — no amount of
  waiting frees a port somebody else is holding.
- **Three ids, one origin.** The preset names its models for the ROLE rather
  than the checkpoint — `bond-prose`, `bond-bulk`, `bond-embed`
  (`model_slots.dart`) — because the router routes on the model name alone.
  Swapping which GGUF fills a role is then a change to the preset and to
  nothing else: no stored target, no request and no test learns the new
  checkpoint's name.
- **How `targetFor` routes.** With `managed_server` on, a slot whose override
  is EMPTY — both the URL and the model — answers
  `http://127.0.0.1:<router_port>/v1/chat/completions` with its router id.
  A slot with a stored override keeps it. That asymmetry is deliberate: an
  override is somebody deliberately pointing the app at a server they run, and
  turning the managed server on must not silently take it away. Clearing the
  override is what hands the slot back to the router. In managed mode the
  editors' "Default" is that router target too (`AppPrefs.slotBaseline`), so
  pressing Save without editing writes an empty override and the slot keeps
  following the router across a port change.
- **Embeddings, two targets.** The embed slot is still not switchable, and it
  now has two targets that are never the same thing.
  `targetFor(ModelSlot.embed)` is for DISPLAY and its model is the corpus tag
  (`EmbeddingsClient.modelTag`); `AppPrefs.embedRequestTarget` is what the wire
  carries — `bond-embed` at the router in managed mode, and the literal
  `embed` (`EmbeddingsClient.requestModel`) at `EMBED_URL` otherwise.
  `EmbeddingsClient` resolves it through the same late-binding
  `LlmTarget Function()` the chat client uses, once per request.
- **Whose job it is to start it.** `EmbeddingsClient` also takes a
  `describeUnavailable` closure. Unmanaged, a refused connection reads
  `is not reachable — run: make embed`; managed, it reads
  `is not running — see Settings › Models › Local server`, because naming a
  Makefile target would send the user back to a workflow they have opted out
  of.
- **`LLAMA_CACHE`.** The child is pointed at an EMPTY directory
  (`servers/empty-cache`). `--no-models-autoload` stops the router loading
  models it was not asked for, but it still LISTS everything in the Hugging
  Face cache, so a developer with a dozen GGUFs downloaded would have the
  readiness check waiting forever for models this app never asked for. An
  empty cache makes the listing exactly the preset.
- **The pid file and the quit hooks.** `servers/router.json` holds the pid, the
  port, the preset hash and the binary path — JSON rather than a bare pid
  because numbers are reused and the number alone is not evidence that the
  process is ours. It is what the next launch reaps and what the Runner's
  `applicationWillTerminate` reads. Dart's own hook is
  `ServerBootstrap`'s `AppLifecycleListener.onExitRequested`, which stops the
  server with a 4 s grace and then exits regardless; the Swift reaper is the
  second line of defence, because a child started with
  `ProcessStartMode.normal` still outlives a parent that dies without running
  it (flutter#134255). That reaper compares the record's `binaryPath` against
  the process's own executable (symlinks resolved on both sides) rather than
  testing that the name ends in `llama-server`, so a pid the kernel has since
  handed to a hand-started `make model` server is never signalled on quit.
- **Adoption takes FOUR agreements**, and every one of them has been the wrong
  answer on its own: the pid is alive, the recorded `presetHash` is the one
  this build writes, the recorded `binaryPath` is the binary this build would
  spawn (symlinks resolved, so `/opt/homebrew/bin/llama-server` and its Cellar
  target are one answer), and the recorded `port` is the one `router_port`
  names. Anything else falls through to the reap-then-start path, which kills
  only when the process's command line carries both `llama-server` AND the
  preset file this app wrote. The binary check is what stops a packaged build
  adopting the Homebrew server a `BOND_LLAMA_SERVER` session left behind and
  reporting Ready for it; the port check is what stops a record written before
  a port change being adopted while every client dials the new one.
- **Off by default.** `managed_server` reads false for an absent key, and the
  compiled slot defaults stay `localhost:8080` / `8082` / `8081`, so the
  three-server `make model | fast | embed` workflow is byte-identical until
  somebody opts in. The port (`router_port`, default 8080) and the models
  folder (`models_folder`, empty = the app's own
  `~/Library/Application Support/com.bondinbox.app/models`) survive `wipeAll`
  with the four slot prefs and for the same reason.

### The manifest

`app/assets/models/manifest.json` is the ONLY place the three checkpoints are
named. Phase 2's Dart trio (`RouterPreset.defaultTrio`) is gone; the preset's
sections are now `ModelManifest.toPreset(folder)`, and `RouterPreset` knows how
to write an INI and nothing about which models belong in one. That is the whole
point of the file: bumping a model must not be a code change, and the diff of
one bump must be legible on its own — three fields in one JSON file (see
`docs/distribution.md`, **Bumping a model**).

One entry per model, in FILE ORDER, which is also the order the INI's sections
take and the order the router loads them in: smallest first, so the embedding
model — the one the ingestion pipeline blocks on — is resident while the
twenty-seven-billion-parameter prose model is still being mapped.

| Field | What it is |
|-------|------------|
| `id` | The router id — `bond-embed` / `bond-bulk` / `bond-prose`, from `model_slots.dart`. |
| `role` | `embed`, `bulk` or `prose`. Exactly one model per role; the parser refuses anything else, because the app asks for a role and the router routes on the id. |
| `repo`, `file` | The Hugging Face repo and the artefact in it. Kept apart because the resolve URL wants both halves and so does the on-disk layout (`<repo with '/' → '_'>/<file>`, the same rule as `RouterPreset.modelPath`). |
| `revision` | A 40-character COMMIT SHA, never `main`. A branch is a moving target: the file behind `main` can be replaced upstream, and a download resolved through it would fetch bytes that no longer match `sha256` — a checksum failure the user cannot act on and this app would have caused. |
| `sizeBytes`, `sha256` | The measured size and the LFS oid. Both are checked against the hub's `X-Linked-Size` / `X-Linked-ETag` on the redirect, so a manifest that is wrong about a file is caught before eighteen gigabytes are spent. |
| `minRamBytes` | What the machine must have. 0 when it always fits. |
| `license`, `licenseUrl`, `notice` | What the first-run screen shows. `notice` is null for the permissive ones, so a screen can skip the line entirely rather than render an empty string. |
| `serverArgs` | llama-server's long flags with the leading dashes stripped — the spelling the preset INI wants. Values are strings; the INI writer prints them verbatim. |

JSON has no comments, so the three flags that are not preferences are recorded
here instead:

- **`pooling = mean`** on the embedding model is not a taste. The stored
  vectors were written under mean pooling, and a server that pooled
  differently would answer plausible numbers in a different space.
- **`parallel = 4`** on the bulk model because the bulk slot is what the drain
  hammers: triage, needs-you, extraction and the digests all queue against it.
- **`parallel = 1`** on the prose model because it is the memory ceiling on
  this machine, and a second concurrent context would double its KV cache.

### The downloader

`ModelDownloader` (`app/lib/services/models/model_downloader.dart`), behind
`modelDownloaderProvider`. It fills the models folder the preset points at, and
Phase 4 draws the wizard on top of it.

- **One stream at a time, smallest first.** The bottleneck is the link, not the
  server, so four concurrent transfers only make every one of them finish
  later; smallest first means the two small models land early and the wizard's
  bars show real progress within minutes. It does NOT open the inbox early:
  the wizard's Continue and the server both wait for all three, because the
  preset names every file and `_launch` refuses to start with one missing
  (`ModelManifest.usableIds` is informational). And a digest that MOVED is
  noticed at the next launch — `DownloadLedger.matches` fails, the gate shows
  the wizard again and it opens on its download step.
- **A failure moves on.** A prose model that 404s must not hide an embedding
  model that finished, so a file's failure is an event on the stream and the
  run continues to the next file. The stream itself never carries an error.
- **`.part` beside the destination, HTTP Range resume.** The part sits next to
  the finished name so the rename onto it is not a cross-device copy. **The
  part's own length is the resume offset, never the ledger's** — the ledger is
  written at most every couple of seconds and a crash can lose the last write;
  the file cannot lie about how many bytes it holds. A server that answers 200
  to a ranged request has ignored the Range, and the part is truncated rather
  than appended to.
- **Re-resolve on expiry, and no URL is ever stored.** Hugging Face answers a
  resolve with a redirect to a signed CDN address that expires in about an
  hour. A 403 mid-transfer means the signature aged out, not that access was
  refused: the app asks the hub again, immediately, without a backoff.
- **sha256 on the platform side.** `SystemInfo.sha256` (CryptoKit) because a
  pure-Dart digest over twenty-three gigabytes takes minutes on the isolate
  that draws the UI. The Dart fallback is what runs under `flutter test`, where
  there is no channel behind the method call. One checksum mismatch is retried
  from zero — a flipped bit in flight is worth one more try; a second is the
  wrong file, and leaves neither a part nor a destination behind.
- **The ledger lives in `setup_state['download']`.** One JSON value per run,
  holding a status, a byte count and the manifest sha each part belongs to — a
  bumped manifest therefore invalidates a stale `.part` rather than resuming
  into bytes from another checkpoint. It holds no URL and no host.
- **A disk preflight with 10 GiB of headroom** (`disk_preflight.dart`) over
  what is still to be downloaded. Free space that cannot be asked is NOT a
  refusal: the download hits ENOSPC and keeps its part, and refusing on
  ignorance would block a volume that simply cannot be asked.
- **The failure vocabulary** is closed and lives in `DownloadError`:
  `disk_full`, `checksum`, `network`, `gated`, `manifest_mismatch`,
  `missing_folder`, and `http_<code>` for everything else. Words rather than an
  enum, so a ledger written by another build stays readable.

### First run

The wizard that fills the folder in the first place. Three gates, outermost
first: `ServerBootstrap` → `SetupGate` → `AuthGate` (`app/lib/main.dart`). The
bootstrap is above everything because the server is wanted signed in or out
and set up or not; `SetupGate`
(`app/lib/screens/setup/setup_gate.dart`) is above the auth gate because
setting the machine up comes before signing in — the wizard has a sign-in step
of its own, and meeting a bare sign-in screen before anything has explained
what Bond is would be the app asking for credentials as its opening line.

- **One stored word.** `setup_state['setup']` holds a `SetupStep.name`;
  `'done'` is the only value that lets the app through. An unknown word — one
  written by another build — reads as `welcome`, and so does a store read that
  throws, on `AuthGate`'s reasoning about an unreadable keychain: the wizard is
  the recoverable answer. The step is written BEFORE the step is entered, so a
  quit mid-probe resumes on the screen the user was looking at; a write that
  fails costs one step, not the button press.
- **Eight steps.** Welcome, Your Mac, Models, Storage, Download, Sign in,
  Notifications, All set. `docs/settings.md` (**First run**) has the table and
  the strings; `docs/install.md` is the same walk for a non-engineer.
- **Continue on the download step waits for EVERY file**, not for
  `ModelManifest.usableIds`. `_launch` refuses to start while any file the
  preset names is missing, so a partial set could not serve the inbox anyway —
  and finishing early would leave a non-engineer looking at an idle inbox with
  no progress bar left to explain it. The rest of the app still uses
  `usableIds`; this is the wizard's rule, not the router's.
- **Finish is what turns managed mode on, and the only thing that writes
  `'done'`.** Arriving at All set records `notifications`, the step before it:
  `'done'` is the gate's sentinel, and a quit on the last screen would
  otherwise let the next launch past the gate with `managedServer` still off.
  `SetupController.finish` writes `managedServer = true`, records
  `setup = 'done'`, and returns whether both landed — a false answer keeps the
  wizard on the screen with `Setup could not be saved. Try Finish again.`
  rather than handing over an inbox whose setup is not on disk. Only a finish
  that saved asks for the server, FIRE-AND-FORGET on `ServerBootstrap`'s
  reasoning: adopting or spawning a server can take tens of seconds against a
  twenty-seven-billion-parameter model, and the inbox has to open now. It is
  `restart()` rather than `ensureRunning()` when the models folder moved during
  the run — `ensureRunning` returns at once on a server that is already up, and
  the router would go on mmap'ing the copies in the old folder. It never
  throws.
- **`--dart-define=BOND_DEV_SKIP_SETUP=1`** skips the wizard entirely. For the
  three-server `make model | fast | embed` workflow, whose models live in the
  Homebrew cache rather than this app's folder. A define rather than a
  preference because it describes the build; `local.mk` passes it through.
- **"Set up again"** (Settings → Models → Local server) clears `setup_state`
  except `SetupStore.keptOnRestart` — the migration record and the download
  ledger — and bumps the counter the gate watches. The models stay on disk and
  the session stays signed in, so those two steps are a Continue each.

## Failure policy: park, never fall back

- **No fallback between servers.** A down server throws
  `LlmUnavailableException`; `AiWorker` (`app/lib/services/ai_worker.dart`)
  parks only that *kind* of work, and a dead session parks the whole drain.
  Work resumes when the server comes up.
- Per-request timeout, per slot (`llm_client.dart`): **90 s on the prose
  client** (`LlmClient.proseTimeout`), **120 s on the bulk one**. 5xx →
  unavailable/park;
  429 (a throttled cloud server) → unavailable/park as well; timeout →
  counted against the item; HTTP 400 → fatal, never retried — which
  is what a model name the server does not have looks like.
- `TriageQueue` and the FAST `AiWorker` share one `DrainGate`
  (`app/lib/services/drain_gate.dart`) so those two drains never compete for
  the fast server's slots. The storyline and draft lanes hold their own gates
  — see **Three drains** below. The worker's header comment explains handler
  ordering as a data dependency and per-kind vs whole-drain parking.

## Three drains

Since Round C (2026-09) there are three `AiWorker` instances, not one, and
three gates. One list behind one gate meant the 27B's work sat both in front
of the 4B's and behind it: a message that arrived while a recap was being
written waited for the recap, and a draft a person asked for waited for the
whole pass to come round.

| Lane | Kinds, in drain order | Server(s) | Gate | Provider |
|---|---|---|---|---|
| Fast | `needs_you`, `extract`, `embed_message`, `attachment_text`, `attachment_digest`, `context_reconcile`, `context_digest`, `context_brief` | fast + embed | `fastDrainGateProvider`, shared with `TriageQueue` | `aiWorkerProvider` |
| Storyline | `storyline`, `storyline_sweep`, `storyline_refresh`, `storyline_audit`, `storyline_recruit`, `storyline_recap` | fast (membership) + prose (naming, refresh, recap) | `storylineDrainGateProvider` | `storylineWorkerProvider` |
| Draft | `draft` | prose | `draftDrainGateProvider` | `draftWorkerProvider` |

The cut is where the constraints are, not where the servers are. The fast lane
is the critical path for a new message and holds nothing that dials the 27B.
Its own load on the fast server is one kind at a time at K=3 — needs-you, then
extraction — and the gate it shares with the triage drain is what stops that
K=3 landing on top of triage's. The fourth slot is the STORYLINE lane's: it is
on a gate of its own, and its membership confirms are fast-server calls, so the
worst case at that server is three plus one, which is `FAST_SLOTS`.
The storyline six stay together because their ORDER is an argument
(`06-storylines.md`) and they mutate shared membership — splitting them by
server would break it. The draft is alone because it is the one kind a person
sits and waits for. Where the two prose lanes genuinely contend the SERVER
queues them, so the worst case for an asked-for draft is one recap rather than
a drain pass.

**Order across lanes is enqueue-and-pump, not list position.** A fast handler
writes the `storyline*` or `draft` row and something wakes the lane that owns
it: `AiWorker.onDrained` fires after every completed drain, empty ones
included (the fast lane wakes the other two; the storyline lane wakes the
draft lane), and `ExtractHandler.onDraftQueued` wakes the draft lane as each
row is written, so a prefetch starts seconds after its extraction rather than
at the end of the fast drain. The fast lane also re-arms the storyline sweep
through `MessageStore.requeueSweep()` before it wakes that lane, and only after
a drain whose `AiWorker.lastDrainCount` is above zero, so a settled fast lane is
what schedules the sweep and an idle pump schedules nothing.
`AiWorkers.pumpAll()` — fast, THEN the other two
together — is what a caller outside the pipeline pumps, and its chained shape
is what keeps "the sync's pump completed" meaning "and the drafts are done".

**How wide the draft lane runs is a setting.** `AppPrefs.proseParallel`
(`prose_parallel`, 1–8, default 1) is read by `DraftHandler.concurrency`
through a closure, and `AiWorker` re-reads that on every launch decision — so
Settings → Models → **Drafts in flight** moves the next draft rather than the
next launch. One per slot the prose server was started with (`SLOTS` in
`local.mk`, `--max-num-seqs` on vLLM); extra requests queue at the server
rather than fail. Drafts only: a recap and a refresh both write the storyline
they are about and stay at one. Measured 2026-09-17: a second local slot on
this Mac's 27B did not pay (width 2 slower end to end than width 1); the
default stays 1 locally, and 4 is the measured value for a GPU-served target.

**Two writers ride the storyline gate** because the single gate used to
serialise them by accident:

- `GateRepairService.afterGate` is called from inside the triage drain. Its
  message-side writes stay awaited; its three storyline writes
  (`evictGatedThread`, `clearConversationEmbedding`,
  `deletePendingWork('storyline', …)`) go through the storyline lane's gate,
  unawaited, and write their own activity row when they land. The sharp one is
  the delete: landing while the lane holds that row's claim it would miss it,
  and the assign pass would file the thread straight back after the eviction.
- `ContextBriefHandler.onBriefChanged` → `StorylineService
  .offerDirectoryCharters` writes `charterSuggestion`, and the refresh pass
  writes the same column. The offer is dispatched onto the storyline gate,
  unawaited — so the brief handler (fast lane) never waits on a sweep, and the
  activity row for a brief no longer carries `charters_offered`.

The one-shot `GateRepairService.repairAll` stays inline: it runs once per
install, from the sync, before the storylines it would race have anything to
do.

`make bench-pipeline` measures both shapes — `PIPE_SHAPE=single` is the
pre-Round-C single worker, `lanes` is what ships. See `docs/model-bakeoff.md`.

## Every prompt is fenced

Every task's system prompt is `rules + untrustedDataClause`
(`app/lib/services/llm/prompt_guard.dart`), and all sender-supplied text is
wrapped by `wrapUntrusted` with `&`-first escaping so a message body cannot
forge a closing tag. A new task must compose its prompt the same way — no
raw interpolation of message content into a prompt, ever.

## Task plumbing

Every chat task implements `JsonTask` (`app/lib/services/llm/json_task.dart`):
a schema-constrained call whose defaults are temperature 0.2 / maxTokens 512,
overridden per call site (see each stage's page). Decoding is
grammar-constrained; `make bench-verify` asserts the server honours the
schema before any bench run trusts it. `runTask(onText:)` is what picks the
streamed method instead of the plain one, and `DraftHandler` is the only caller
in `lib/` that passes it — every other stage, every test double and every bench
goes through `completeJson` unchanged.

**The two timeouts are one number each, sized to the longest legitimate call
on that slot.** The prose client gets 90 s, and there are two worst cases to
clear. An ordinary directory-fed draft with every input at its cap is about
14K characters of prompt, prefilling in roughly 26 s, plus 768 generated
tokens in roughly 43 s with speculative decoding: 69 s. A draft whose pack
expanded a section is larger — the passages take their 8,700 ceiling and the
storyline summary its 600 — about 20K characters, roughly 5K tokens, so
roughly 37 s of prefill and the same 43 s of generation: about 80 s. Both fit
under 90, with about ten seconds of headroom on the expanded case, and 60
would cut BOTH off mid-sentence. The fast client keeps the generic 120: its
calls answer in seconds, so the number only ever describes how long a dead
server is waited on, and there is nothing to be gained by tightening it. The
bench clients pass no timeout at all and so inherit that same 120
(`app/test/fixtures/bench_target.dart`), which is deliberate: a prose bench
can pass where the app itself would have given up at 90, and a candidate
runtime slower than the app's ceiling shows up as a p50 above about 90 s in
the table rather than as a failed run.
