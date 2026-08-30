# bond-desktop

A proof of concept for running a capable LLM entirely on a Mac, with no network
call leaving the machine at inference time.

There are three layers, two of which exist today:

1. **Model server** — [llama.cpp](https://github.com/ggml-org/llama.cpp)'s
   `llama-server`, which exposes an OpenAI-compatible HTTP API on `:8080`.
   Installed from Homebrew; the `Makefile` owns its lifecycle.
2. **Agent** — `agent/bin/chat.dart`, a minimal Dart tool-calling loop: it
   POSTs a conversation plus a list of tool schemas, executes whatever tool
   calls come back, feeds the results in, and repeats until the model answers
   without asking for a tool. This is the seam where an MCP client plugs in
   later — register handlers in `toolHandlers` and their JSON schemas in
   `toolSchemas` and the loop itself needs no changes.
3. **UI** — `app/`, a Flutter desktop app: a Microsoft-signed-in Outlook inbox
   whose mail is triaged by the model on layer 1. See
   [The desktop inbox](#the-desktop-inbox-app).

The point of the POC is layer 2: proving that a local model reliably emits
well-formed OpenAI `tool_calls` and can be driven in a loop, which is the
prerequisite for everything else.

## The model

Qwen 3.8 27B, Q4_K_M quantization, from the official
[`ggml-org/Qwen3.8-27B-GGUF`](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF)
repo on Hugging Face. Apache 2 licensed.

Two files get pulled: ~19GB of weights (`Qwen3.8-27B-Q4_K_M.gguf`) and a
~630MB multimodal projector (`mmproj-Qwen3.8-27B-Q8_0.gguf`) that gives the
model vision. Both are downloaded automatically by `llama-server`'s `-hf` flag
into `~/.cache/huggingface/hub/` the first time you run `make model` — nothing
model-sized ever lands in this repo, and `make clean` never touches them.

The model's native context is 262K tokens. The `Makefile` caps it at 32K
(`CTX_SIZE`) because the KV cache is what actually costs RAM at runtime; 32K
is roughly 2GB of cache and leaves headroom on a 64GB machine. Raise it when a
workload needs it.

## Requirements

- Apple Silicon Mac. Every layer is offloaded to Metal (`-ngl 99`).
- 32GB RAM or more recommended. Verified on an M1 Max with 64GB.
- ~20GB free disk for the weights.
- [Homebrew](https://brew.sh), for `llama.cpp`.
- Dart SDK on `PATH`. If you have Flutter installed you already have it.

## Quickstart

```sh
make setup
make chat
```

`make setup` installs the dependencies, starts the model server, waits for it
to answer `/health`, verifies the download's SHA256, and runs a smoke test
against the live server. It is idempotent — re-running it on an already-running
server just re-verifies and re-smokes.

**The first run downloads ~19GB and takes about ten minutes on fast internet.**
`setup` waits up to 30 minutes (`SETUP_WAIT`) and prints an elapsed-time
heartbeat every 60 seconds so you can tell it is still alive. It will not
report success until the weights have been hashed and the model has answered a
real prompt.

## Step by step

If you would rather drive it manually, or `make setup` failed somewhere and you
want to see which stage:

```sh
make install      # brew install llama.cpp, dart pub get in agent/
make model        # start llama-server on :8080
make status       # [up]/[down] + pid
make logs         # tail tmp/logs/model.log (Ctrl-C to stop tailing)
make smoke        # one chat completion — proves the server answers
make smoke-tools  # proves the model emits OpenAI tool_calls, not prose
make chat         # interactive agent, foreground
```

One thing to know about `make model` on a first run: it launches the server and
then waits 120 seconds for the port to bind. The port will not bind in 120
seconds, because the download has not finished. You will see this, and it exits
non-zero:

```
  ! model has not bound :8080 after 120s
    On the FIRST run this is EXPECTED, not a failure: llama-server
    downloads ~19GB of weights for ggml-org/Qwen3.8-27B-GGUF:Q4_K_M
    before it binds the port.
    Watch it:   make logs
    'make status' flips to [up] once loading finishes.
```

Nothing has gone wrong. The download continues in the background. Watch
`make logs`, and `make status` flips to `[up]` when the model has loaded.
(`make setup` handles this for you — it ignores that exit code and polls
`/health` instead.)

`make smoke-tools` is a gate, not a demo: it exits non-zero if the model
answers the question in prose instead of emitting a `tool_calls` block. Tool
calling depends on `llama-server`'s `--jinja` flag, which the `model` target
passes so the model's own chat template is used.

## Trying it out

Things worth asking in `make chat`, which has two tools registered
(`get_current_time` and `list_directory`):

- `what time is it?` — single tool call, then an answer.
- `what's in my home directory?` — tool call with an argument.
- `what time is it, and what's in ~/projects?` — two tool calls in one turn,
  which is the interesting case: the loop has to execute both and feed both
  results back before the model answers.
- `write me a haiku about a laptop fan` — no tool call at all. Worth checking:
  a model that reaches for a tool on every turn is as broken as one that never
  does.

You will see a `[tool] name({"args": ...})` line for each call the model makes,
so you can watch the loop work.

Raw HTTP, bypassing the Dart client entirely:

```sh
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3.8",
    "messages": [{"role": "user", "content": "Explain mmap in two sentences."}],
    "reasoning_effort": "low",
    "max_tokens": 256
  }' | python3 -m json.tool
```

`reasoning_effort` is worth knowing about: Qwen 3.8 is a reasoning model, and
left to itself it will spend a long preamble thinking before it answers.
`"low"` keeps short answers short. The `model` field is not meaningfully
checked — `llama-server` serves whatever single model it was started with.

There is also a web UI built into `llama-server` at <http://localhost:8080>.
It supports drag-and-drop images, which is how to exercise the vision side —
that is what the mmproj file is for.

## The desktop inbox (app/)

A Flutter macOS app: sign in with Microsoft, and a live Outlook inbox threaded
into conversations, each one annotated by the local model. `make app-run`
starts it. Triage additionally needs `make model` running — without it the
inbox works fine and simply stays un-annotated.

The list is filtered by five pills: **Open**, **Needs action**, **Needs
reply**, **Waiting**, **Done**. *Needs action* is the model's view rather than
the thread state machine's — it shows the threads triage left a concrete ask
on, cutting across the others.

Triage runs 100% locally: every email is classified by `llama-server` on
`:8080` and nothing about the mail leaves the machine. Cheap gates (the user's
own address, no-reply senders, list and auto-generated headers) skip what is
not worth a model call; the rest go through one at a time, newest first.

First run syncs 14 days of mail and queues the newest 7 days for triage, capped
at 150 messages. At roughly 17 seconds an email that backlog annotates itself
over about 45 minutes, in the background, with a `Triaging N remaining…`
counter in the header. It survives a restart: work in flight is re-queued at
the next launch.

## Operations

```sh
make status                 # up/down + pid
make logs                   # tail the server log
make stop                   # stop the server on :8080
make verify                 # SHA256 the downloaded weights (~1 min)
make clean-model            # delete the cache, forcing a re-download
make clean                  # rm tmp/logs
```

`make verify` is cheap insurance. The Hugging Face cache is content-addressed:
every file in `blobs/` is named by its own SHA256, so the expected hash is the
filename and no network access is needed to check it. Hashing ~19GB takes about
a minute. You want this after any interrupted or suspicious download — see
troubleshooting below for why.

`make clean-model` refuses to run while `llama-server` is alive. The weights
are memory-mapped, so deleting them under a live server unlinks the directory
entries while the process keeps the inodes pinned: the disk stays consumed
until it exits, and a fresh download racing the still-open old file is a good
way to manufacture exactly the corruption `make verify` exists to catch. Run
`make stop` first.

Knobs:

- `LLAMA_URL` — read by the Dart client, full URL of the completions endpoint.
  Defaults to `http://localhost:8080/v1/chat/completions`. Point it at another
  port or another machine.
- `MODEL_PORT` and `CTX_SIZE` are overridable per invocation:
  `make model CTX_SIZE=65536`, `make model MODEL_PORT=8081`.
- `SETUP_WAIT` — how long `make setup` polls for `/health`. Default 1800s.

## Performance

Measured on an M1 Max, 64GB, with the Q4_K_M quantization at 32K context:

- **Generation: ~12 tokens/sec.** Steady, and the number that governs how long
  you wait for an answer.
- **Prompt prefill: 90–126 tokens/sec** on prompts of a few hundred tokens.
  Very short prompts measure lower because fixed overhead dominates.
- **A short completion takes about 7 seconds** end to end.

Fast enough to be useful for tool-driving and interactive work; not fast enough
to feel like a hosted frontier model. Plan accordingly.

## Troubleshooting

**Activity Monitor shows `llama-server` using only ~5GB. Did it load the whole
model?** Yes. The weights are `mmap`'d, so they are file-backed pages that macOS
accounts under *Cached Files*, not under the process's memory footprint. The
real working set is roughly 24GB — ~19GB of weights plus the KV cache and
runtime overhead. Watch the *Cached Files* figure, or just believe `make verify`
and the token throughput.

**The output is garbage — endless repeated `0`s, or it never stops
generating.** That is a corrupt download, and it is sneaky, because every cheap
check passes: the file is full length, `llama-server` loads it without an
error, the port binds, `/health` returns 200. Only the hash catches it. Run:

```sh
make verify
make stop && make clean-model && make model
```

**The model says it is Claude, or insists it is not running locally.** This is
training-data identity bleed, and it is harmless — Qwen has clearly seen a lot
of assistant transcripts. It will happily tell you it is "running on Anthropic's
infrastructure" while running on your laptop with the network off. Do not use
self-report prompts as a health check; use `make status`, `make smoke-tools`,
and the log.

**Port 8080 is busy.** `make model` deliberately refuses to reuse a port held by
anything that is not a `llama-server` — it prints the offending pid and command
rather than assuming the listener is ours. Either free the port or move:

```sh
make model MODEL_PORT=8081
LLAMA_URL=http://localhost:8081/v1/chat/completions make chat
```

The `Makefile` header lists the sibling stacks on this machine and the ports
they occupy, so you can tell a collision from a stray process.

## Layout

```
Makefile          everything: install, model lifecycle, smoke tests, verify
agent/            Dart package
  bin/chat.dart   the tool-calling loop — the whole agent, one file
  pubspec.yaml    one dependency: package:http
app/              Flutter macOS app — the desktop inbox
  lib/data/       sqlite schema and every SQL statement in the app
  lib/services/   Graph auth + mail sync, the triage gates and queue
  lib/services/llm/  the local-model client, prompts and validators
  lib/screens/    inbox and sign-in
  lib/widgets/    thread list, transcript, chips
  test/           unit tests; llm_live_test.dart needs a running model
tmp/logs/         runtime logs; make clean removes it, keep it out of git
```

Model weights live in `~/.cache/huggingface/hub/`, deliberately outside the
repo.
