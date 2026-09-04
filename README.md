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
3. **UI** — `app/`, a Flutter desktop app: a Microsoft-signed-in inbox of
   Outlook mail and Teams chats, read and ranked by the model on layer 1. See
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

A Flutter macOS app: sign in, and a live Outlook inbox threaded into
conversations, each one read and annotated by the local model. `make app-run`
starts it.

**Signing in takes one line of setup, if your workspace already uses
bond-mcps.** Put the platform's URL in your `MS_ENV` file
(`BOND_MCP_SERVER_URL=…`), `make app-run`, then **Sign in** — the same login
Claude Code uses for the platform — and the mail starts arriving. Where that
mail comes from is a choice between two backends, and only the other one needs
an Azure app registration on this machine: see
[Microsoft backends](#microsoft-backends) below.

**Three model servers, all optional.** `make model` is the main chat model on
`:8080` — the careful reader that names storylines and writes draft replies.
`make fast` is a much smaller model on `:8082` that does the bulk per-message
work — triage and extraction — in seconds rather than tens of seconds, with
several requests in flight at once. `make embed` is a third llama-server on
`:8081` running `embeddinggemma-300M`, which is what turns conversations into
vectors so they can be clustered — it needs its own process because
`--embeddings` puts a server in embedding mode and one server cannot both chat
and embed. With none of them running the inbox works fine and simply stays
un-annotated; each missing server parks only the work that needs it, and the
work resumes when the server comes up.

Nothing about the mail ever leaves the machine at inference time. Both servers
are local, and the only network calls the app makes are the ones that fetch the
mail in the first place — to Microsoft Graph, or to the Bond server that holds
the Microsoft grant on your behalf.

The left rail has four sections:

**Needs You** ranks what the signed-in user is actually on the hook for. Every open thread
gets an attention score from its state, how recently it moved, what the model
found in it, and how often that sender gets answered; a slider in Settings sets
how high a thread must score to appear. Threads awaiting a reply come first,
then threads waiting on somebody else, dimmed.

**Storylines** are groups of threads about the same thing — one project, one
trip, one event — proposed by the model and kept or dismissed by the user. A
clustering sweep compares conversation embeddings, a confirmation call decides
whether a candidate really belongs, and the result opens as a single merged
transcript with a chip at each seam naming the thread it just crossed into.
Removing a thread by hand blocks it, so the model cannot put it straight back.

**Later** is where low-value mail goes instead of the inbox. The model's read of
a message decides it, a standing per-sender rule overrides that, and an explicit
"keep this in my inbox" overrides both — nothing automatic ever overturns a
person. It is grouped by day and nothing is hidden: the rail shows a count per
day and one click opens all of it.

**Drafts** are suggested replies. Threads that need an answer and score high
enough get one written in the background, shown above the reply box with the
model's own sentence about what it drew on. Nothing sends on its own: a draft is
text in a box until somebody presses Send, and what gets sent is what is on
screen. Depending on what the tenant granted, Send either sends, saves to
Outlook Drafts, or copies to the clipboard.

Triage's cheap gates (the user's own address, no-reply senders, list and
auto-generated headers) skip what is not worth a model call; the rest go through
one at a time, newest first. First run syncs 14 days of mail and queues the
newest 7 days for triage, capped at 150 messages. On the fast server that
backlog annotates itself in a few minutes, in the background, with a
`Triaging N remaining…` counter in the rail. It survives a restart: work in
flight is re-queued at the next launch.

### Microsoft backends

Where the Microsoft data comes from is a choice, made under Settings →
Microsoft connection, and nothing above it changes: the same inbox, the same
triage, the same storylines and drafts either way.

**Bond server**, the default. The app talks to the bond-mcps platform over MCP,
and the platform holds the Microsoft grant server-side. Nothing Microsoft-shaped
has to exist on this machine — no app registration, no secret, no consent
prompt of its own.

**This Mac.** The app holds the grant itself and calls Microsoft Graph directly
from the machine.

**The zero-config path.** `make app-run` with nothing configured talks to a
local bond-mcps server (`http://localhost:18001/mcp`) and signs in with no
browser round at all. To reach a deployed platform instead, add one line to
your `MS_ENV` file — `BOND_MCP_SERVER_URL=https://…/mcp` — and that endpoint
becomes the **Deployed** preset and the default; sign in with your bond-mcps
login and, if the workspace already has a Microsoft connection, the inbox
syncs straight away. The **Connect your Microsoft account** step appears only
for a workspace that has never connected one: it hands you off to the
platform's own consent page, and the app picks the connection up when you come
back — on its own when the window regains focus, or on
**I've connected — continue**.

**Which server.** The **Bond server** dropdown offers **Deployed** (the
`BOND_MCP_SERVER_URL` endpoint, when the build carries one), **Local** —
`http://localhost:18001/mcp` — and **Custom…** for anything else. The deployed
hostname deliberately never appears in this repository: which cluster a
company runs is environment configuration, and it rides the same git-ignored
`MS_ENV` file as the Azure ids.

**Switching servers.** Every backend and server keeps its own session, so
switching never costs a sign-out. Pick the target in Settings and the dialog
says whether you are signed in to it; **Sign in…** and **Sign out of this
server** act right there, in place, and the permission rows re-answer for
whatever is selected. Nothing changes behind the dialog until you act — the
app's own sign-in screen appears only at launch, when the current target has
no session yet.

**Working against a local server.** Start bond-mcps with its own `make dev`,
then Settings → Bond server → **Local**, and sign in. The local server asks for
no token at all, so that sign-in is instant — no browser round trip.

**An Azure app registration is needed only by "This Mac".** The client id,
tenant id and (for a registration without a public-client platform) client
secret are never committed; `make app-run` / `make app-build` read them from a
dotenv-style file and pass them as `--dart-define`s. Point `MS_ENV` at any file
carrying `MICROSOFT_CLIENT_ID`, `MICROSOFT_TENANT_ID` and
`MICROSOFT_CLIENT_SECRET` lines — the default is a git-ignored `.env` next to
the `Makefile`, and a git-ignored `local.mk` can pin `MS_ENV` somewhere else
permanently. A build made without them runs fine and is unaffected in Bond
server mode; it is the **This Mac** sign-in that refuses, with a message naming
exactly these defines. A build made **with** the secret carries it in the
binary — do not distribute one.

### Microsoft Teams

Teams **chats** — 1:1 and group — flow into the same conversations, the same
state machine and the same Needs You / Later ranking as mail, marked with a 💬
on the row. Pills at the foot of the rail switch between **All**, **✉ Mail** and
**💬 Teams**.

**Channel messages are out of scope.** Reading a team's channels needs
tenant-wide admin consent this app does not ask for; chats need only the
delegated `Chat.Read`. At a tenant that admin-gates `Chat.Read` (this one
does, as of 2026-08-30) the sign-in leaves it out entirely — one admin-gated
scope in the bundle walls off the whole request — and Teams features report
themselves unavailable until the admin approves the app.

**Teams refreshes only when you ask it to.** Microsoft's terms for the Teams
messaging endpoints forbid polling them in the background, so the sixty-second
timer that keeps mail current does not touch them. A chat pull happens when you
press Refresh, when the app launches, and when the window comes back to the
front after ten minutes or more. The rail says how long ago that was.

**Replies are email-only.** A Teams thread shows "Reply in Microsoft Teams"
where the composer would be, and a storyline's reply dropdown offers its mail
threads only — Graph builds a mail reply for this app from the message being
answered, and there is no equivalent for a chat.

**Consent degrades quietly.** The sign-in asks for everything it can use in
one round: `Mail.Read`, `User.Read`, `offline_access`, plus `Mail.ReadWrite`
and `Mail.Send` (`Chat.Read` sits out while the tenant admin-gates it — see
above). A tenant that refuses the extended scopes leaves a perfectly usable
session — the sign-in retries with the core three — and each feature that
needed one reports itself unavailable rather than broken. Without `Chat.Read`
the Teams pill is present but disabled with a tooltip pointing at Settings,
and the app makes no Teams request at all.

## Operations

```sh
make status                 # up/down + pid
make logs                   # tail the server log
make stop                   # stop the chat server on :8080
make embed                  # start the embedding server on :8081
make embed-stop             # stop it
make fast                   # start the bulk-work model server on :8082
make fast-stop              # stop it
make verify                 # SHA256 the downloaded weights (~1 min)
make clean-model            # delete the cache, forcing a re-download
make clean                  # rm tmp/logs
make app-run                # the desktop inbox
make app-test               # its test suite
make app-analyze            # its analyzer
```

`make stop` deliberately kills by PORT and never by process name: `make embed`
is a second `llama-server`, and a name-based kill would take the embedding
server down every time someone stopped the chat one.

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
- `FAST_LLAMA_URL` and `EMBED_URL` — the same, for the bulk-work server
  (`:8082`) and the embedding server (`:8081`).
- `LLAMA_MODEL` and `FAST_LLAMA_MODEL` — the model name each request carries.
  `llama-server` ignores it and serves whatever it loaded; an MLX-based server
  routes on it, so a runtime holding several models needs it set.
- All five are passed through by `make app-run` and `make app-build` only when
  you set them: `make app-run FAST_LLAMA_URL=http://localhost:9000/v1/chat/completions`.
  Unset means the app's own defaults, which is not the same as empty.
- `MODEL_PORT` and `CTX_SIZE` are overridable per invocation:
  `make model CTX_SIZE=65536`, `make model MODEL_PORT=8081`.
- `SETUP_WAIT` — how long `make setup` polls for `/health`. Default 1800s.

### Benchmarks

```sh
make bench-verify           # does a target uphold the contract? (bulk slot)
make bench-verify-prose     # the same, for the prose slot
make bench                  # the corpus through triage + extraction, timed
make bench-prose            # storyline names + drafted replies, verbatim
make ab                     # the same corpus on both servers, compared
make ab-membership          # the membership eval set on both servers
make drain                  # the drain concurrency race (needs FAST_SLOTS=4)
make bench-compare A=… B=…  # diff two runs
```

Each of these is live and none is a gate: they need a server up, print tables
rather than assert on judgements, and stay out of `make app-test`.

`bench-verify` is the exception, and it runs first from every target above.
It asks the questions `curl /health` cannot: does this server accept the
request body the app sends, does it honour a JSON schema, is decoding actually
constrained, does it report the token counts a throughput number is divided by?
None of those is a judgement — they are facts about how a server was
configured, and getting one wrong is an adoption disqualifier rather than a
nuance, because the queues treat an HTTP 400 as fatal and drop the message.
`BENCH_VERIFY=0` skips it.

A bench points wherever you tell it, so trying a candidate runtime is one
command and no code edit. `BENCH_*` is the bulk slot (triage, extraction,
membership); `PROSE_*` is the drafting slot `make bench-prose` and the A/B use:

```sh
make bench BENCH_URL=http://localhost:9000/v1/chat/completions \
           BENCH_LABEL=omlx/qwen3-4b-4bit BENCH_MODEL=qwen3-4b
```

Every run writes a JSON result to `BENCH_OUT` (default `tmp/bench/`), named for
the bench, the label and the time. `make bench-compare A=<a.json> B=<b.json>`
diffs two of them — latency, generation rate, and where accuracy moved — which
is the only way to compare a candidate against a run from last week, since
scrollback does not survive the meeting. `BENCH_WARMUP` (default 1) discards
that many calls before the clock starts; `BENCH_THINK=1` prints the reasoning
tripwire instead of failing on it, for candidates with no thinking switch.

Two more knobs:

- `BENCH_VERIFY` (default 1) — run the contract check before the bench. Set to
  0 for a server already verified this session, or to watch a failing candidate
  behave rather than be stopped at the door.
- `BENCH_K` (default `1,3`) — which concurrencies `make drain` races, in order.
  `make drain BENCH_K=1,3,6` needs the server started with at least six slots
  (`make fast FAST_SLOTS=6`); past the slot count the extra requests queue on
  the server rather than batch, and the round measures queue-wait dressed up as
  throughput.

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
  lib/services/   Graph auth, the mail and Teams syncs, the gates and queues
  lib/services/backend/  the two backends' shared interfaces
  lib/services/mcp/  the Bond-server backend: MCP client, sign-in, reshapes
  lib/services/llm/  the local-model client, prompts and validators
  lib/providers/  the read models the screens watch
  lib/screens/    inbox and sign-in
  lib/widgets/    rail, thread list, transcript, composer, chips
  lib/theme/      the design tokens every widget draws from
  test/           unit tests; llm_live_test.dart needs a running model
tmp/logs/         runtime logs; make clean removes it, keep it out of git
```

Model weights live in `~/.cache/huggingface/hub/`, deliberately outside the
repo.
