# The model bakeoff

The app runs two model slots: a **bulk** slot that does triage, extraction and
storyline membership, and a **prose** slot that names storylines and drafts
replies. Both are served locally, and both are choices rather than
conclusions — a different model or a different runtime could be faster, more
accurate, or cheaper in RAM, and until it is measured nobody knows which. The
bakeoff is the apparatus for measuring it: accuracy, throughput (tokens/sec)
and latency for each slot, with every candidate benched by one command against
the same corpus and the same real task prompts, so adopting a winner is a
config change rather than a rewrite.

## How a run works

Every bench lives in `app/test/` behind `@Skip`, so `make app-test` never
depends on a server being up, and each `make` target below runs it with
`--run-skipped` plus the `--dart-define`s that point it somewhere.

| Target | What it measures |
| --- | --- |
| `make bench` | The bulk slot: the fixture corpus through triage and extraction, with a latency and throughput table. |
| `make bench-prose` | The prose slot: five storylines named and five replies drafted, printed verbatim. No scorecard — a title and a draft are judged by reading them. |
| `make ab` | The same corpus through triage and extraction on **both** slots, printing where they disagree and what each cost. |
| `make ab-membership` | The membership eval set through the confirm task on both slots, against the answer a person would give. |
| `make drain` | The drain concurrency race: one round per concurrency in `BENCH_K` over the same backlog. The only bench that can see batching. |
| `make bench-verify` | Not a measurement — a contract check. See "Protocol". |

The knobs, all `?=` in the `Makefile` and all overridable on the command line
(or durably in a git-ignored `local.mk`):

- `BENCH_URL`, `BENCH_LABEL`, `BENCH_MODEL` — where the **bulk** slot points,
  what the run is called, and the `model` field in the request body.
  `BENCH_MODEL` is ignored by llama-server and load-bearing for a multi-model
  server like oMLX.
- `PROSE_URL`, `PROSE_LABEL`, `PROSE_MODEL` — the same three for the **prose**
  slot.
- `BENCH_OUT` — where result JSON lands. Defaults to `tmp/bench/`, which is
  git-ignored: results are data, this document is the record.
- `BENCH_WARMUP` — discarded calls before the clock starts (default 1).
- `BENCH_THINK` — `1` for a candidate that always reasons.
- `BENCH_VERIFY` — `0` skips the contract check that otherwise runs before
  every bench.
- `BENCH_K` — the concurrencies `make drain` races, in order (e.g. `1,3,6`).

Name the weights in a label, not just the runtime: two quantizations of one
model otherwise produce two identical-looking tables. Once two runs have
written their JSON, `make bench-compare A=<a.json> B=<b.json>` turns them into
a diff.

## Protocol

Follow this or the numbers are decoration.

1. **`bench-verify` must pass first.** It runs automatically before every
   bench (set `BENCH_VERIFY=0` to skip). It replaces the `curl /health` guard
   the benches used to open with, which answered a question nobody was asking:
   `/health` says a process is listening and nothing about whether it accepts
   this app's request body, honours a JSON schema, actually constrains
   decoding, or reports the token counts a throughput number is divided by. A
   candidate that fails it is not slow, it is wrong, and its numbers mean
   nothing.
2. **Warm up.** `BENCH_WARMUP` handles this automatically, and it matters more
   than it sounds: llama.cpp measured 6.8 tok/s cold against 130 warm on this
   machine, and one cold call in a small sample replaces the median rather
   than nudging it.
3. **Run each row twice and keep the second.** Caches — the OS page cache, the
   server's prompt cache, and for oMLX the resident-model LRU — make a first
   run a measurement of loading.
4. **Nothing else heavy running.** Another model server mid-download, a build,
   or a `flutter test` sweep all show up in the numbers.
5. **Give the server enough concurrency.** `make drain` needs the serving side
   started with at least `max(BENCH_K)` slots — `FAST_SLOTS` for llama.cpp,
   `OMLX_SLOTS` for oMLX — or the high rounds measure queue-wait instead of
   batching, which is the opposite of the thing being measured.
6. **`BENCH_THINK=1` only for always-reasoning candidates**, such as an
   R1 distill that has no `enable_thinking` to honour. It stops the harness
   sending `enable_thinking: false` and relaxes the reasoning-leak gate to a
   printed count. The resulting numbers honestly include the cost of the
   reasoning tokens, which is the point: that cost is what the app would pay.

## oMLX

[oMLX](https://github.com/jundot/omlx) is an MLX-based OpenAI-compatible
server — the candidate runtime against llama.cpp, on Apple's own inference
stack.

### Install

```sh
brew tap jundot/omlx https://github.com/jundot/omlx
brew install jundot/omlx/omlx
brew reinstall omlx --with-grammar
```

The third line is not optional for this repo. `--with-grammar` pulls in
xgrammar, which is what makes `response_format: json_schema` a real decoding
constraint; every call the app makes is schema-constrained, so a server
without it is not serving the same workload.

### The xgrammar library-path workaround

Installing xgrammar is necessary but not sufficient. Homebrew's
`--with-grammar` build pairs xgrammar 0.2.3 with a `tvm_ffi` whose dylib
search covers tvm_ffi's own directories plus `DYLD_LIBRARY_PATH`/`PATH` — and
never the xgrammar package directory where `libxgrammar_bindings.dylib`
actually lives. That dylib in turn needs `libtvm_ffi.dylib` from
`tvm_ffi/lib`. Both directories have to be on `DYLD_LIBRARY_PATH` for the
import to succeed:

```
/opt/homebrew/opt/omlx/libexec/lib/python3.11/site-packages/xgrammar
/opt/homebrew/opt/omlx/libexec/lib/python3.11/site-packages/tvm_ffi/lib
```

(`python3.11` is pinned by the formula's own venv.) The `Makefile` carries
this as `OMLX_XG_LIBS` and `make omlx` applies it, so nothing here is manual —
but know the symptom, because it is silent. Without the path, oMLX does not
crash and does not warn: it falls back to asking for the schema in the prompt.
Output still looks like JSON and is no longer constrained. `make bench-verify`
catches it with an enum probe — a prompt that begs for a value outside the
enum, which a constrained decoder cannot produce and a prompt-injected one
will happily hand over.

One more wrinkle worth knowing if you launch oMLX by hand: the environment
assignment has to ride inside the command as `env DYLD_LIBRARY_PATH=... omlx
serve ...`. `nohup VAR=x cmd` treats the assignment as the command name, and
an *exported* `DYLD_*` variable is stripped by SIP when `make` execs
`/bin/sh`. Passing it to `env` as an argv word, which then execs the
unprotected Homebrew python, survives both.

### Models

oMLX does not download anything. It discovers models already present in
`--model-dir` (default `~/.omlx/models`) and in the HuggingFace cache, so pull
weights first with the `hf` CLI inside the formula's venv:

```sh
/opt/homebrew/opt/omlx/libexec/bin/hf download mlx-community/Qwen3-4B-Instruct-2507-4bit
```

The **serving id** is the HuggingFace *cache directory* name, which is the
repo id with the slash turned into a double dash:

| Repo | `model` field to send |
| --- | --- |
| `mlx-community/Qwen3-4B-Instruct-2507-4bit` | `mlx-community--Qwen3-4B-Instruct-2507-4bit` |
| `mlx-community/Qwen3-4B-Instruct-2507-8bit` | `mlx-community--Qwen3-4B-Instruct-2507-8bit` |
| `mlx-community/Qwen3.8-27B-4bit` | `mlx-community--Qwen3.8-27B-4bit` |

The server log prints a `Discovered model: …` line per model at startup, which
is the authoritative list when a name is in doubt.

### One server, both slots

oMLX is multi-model: there is no `--model` flag, and the request body's
`model` field routes. So the bakeoff runs **one** oMLX process on `:8090`
serving both slots, rather than the two ports an earlier sketch assumed. An
LRU keeps models resident, and `OMLX_GUARD_GB` (24 by default) is sized so the
4B and the 27B can be resident together — the `balanced` memory-guard tier
picked a 14.0GB ceiling on this 64GB M1 Max, which refuses the ~15GB 27B-4bit
outright, so an explicit ceiling replaces the tier. The first call after a
model swap still pays a load cost; the warmup absorbs it, which is another
reason not to trust a first run.

### Lifecycle

```sh
make omlx        # start on OMLX_PORT, default :8090
make omlx-stop   # stop it
make status      # now has an omlx row alongside model/embed/fast
```

Startup takes roughly 70 seconds, and the TCP port binds almost immediately —
uvicorn binds, then the app keeps starting. `_wait-omlx` therefore polls
`/v1/models` for HTTP 200 rather than watching for the port to bind, because a
bench started against a bound-but-unready server collects connection-level
503s and calls them the candidate's numbers.

### Timing

oMLX serves `/v1/chat/completions` and returns a `usage` block, but not
llama-server's `timings` block. The harness falls back to wall-clock
tokens/sec, and every result records a `timing_source` so a table never
silently mixes the two. Wall-clock is the more pessimistic and more honest of
the two anyway — it includes the queueing and serialization a user waits
through.

## Run matrix

Each row is one run. Restart requirements are noted where a row needs the
server started differently from the default.

| # | Slot | Candidate | Commands |
| --- | --- | --- | --- |
| 1 | bulk | **baseline** — llama.cpp, Qwen3-4B-Instruct Q8_0, `:8082` | `make fast-stop && make fast FAST_SLOTS=6` (the default 4 is below `max(K)=6`), then `make bench` and `make drain BENCH_K=1,3,6` |
| 2 | prose | **baseline** — llama.cpp, Qwen3.8-27B Q4_K_M, `:8080` | `make bench-prose` and `make ab` |
| 3 | prose | llama.cpp, unsloth `UD-Q4_K_XL`, `:8083` | `make model MODEL_PORT=8083 MODEL_HF=unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL`, then `make bench-prose PROSE_URL=http://localhost:8083/v1/chat/completions PROSE_LABEL='llamacpp/Qwen3.8-27B-UD-Q4_K_XL'` — 17.9GB, so run it alongside the baseline only if RAM allows, else `make stop` first. llama-server binds its port while still loading and answers 503 until it finishes; `bench-verify` refuses cleanly, so wait for `curl :8083/health` to go 200 before benching |
| 4 | bulk | oMLX, Qwen3-4B-Instruct 4bit (then 8bit) | `make omlx`, then `make bench BENCH_URL=http://localhost:8090/v1/chat/completions BENCH_MODEL='mlx-community--Qwen3-4B-Instruct-2507-4bit' BENCH_LABEL='omlx/Qwen3-4B-Instruct-2507-4bit'` and the same three defines on `make drain BENCH_K=1,3,6`. The 8bit variant swaps `-4bit` → `-8bit` in `BENCH_MODEL` and `BENCH_LABEL` |
| 5 | prose | oMLX, Qwen3.8-27B 4bit (same `:8090` server) | `make bench-prose PROSE_URL=http://localhost:8090/v1/chat/completions PROSE_MODEL='mlx-community--Qwen3.8-27B-4bit' PROSE_LABEL='omlx/Qwen3.8-27B-4bit'` |
| 6 | bulk | llama.cpp, DeepSeek-R1-Distill-Qwen-14B Q4_K_M, `:8083` | `make fast FAST_PORT=8083 FAST_HF=unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF:Q4_K_M FAST_SLOTS=6`, then `make bench BENCH_URL=http://localhost:8083/v1/chat/completions BENCH_LABEL='llamacpp/R1-Distill-Qwen-14B-Q4_K_M' BENCH_THINK=1` — always reasoning, so `BENCH_THINK=1` stops sending `enable_thinking:false` and relaxes the leak gate |
| 7 | — | further candidates | Added here as they come up, one command per row. What is worth trying is best judged after the rows above have numbers |

## Ledger

Appended after each run, second-run numbers only (see the protocol). Prose
rows quote the draft_reply p50 in the "p50 triage ms" column's place — marked
(draft) — since prose runs never triage. gen t/s is wall-clock throughout;
llama.cpp rows also carry a server-clock rate in their JSON.

| date | label | result json | gen t/s | p50 ms | accuracy | drain msgs/min K=1/3/6 | verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-04 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0 (bulk baseline) | `triage-extract-…-035554.json`, `drain-…-035919.json` | 54.8 (63.6 srv) | 2176 | cat 81% · label 88% · needs_action 100% | 26.1 / 25.3 / **56.9** | the drain champion — 2.18x at K=6, queue-wait ≤102ms |
| 2026-09-04 | llamacpp/Qwen3.8-27B-Q4_K_M (prose baseline) | `prose-…-040919.json`, `triage-extract-ab-…-042749.json` | 10.4 (12.1 srv) | 22506 (draft) | prose read by hand; A/B vs 4B: category agreement 75%, urgency-within-one 100% | — | the reference the prose candidates tie with |
| 2026-09-04 | llamacpp/Qwen3.8-27B-UD-Q4_K_XL | `prose-…-050539.json` | 10.1 (11.6 srv) | 22383 (draft) | prose read by hand | — | speed tie with baseline (−3.5% gen t/s); any edge is quality, judged by reading |
| 2026-09-04 | omlx/Qwen3-4B-Instruct-2507-4bit | `triage-extract-…-043101.json`, `drain-…-043617.json` | 61.7 | 2066 | cat 81% · label 88% · needs_action 100% (identical misses to baseline) | 30.2 / 36.0 / 31.6 | fastest single stream (+12.5% gen t/s) but the drain peaks at K=3 and degrades at K=6 |
| 2026-09-04 | omlx/Qwen3-4B-Instruct-2507-8bit | `triage-extract-…-044023.json`, `drain-…-044436.json` | 45.5 | 2860 | cat 81% · label 88% · needs_action 100% | 22.4 / 33.4 / 30.6 | slower than the 4bit everywhere with the same accuracy — no reason to prefer it |
| 2026-09-04 | omlx/Qwen3.8-27B-4bit | `prose-…-045218.json` | 10.5 | 22233 (draft) | prose read by hand | — | draft speed tie with the baseline; naming −18% — nothing measurable to switch for |
| 2026-09-04 | llamacpp/R1-Distill-Qwen-14B-Q4_K_M (BENCH_THINK=1) | none — bench cannot complete | — | — | — | — | **disqualified for bulk**: contract verify passes, but reasoning consumes the production token budget and the JSON answer truncates mid-object (reproduced twice). In production that exact failure drops mail |

## Recommendations

**Bulk slot: keep llama.cpp Qwen3-4B-Instruct Q8_0 on :8082.** The bulk
slot's defining workload is the backlog drain, and llama.cpp wins it without
argument: 56.9 msgs/min at K=6 against oMLX's best-of-any-K 36.0 — with
accuracy identical to the decimal on every scored dimension (both miss the
same three categories). oMLX's real single-stream edge (+12.5% gen t/s, p50
2066ms vs 2176ms) is the wrong number to optimize: one message arriving alone
is fast either way; sixty arriving after a sync is where the slots matter.
Revisit if oMLX's batched engine improves — the harness makes that a
one-command check.

**Prose slot: keep llama.cpp Qwen3.8-27B Q4_K_M on :8080.** All three
candidates are a speed tie on drafts (p50 22.2–22.5s, gen t/s within ±4%),
so the only thing left to switch for is prose quality, and that is a reading
judgement, not a scorecard — the verbatim titles and drafts from every run
are in the bench logs and JSONs for exactly that comparison. On the
measurables there is no reason to move. The Unsloth UD-Q4_K_XL quant costs
nothing to keep cached if a quality read later favors it.

**R1-Distill-Qwen-14B: do not adopt for bulk work.** Not a speed judgement —
a fit one: with thinking enabled (its only mode) it cannot reliably finish a
triage answer inside the app's token budgets, and a truncated answer is a
dropped message, not a slow one. Any always-reasoning candidate needs either
task budgets sized for its reasoning or a runtime-level reasoning cap before
it can be measured at all, let alone adopted.

## Open questions

**Distribution.** There is no install story yet for llama.cpp, oMLX, or the
model weights when this app goes to anyone who is not the person who built it.
The dev setup is hand-rolled: Homebrew for the runtimes, this `Makefile` for
the servers, HuggingFace downloads for tens of gigabytes of weights. Whichever
runtime wins here, a future round has to design the first-run dependency and
model install flow — what gets bundled, what gets fetched, and what happens on
a machine where the download is still in progress.

**Reasoning models on oMLX.** oMLX needs per-model reasoning-parser
configuration to separate reasoning tokens from the answer. Nothing in the
matrix above needs it, but a thinking candidate on oMLX (the row-6 equivalent)
would have to sort that out before its numbers mean anything — otherwise
reasoning ends up in the content and every schema check fails for the wrong
reason.
