# The model bakeoff

The app runs two model slots: a **bulk** slot that does triage, extraction and
storyline membership, and a **prose** slot that names storylines, recaps them,
and drafts replies. Both are served locally, and both are choices rather than
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
| `make bench-prose` | The prose slot: five storylines named, three recapped and five replies drafted, printed verbatim. No scorecard — a title, a recap and a draft are judged by reading them. |
| `make ab` | The same corpus through triage and extraction on **both** slots, printing where they disagree and what each cost. |
| `make ab-membership` | The membership eval set through the confirm task on both slots, against the answer a person would give. |
| `make drain` | The drain concurrency race: one round per concurrency in `BENCH_K` over the same backlog. The only bench that can see batching. |
| `make bench-verify` | Not a measurement — a contract check. See "Protocol". |
| `make golden-baseline` | Not a model run at all: what the shipping app already scored on the golden set, from the labels the set stores. See "The golden set". |
| `make golden-score R=…` | Scores a golden run file, keep-only first and all items second. See "The golden set". |
| `make golden` | The golden set through triage, needs-you and extraction on the bulk slot — the run behind a golden-ledger row. Writes the run file and the timing/cost JSON. |
| `make golden-prose` | Reply decisions for every gold-keep item and drafts for the reply-rubric items, on the prose slot. |

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
- `GOLDEN`, `GOLDEN_REGISTRY`, `GOLDEN_CTX`, `GOLDEN_K`, `GOLDEN_OWNER_NAME` /
  `GOLDEN_OWNER_ADDRESS` — see "The golden set".

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

## The golden set

The bakeoff's accuracy numbers used to come from seventeen fictional emails.
The golden set replaces them for anything that claims to be a quality
measurement.

**What it is.** A hundred real messages from the live mailbox, each carrying
gold labels for every stage the pipeline runs: the gate verdict and its reason,
triage (category, urgency, needs-action, reply-expected, deadline, plus rubrics
for the label, the summary and the action items), extraction (intent,
importance, project, topics, people, organisations, plus an evidence rubric),
the needs-you verdict with a confidence floor, the storyline the message
belongs under, and the thread's state. Twenty-five of them also carry a REPLY
rubric — the points a draft must make, the points it must not, and the facts
only the owner knows, which a good draft asks about rather than invents.

The hundred are drawn across nine strata, each named for what it tests rather
than for what it contains: messages at the core of a storyline, messages that
tempt a wrong one, the spread of triage labels, gates that should keep,
gates that should drop, gates that were missed, gate edge cases, hard
needs-you calls, and thread recaps. Every item is marked `easy`, `medium` or
`hard`, and records which rung of the context ladder its label needs.

**How the labels were made**, in one paragraph, because it is what the numbers
rest on: two independent model annotators worked from a written spec, one at
temperature 0 and shown the app's stored output, one at temperature 1 and not
shown it, so the second opinion cannot be anchored by the first or by the
system under test. Deterministic facts (thread state, and what the app
currently does) are computed rather than judged. Where the two annotators split
on a genuinely ambiguous enum, BOTH answers become acceptable rather than one
being chosen — a model is not marked wrong for a call two careful annotators
split on — while forbidden lists are unioned, so a trap either annotator spotted
stays a trap. The remaining conflicts were adjudicated by hand, a third harness
ran as a control, and an adversarial review then tried to refute the gold
itself, with every finding re-checked by a skeptic whose default stance was
that the gold was right. Every item records whether the annotators agreed
(`2/2`) or needed adjudication (`1/2`), and every table below is printed twice:
once over all items, once over the `2/2` subset. A candidate that only looks
good on the clean subset is a different animal from one that is uniformly
mediocre, and a single number hides it.

**Where it lives.** `golden/`, at the repo root, git-ignored in full — the set
is real correspondence and this repository is public. It exists on the machine
that built it and nowhere else, which means the targets below depend on files
a clean checkout cannot supply. That is deliberate and is not going to change.
`GOLDEN` points at the set (`golden/golden-set.json` by default) and
`GOLDEN_REGISTRY` at the storyline registry; override either in `local.mk`.
Committed tests use a small FICTIONAL fixture of the same shape
(`app/test/fixtures/golden_fixture.json`) so the loader and the run-file writer
are covered offline by anyone.

**The scorer of record is `golden/tools/score_run.py`, not Dart.** One set of
scoring semantics, already reviewed and already producing the baseline below;
a Dart re-implementation would be a second opinion about what "correct" means,
which is the one thing a bakeoff must not grow. It reads either the labels the
app already stored (`--baseline`, no model run at all) or a RUN FILE a replay
wrote. Two commands:

```sh
make golden-baseline                      # what the shipping app scores
make golden-score R=tmp/bench/golden-run-….json
make golden-score R=… BREAKDOWN=stratum   # or difficulty, or derivable_from
make golden-score R=… JSON=tmp/row.json   # the same tallies, for a ledger row
```

`BREAKDOWN` and `JSON` apply to the keep-only pass only. That is the pass a
ledger row quotes; breaking down the all-items pass as well would double the
output for a copy nobody reads.

Both print twice, because there are two honest populations:

- **all items** — every message, including the ones the gate dropped. Triage
  never ran on those, so their absence counts as "not attempted" rather than
  wrong, and the gate's own quality is priced into the read.
- **gold-keep only** (`--keep-only`, which the make targets run first) — the
  76 messages gold says should have been kept. This is the model-quality
  number, and it is what a ledger row quotes first.

A run file is a JSON array of per-item objects, and **an omitted section means
"not attempted", not "wrong"**, so a partial run scores honestly. The one trap
is `triage.deadline`: the empty string is the claim "this message named no
deadline" and scores as an answer, while a null is a stage that never ran.

**Lexical against rubric.** The scorer checks what can be checked without a
reader: enums, booleans, list membership, surname matching, a normalised
project name. The fields a user actually reads — the label, the summary, the
action items, the two evidence sentences, and a drafted reply — are rubric
judgements ("does this sentence contain this claim") and a lexical proxy for
them produces confident nonsense. They are counted here and judged in a later
phase, by a judge that grades the baseline and every candidate alike.

**The context ladder.** The set exists partly because the pipeline is
inconsistent about thread context: triage and needs-you see the last three
messages at 300 characters each, extraction sees the judged message completely
alone. So every item carries three rungs, and `GOLDEN_CTX` picks which one the
replay shows triage and needs-you:

| rung | what the thread carries |
|---|---|
| `none` | the message alone |
| `tail3` | the last three messages, 300 characters each — what ships today |
| `compressed` | the tail, led by an extractive digest of everything earlier |

The digest is extractive, never generated: a model inside the fixture would
make it irreproducible, and a generated summary leaks the answer. It rides in
as one synthetic leading thread message rather than as a new prompt field,
because a measurement round does not edit the prompts it measures. Two
consequences follow from riding in that fence. Triage and needs-you keep only
the newest three thread messages, so at this rung the digest takes one of the
three slots and the two newest tail messages take the others — a fourth would
push the digest, the oldest, straight out. **And both clip a thread message at
300 characters, so what they actually see of a digest is its head**: the
median digest in the set is about 670 characters, so the clip bites on roughly
two thirds of them. The `compressed` rung is therefore a lower bound on what
real compression would buy, and any row run at it says so.
Gold records, per stage, which rung a label needs, so
`BREAKDOWN=derivable_from` answers the question the ladder was built for: what
does context buy, and where.

`GOLDEN_K` sets the replay's concurrency (a llama.cpp server needs
`FAST_SLOTS` at least that high), and `GOLDEN_OWNER_NAME` /
`GOLDEN_OWNER_ADDRESS` supply the inbox owner, which the set itself does not
carry.

**Running it.** Two targets, one per slot:

```sh
make golden                               # bulk slot, tail3 — the shipping rung
make golden GOLDEN_CTX=none               # the same, message alone
make golden GOLDEN_CTX=compressed         # the digest rung, with its caveat
make golden BENCH_URL=… BENCH_LABEL=…     # point it at a candidate
make golden-prose                         # prose slot: decisions + drafts
```

Each run writes a PAIR of files to `BENCH_OUT`. The run file
(`golden-run-<label>-<stamp>.json`) holds real message content and is what
`make golden-score R=…` reads — the run prints that exact command when it
finishes. The timing and cost JSON (`golden-bulk-…` / `golden-prose-…`) is
schema 1 like every other bench result, and carries `extra.run_file`,
`extra.ctx`, `extra.k`, `extra.msgs_per_min` and `extra.cost`, so a row can be
quoted from one file and scored from the other.

The replay runs the app's own tasks with the HANDLERS' parameters, not a
bench's: triage on the defaults, needs-you and extraction at temperature 0,
and the deterministic needs-you floor applied FIRST — a floor item never calls
the model at all and its row is marked `floor: true`, so a reader can tell the
model's recall from the floor's. The owner line comes from `GOLDEN_OWNER_NAME`
/ `GOLDEN_OWNER_ADDRESS`; a run with neither set says so in its banner, because
needs-you then judges "does this name the owner" with no owner to name.
`msgs/min` is items over wall time for the whole run at the `GOLDEN_K` it was
given, which is the throughput a backlog is felt in. Cost comes from the dated
Bedrock price table in `app/test/fixtures/golden_prices.dart`: zero for a local
server, and BLANK — never zero — for a remote model the table does not price,
because an unpriced cloud call is unknown rather than free.

Two things the needs-you replay leaves out, for the same reason the draft
below leaves things out: the attachment digests the handler passes (the set
carries none) and this machine's custom needs-you rules — the replay runs the
default prompt, so a row measures the shipped prompt on the model rather than
one machine's rules on it.

One comparability caveat. The replay runs triage, needs-you and extraction on
gold-DROP items too — the gate strata need reading — where the shipping app
never ran them. So a replay's ALL-ITEMS pass is not comparable with the
baseline's all-items pass: the baseline reads those items as "not attempted",
the replay as answers. The keep-only pass, which a ledger row quotes, is
unaffected.

The prose run differs in three ways worth stating. First, its decision context
is the plain tail whatever `GOLDEN_CTX` says, because the decision keeps six
messages at 500 characters and the tail already fits it whole — the ladder is a
question about the two stages that clip. Second, a draft gets the message and
its tail and nothing else: no style examples, no about-me, no storyline summary, no
directory pack, because the set carries none of them, so a prose row measures
the model rather than the retrieval that would feed it in the app. Third, in a
prose run file `triage.reply_expected` IS the reply decision: the scorer's
`triage.reply_expected` asks "is the sender waiting on an answer", which is
exactly what the reply-decision stage answers and what gold has one label for,
so a decision-only row writes its verdict there and repeats it in a `decision`
object with the model's reason beside it.

A `compressed` row carries the lower-bound caveat above, printed by the run
itself so it travels with the number rather than being remembered.

### Golden ledger

Keep-only numbers, per the population rule above. Rubric columns come from the
judge, not from `score_run.py`.

| date | slot | label | ctx | run file | keep-only: category / urgency / needs_action / reply_expected / needs_you / intent / importance / project / topics / people | rubric | p50 ms | gen t/s | msgs/min | $/1K msgs | note |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-12 | — | the shipping app, as stored | tail3 | none — `--baseline` | 94% / 88% / 68% / 77% / 94% / 84% / 45% / 67% / 31% / 86% | Opus 4.5 judge: label 84% · action items 61% · summary 53% · needs-you evidence 36% · extract evidence 25% | — | — | — | — | the shipping app's stored output; gate 76/100, storyline 42/99 with no correct positive |
| 2026-09-14 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | tail3 | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-174707.json` | 89% / 89% / 66% / 70% / 92% / 75% / 39% / 66% / 26% / 87% | — | 2436 / 1616 / 1950 (triage / needs_you / extraction) | 41.4 | 8.9 | $0.00 | the shipping bulk model, replayed; second of two passes |
| 2026-09-14 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | none | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-175832.json` | 88% / 89% / 75% / 75% / 93% / 75% / 39% / 66% / 26% / 87% | — | 2173 / 1458 / 2020 (triage / needs_you / extraction) | 41.5 | 9.1 | $0.00 | context ladder: message alone (one pass) |
| 2026-09-14 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | compressed | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-181030.json` | 89% / 89% / 68% / 74% / 91% / 75% / 39% / 66% / 26% / 87% | — | 2452 / 1684 / 2028 (triage / needs_you / extraction) | 40.4 | 8.7 | $0.00 | context ladder: digest + two newest tail messages, 300-char clip — lower bound (one pass) |
| 2026-09-14 | bulk | llamacpp/Qwen3.5-4B-UD-Q4_K_XL | tail3 | `golden-run-llamacpp-qwen3-5-4b-ud-q4-k-xl-20260914-190503.json` | 91% / 89% / 66% / 83% / 87% / 79% / 66% / 63% / 29% / 88% | — | 2838 / 1716 / 2745 (triage / needs_you / extraction) | 36.9 | 7.5 | $0.00 | candidate bulk model, 1 slot on :8083; second of two passes |
| 2026-09-14 | bulk | llamacpp/Qwen3.5-9B-Q4_K_M | tail3 | `golden-run-llamacpp-qwen3-5-9b-q4-k-m-20260914-200430.json` | 91% / 93% / 64% / 70% / 83% / 82% / 74% / 64% / 24% / 83% | — | 4394 / 2648 / 4444 (triage / needs_you / extraction) | 22.8 | 4.6 | $0.00 | candidate bulk model, 1 slot on :8083; second of two passes |
| 2026-09-14 | bulk | llamacpp/Qwen3.8-27B-Q4_K_M (as bulk) | tail3 | `golden-run-llamacpp-qwen3-8-27b-q4-k-m-as-bulk-20260914-223320.json` | 92% / 95% / 72% / 84% / 93% / 86% / 74% / 58% / 32% / 93% | — | 13412 / 8969 / 13907 (triage / needs_you / extraction) | 7.1 | 1.5 | $0.00 | accuracy ceiling for these prompts: the prose model doing bulk work, 1 slot, no MTP; second of two passes |
| 2026-09-14 | prose | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | tail (fixed) | `golden-run-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260914-230921.json` | — / — / — / 82% / — / — / — / — / — / — | — | 6578 / 16589 (reply_decision / draft_reply) | 7.1 | 4.4 | $0.00 | prose slot: reply decision for the 76 gold-keep items (scored as reply_expected) + 25 drafts for the reply-rubric items, judged in Phase 3; message + tail only; second of two passes |

**What the first rows say** (2026-09-14, all at `GOLDEN_K=1`, keep-only, every
row the second of two passes unless its note says otherwise). Bigger bulk
models buy the enums, not the booleans: category and urgency reach 91–95% on
anything from Qwen3.5-4B up, against 89% on the shipping 4B, and importance
jumps from 39% to 66–74% — but needs-you FALLS as the bulk model grows (92 →
87 → 83) until the 27B recovers it (93), and project is flat or worse. The
context ladder on the 4B is the row worth re-reading: the thread tail lowers
needs-action (75% alone → 66% with it) and reply-expected (75 → 70), on the
items whose gold label needs the tail as much as on the rest, and the digest
rung sits between the two. Extraction is identical across rungs by
construction — it has no thread field. The 27B doing bulk work is the ceiling
for these prompts (needs-action 72, reply-expected 84, needs-you 93) at six
times the shipping model's time per message. On the prose slot the dedicated
reply decision scores 82% against gold reply-expected, twelve points above the
4B's triage boolean for the same question. Topics stay under a third for every
model, the one field nothing separates them on. The temperature-0 stages
(needs-you, extraction) reproduce token for token between passes; triage at
0.2 moves one to three points, which is the noise floor for its booleans. The
replayed 4B also lands a few points under the stored baseline on several
fields: the stored run saw the live thread of 2026-09-12 and is one sample of
the same model, so candidates are read against the replayed row, not the
stored one. Rubric columns wait for the judge; recommendations for the round's
last phase.


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
llama.cpp rows also carry a server-clock rate in their JSON. The accuracy
column here is measured on the fictional corpus; accuracy against real traffic
lives in the golden ledger above.

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

**Distribution.** The installer round answers this: the app bundles its own
`llama-server`, built from a SHA-pinned llama.cpp source tarball, and ships as
a DMG, with the weights downloaded on first run from a committed manifest.
`docs/distribution.md` is the authority on how a checkout becomes an
installable build.

**Reasoning models on oMLX.** oMLX needs per-model reasoning-parser
configuration to separate reasoning tokens from the answer. Nothing in the
matrix above needs it, but a thinking candidate on oMLX (the row-6 equivalent)
would have to sort that out before its numbers mean anything — otherwise
reasoning ends up in the content and every schema check fails for the wrong
reason.
