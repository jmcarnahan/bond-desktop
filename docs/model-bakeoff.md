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
| `make bench-prose` | The prose slot: five storylines named, three recapped and five replies drafted, printed verbatim. The draft leg streams, so its row carries a `ttft p50` column — how long the box stayed empty, beside how long the whole call took. No scorecard — a title, a recap and a draft are judged by reading them. |
| `make ab` | The same corpus through triage and extraction on **both** slots, printing where they disagree and what each cost. |
| `make ab-membership` | The membership eval set through the confirm task on both slots, against the answer a person would give. |
| `make drain` | The drain concurrency race: one round per concurrency in `BENCH_K` over the same backlog. The only bench that can see batching. |
| `make bench-pipeline` | The backlog end to end through the real queues, in both drain shapes (`PIPE_SHAPE=single\|lanes`): wall to a usable inbox, wall to the drafts, and how long a message that arrives mid-backlog waits. Needs BOTH servers. |
| `make bench-verify` | Not a measurement — a contract check. See "Protocol". |
| `make golden-baseline` | Not a model run at all: what the shipping app already scored on the golden set, from the labels the set stores. See "The golden set". |
| `make golden-score R=…` | Scores a golden run file, keep-only first and all items second. See "The golden set". |
| `make golden` | The golden set through triage, needs-you and extraction on the bulk slot — the run behind a golden-ledger row. Writes the run file and the timing/cost JSON. |
| `make golden-prose` | Reply decisions for every gold-keep item and drafts for the reply-rubric items, on the prose slot. |
| `make golden-sweep GOLDEN_RUN=…` | The app's own filing path over the golden set: the sweep, the naming pass, the per-member confirms and the assign shortlist, scored by membership against the gold registry. Needs the embed, bulk and prose servers. `SWEEP_CARD` picks whether the people on a thread are inside the clustering vector. See "The golden set". |
| `make golden-gate` | Offline, no server: the golden set through the app's own gates — direction, sender address and body. Tier 2 (headers) and the Teams ingest gates are not in the set and go unmeasured. `GOLDEN_RUN=` adds the model's `notification` proxy column. See "The golden set". |

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
- `PIPE_COPIES` — how many copies of the fixture corpus `make bench-pipeline`
  seeds (default 3 ≈ 66 messages).
- `PIPE_WIDTH` — how many drafts are at the prose server at once: the app's
  `AppPrefs.proseParallel` as a define. The server must have been started with
  at least this many slots or the extra requests queue rather than batch.
- `PIPE_SHAPE` — `single` (one worker holding needs-you, extraction and
  drafting, sharing the triage gate — the pre-Round-C shape) or `lanes` (what
  ships: a fast worker on the triage gate, a draft worker on its own).
- `PIPE_LATE` — `0` skips the late-arrival leg.
- `MODEL_CTX` — the total context the prose server is launched with, when it
  wants a different one from `CTX_SIZE`. llama.cpp splits `-c` across
  `--parallel` slots, so `SLOTS=2` at 16K is 8K a slot; `make model SLOTS=2
  MODEL_CTX=32768` is how a second slot is bought without narrowing either one.
- `GOLDEN`, `GOLDEN_REGISTRY`, `GOLDEN_CTX`, `GOLDEN_EXTRACT_CTX`, `GOLDEN_K`,
  `GOLDEN_CHARTER_CAP`, `GOLDEN_OWNER_NAME` / `GOLDEN_OWNER_ADDRESS` — see
  "The golden set".
- `SWEEP_CARD` — which clustering card `make golden-sweep` embeds: `topics`,
  the card the app ships since 2026-09-18, with its people segment left empty,
  or `participants`, the card it shipped before. Defaults to `topics`, which
  is to say to the app. The variable that bench was built to price.
- `EMBED_URL` — the embedding server every bench dials, defaulting to
  `EMBED_PORT` on localhost. It reached only the app until `make golden-sweep`
  needed it: a bench run without it would embed against the compiled default
  whatever `local.mk` says.

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
   nothing. The prose slot has a second check beside the contract one
   (`prose slot streams the same answer it writes plain`): the draft prompt at
   temperature 0, sent once plain and once streamed, must come back as the same
   object, in at least two deltas, with usage reported and a first-token stamp.
   Byte-identity is ASSERTED only where the runtime reports its own `timings` —
   llama.cpp, whose temperature-0 decode reproduces 25 of 25 golden drafts. A
   runtime that reports none (vLLM, whose speculative decoding is not bit-exact
   under batching — see the 2026-09-17 FP8+MTP row) has never promised that, so
   there the comparison is printed rather than asserted. First run, 2026-09-17:
   llama.cpp (27B Q4_K_M + MTP) streamed the draft in 229 deltas, first token
   205–216 ms of 13.4 s on a warm prefix, usage and timings present, streamed
   == plain byte-identical; vLLM on the box (27B FP8, same day) streamed in 84
   deltas, first token 695 ms of 5.0 s, usage present, no timings, and the two
   answers were identical there too.
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
alone. So every item carries four rungs, and `GOLDEN_CTX` picks which one the
replay shows triage and needs-you:

| rung | what the thread carries |
|---|---|
| `none` | the message alone |
| `tail3` | the last three messages, 300 characters each — what ships today |
| `compressed` | the tail, led by an extractive digest of everything earlier as a synthetic thread message (the superseded 2026-09-14 form) |
| `digest` | the tail, plus the digest as its own `thread_digest` fence, 900 characters, trimmed by whole lines from the old end (2026-09-16; supersedes `compressed`) |

The digest is extractive, never generated: a model inside the fixture would
make it irreproducible, and a generated summary leaks the answer. `compressed`
rode it in as one synthetic leading thread message rather than as a new prompt
field, on the principle that a measurement round does not edit the prompts it
measures. Two consequences followed from riding in that fence. Triage and
needs-you keep only the newest three thread messages, so at that rung the
digest takes one of the three slots and the two newest tail messages take the
others — a fourth would push the digest, the oldest, straight out. **And both
clip a thread message at 300 characters, so what they actually saw of a digest
was its head**: the median digest in the set is about 670 characters, so the
clip bit on roughly two thirds of them. The `compressed` rung is therefore a
lower bound on what real compression would buy, and any row run at it says so.
`digest` is what replaced it: the three tasks gained a `threadDigest` field of
their own, so the digest is no longer a thread message, no longer clipped to
300, and no longer stealing a tail slot — it is its own fence above the tail,
capped at 900 characters by `fitThreadDigest`, which drops whole lines from the
OLD end and keeps the header line. Prefer `digest`; `compressed` stays only so
older rows can be read.

`GOLDEN_EXTRACT_CTX` is extraction's own axis — `none` (the default, what
ships), `tail3` or `digest` — because extraction's question is not triage's
and the two stages had never been measured apart. It is recorded as
`extra.extract_ctx` in the timing JSON, and every run prints a
`digests: N items carry one, M trimmed to 900` line so a reader knows how much
of the set the rung actually touched.

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
make golden GOLDEN_CTX=digest GOLDEN_EXTRACT_CTX=digest   # the digest as its own fence, extraction on the same rung
make golden GOLDEN_CTX=compressed         # the digest rung, with its caveat (superseded)
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

**Bedrock as a target.** A hosted candidate is a target like any other — a
URL, a model id and a label — with two differences: it needs a key, and it may
need the other wire.

Most Bedrock models speak the OpenAI shape at
`https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/chat/completions`
and take the app's body unchanged: `nvidia.nemotron-nano-3-30b`,
`nvidia.nemotron-super-3-120b`, `zai.glm-4.7-flash`, `zai.glm-4.7`,
`zai.glm-5`, `deepseek.v3.2`, `google.gemma-3-12b-it`, `google.gemma-3-27b-it`,
`openai.gpt-oss-20b-1:0`, `openai.gpt-oss-120b-1:0`,
`openai.gpt-oss-safeguard-20b`. The Anthropic ids —
`us.anthropic.claude-haiku-4-5-20251001-v1:0`, `us.anthropic.claude-sonnet-5`,
`us.anthropic.claude-opus-5` — are not served on that wire at all, so they are
disqualified on it and run on Converse instead (`BENCH_WIRE=converse`, or
`PROSE_WIRE` for the prose slot), which addresses the model in the URL path
rather than in the body. `minimax.minimax-m2.5` answers on both wires and is
disqualified on both, for R1-Distill's reason: it reasons whatever it is told —
`<reasoning>…` written INTO `content` on the OpenAI wire (178 tokens for a
ten-token answer), a `reasoningContent` block plus a tool input outside the
enum on Converse — so every latency against it would measure the leak and
every budget would be spent on it.

The key is a long-term Bedrock API key for an IAM user:

```sh
aws iam create-service-specific-credential \
  --user-name <user> --service-name bedrock.amazonaws.com
```

Store it as `BEDROCK_API_KEY=…` in the git-ignored `.env` (`BEDROCK_ENV` in the
Makefile — its own variable rather than `MS_ENV`, which may point at another
project's registration file). The harness receives it as a `--dart-define` the
SHELL resolves inside the recipe, so it never sits in a make variable, never
appears in `make -n` output, and never reaches a result file, an
`LlmCallRecord` or a log line. One gotcha: an `aws` CLI older than the feature
(2.27.35 here) parses the secret out of its own output — read the raw response
under `--debug`, or upgrade the CLI. `BEDROCK_REGION` defaults to `us-east-1`,
which is the region the price table in
`app/test/fixtures/golden_prices.dart` (dated `2026-09-12`) was copied for; a
row run elsewhere is priced against the wrong table.

```sh
make bench-verify BENCH_URL='$(BEDROCK_OPENAI_URL)' BENCH_MODEL=nvidia.nemotron-nano-3-30b
make golden BENCH_URL='$(BEDROCK_OPENAI_URL)' BENCH_MODEL=nvidia.nemotron-nano-3-30b \
            BENCH_LABEL=bedrock/nemotron-nano-3-30b GOLDEN_K=4
make golden-prose PROSE_URL='$(BEDROCK_CONVERSE_URL)' PROSE_WIRE=converse \
            PROSE_MODEL=us.anthropic.claude-sonnet-5 PROSE_LABEL=bedrock/claude-sonnet-5
```

`make bench-verify` first, always, and here for a second reason: the OpenAI
wire's `/openai/v1/models` answers 404, so there is no listing to check a
target against and a real completion is the only proof the id exists.

What that verify confirmed on 2026-09-14: the OpenAI wire accepts
`chat_template_kwargs` and `response_format: json_schema` with `strict`, and it
CONSTRAINS decoding — an enum probe that asked for a value outside the enum got
one inside it. It reports `usage` and sends no `timings`, so those rows are
wall-clock only and carry `timing_source: wall`.

Converse differs in four ways worth knowing before reading a row. A JSON answer
is a forced tool call (`toolConfig` plus a `toolChoice` naming it), not a
`response_format`. `temperature` is NOT sent: Claude 5 answers HTTP 400
`temperature is deprecated for this model` while Haiku 4.5 accepts one, and a
wire cannot behave two ways — so a Converse row samples at the model's default
and the run prints that caveat beside its banner. A `reasoningContent` block
counts as a reasoning leak, exactly as `reasoning_content` does on the other
wire. And `metrics.latencyMs` is the whole request's latency rather than a
generation time, so it is dropped rather than reported as a server clock: a
Bedrock row quotes no server-side rate.

Throttling is HTTP 429 on both wires, which the client maps to
`LlmUnavailableException` — the same class a 503 gets, because it says nothing
about the request and the app would park on it. A golden replay retries an
unavailable stage up to three more times with 2/4/8 s backoff and prints
`retried N` in its failure line, so a throttled row comes out complete rather
than quietly missing stages. `GOLDEN_K=4` is the intended concurrency for a
cloud row; there is no slot count to respect, only the account's rate limit.

Comparability: a Bedrock row runs the same handler parameters as a local row,
with the Converse temperature caveat as the single exception. Cost comes from
the dated price table and is blank — not zero — for an id nobody has priced.

**Judging the rubric fields.** Six fields need a reader rather than a matcher:
the label, the summary, the action items, the needs-you evidence, the extract
evidence, and a drafted reply. The judge answers one boolean per rubric string
— "is this claim in this sentence" — and nothing else. The pass/fail arithmetic
is code in `golden/tools/judge_rubrics.py`: every required point present, no
forbidden point asserted, and the text inside the app's own caps (summary 500,
label 40, evidence 300 characters). The judge reads; it does not grade.

The middle step is Claude Code agents rather than a Bedrock call, so a judging
round needs no cloud credentials at all:

```sh
make golden-judge-pack R=tmp/bench/golden-run-….json    # write the packets
#   then one Claude Code agent (Opus) per packet under
#   golden/labels/judge/<run>/packets/, each writing one file per item
make golden-judge-tally R=tmp/bench/golden-run-….json   # grade what they wrote
make golden-judge-tally R=… JSON=tmp/rubric.json        # the same, for a row
make golden-judge-pack  BASELINE=1 NAME=baseline-cc     # re-judge what the app stored
make golden-judge-tally BASELINE=1 NAME=baseline-cc
```

Pack writes one packet per `GOLDEN_BATCH` items, each carrying the judge prompt
verbatim, so an agent needs nothing but the file it is handed. Tally prints
twice, keep-only first and then all items, exactly like `make golden-score`,
and `JSON=` captures the keep-only pass. `NAME=` picks the directory, which is
how a re-judged `baseline-cc` sits BESIDE the original Opus 4.5 files instead
of over them. Items already carrying a result file are skipped, so a re-pack
after a half-finished round packs only the remainder.

**These numbers are comparable, not absolute.** The gold rubrics were written
with Claude's help and the judge is Claude, so every row leans the same way. A
rubric number is worth reading against another rubric number — the baseline and
every candidate share one judge and one prompt — and is not worth reading as
the truth about how good a summary is.

Three honesty counters print under the table, because a judging pass can fail
quietly in ways a pass rate hides. `missing` is judgeable items with no result
file, and under `--tally-only` it names them (the first twenty), so an agent
that dropped its packet shows up instead of being rounded away. `unreadable` is
files that exist but carry an error or no verdict; a re-pack treats both as not
yet judged, so the next round of agents picks them up without `--force`. Under
keep-only every counter covers the keep population, the same one the rates do. `rubric keys unmatched` counts keys the judge invented
instead of copying: a paraphrased key is never looked up, so the rubric point
it stands for silently fails. A non-zero count means the row is partly
measuring the judge's formatting rather than the model's writing — re-judge
those items rather than quoting them.

The ledger's `rubric` column reads `label · action items · summary · needs-you
evidence · extract evidence · draft`, as keep-only pass rates. The baseline
appears once, carrying both judges' numbers side by side: the same stored
output, read twice by two different readers.

**Storyline membership.** Filing is the stage the golden set says has never
once been right — the shipping app scores 42 of 99 on `storyline.id` with no
correct positive — and the only model in it is `ConfirmMembershipTask`. So
there is a third replay that asks that task alone, per item, against a BOUNDED
candidate list: the item's gold storyline when it has one, every registry
storyline gold marks forbidden on it, and three more drawn from the rest of the
registry. That is three to six questions an item, about four and a half on
average and 453 over the set, against the three thousand a full sweep of thirty
storylines would ask. Each registry storyline arrives as the app's own
`Storyline` with its charter as the membership criterion — clamped at 400
characters at prompt time, exactly as in the app, which bites on most real
charters — and with its people unioned out of the set's OTHER items filed
under it. The candidate's own thread is never among the members it is judged
against, as in the app, where a candidate is by construction not yet one; a
whole-set union would hand the model the candidate card's own participants
segment back as the storyline's people, on exactly the question the headline
gold-accept rate is read from. A storyline whose only golden item IS the
candidate therefore arrives with an empty People line, which is thinner than
the prompt the app would send and so penalises rather than flatters — the run
counts how many gold candidates were asked that way. The candidate card is
built the way `enrichedCardForConversationRow` builds one: the subject
stripped of its Re:/Fw: markers, the conversation's people, and the extraction
topics and triage summary of a BULK RUN FILE, passed as `GOLDEN_RUN=`. The
card is therefore the one the app would carry if the model that wrote that
run file were the one shipping, which is the only honest way to card a thread
the replay never triaged. The extras are drawn by a shuffle seeded with the
item's id, so two candidates sit the same exam; the anti-storylines are never
instantiated, because an anti-storyline has no charter to judge against and is
scored through the real storylines' forbidden lists instead.

What this does NOT measure is most of the stage. The sweep that proposes
storylines, the embeddings and thresholds that shortlist them, the recruit laps
and the chaining are code, and this replay is blind to all of it: it hands the
model a list a human wrote. The owner's kept and removed example fences ride
in empty, because a gold storyline has no owner history to teach it. And the
economics do not transfer — the app asks one confirmation per assignment and
this asks four or five per message, so the `$/1K msgs` on a storyline row is
per thousand messages FILED through the bounded list, not per thousand
triaged.

Scoring has two halves. The derived `storyline.id` is the accepted candidate
with the highest confidence — `low` counts as a no, the service's own rule,
and a tie at the top is broken alphabetically, blind to gold, with the ties
counted so a reader knows how often the rule decided anything. That id goes
into a run file and `make golden-score` applies the toolkit's
must/should/may/forbidden rules to it, the same scorer as every other row. An
item that lost a candidate call to a failure is left UNFILED, so the scorer
reads it as not attempted rather than as a miss. Beside the scorer the run
prints its own direct rates, which a single derived id cannot express:
gold-accept on the `must` and `should` populations, forbidden-accept,
extra-accept, how often a gold-`none` item was filed nowhere, and how many
yeses were hedged into `low` and thrown away.

```sh
make golden-storyline GOLDEN_RUN=tmp/bench/golden-run-<bulk>-….json         # the shipping 4B
make golden-storyline GOLDEN_RUN=… BENCH_URL=… BENCH_MODEL=… BENCH_LABEL=…  # a candidate on the bulk slot
make golden-score R=tmp/bench/golden-run-<bulk>-storyline-….json           # storyline.id, must/should/forbidden rules
```

**The sweep, replayed.** The block above measures the model handed a
candidate list a person wrote. `make golden-sweep` measures the half that list
skips: whether the app puts the right threads in front of it at all. It seeds
an in-memory store with the conversations behind the hundred items, one
conversation per thread, with the messages the set carries, the triage summary
and extraction topics of a `GOLDEN_RUN` bulk run file, and one live embedding
per thread through the app's own clustering recipe. Then it runs the real
`StorylineService`: `sweep` forms the clusters, the naming pass names them, a
confirm judges every member, and `assignConversation` offers every pool thread
that is still unfiled to the storylines that now exist. Three servers, so the
embed, bulk and prose slots all have to be up. Since Round D Phase 6 the tally
prints two more lines: each cluster's gold purity BEFORE the namer saw it, by
what the sweep then did with it, which separates a namer that declines pure
groups from a clustering that builds mixed ones, and the cosine of every pool
pair split by whether the two threads share a gold effort, which says whether
a threshold separating in-effort pairs from the rest exists at all.

The owner in this bench keeps everything. After each sweep pass every
suggestion is kept and the pass runs again, until a pass proposes nothing or
twenty have run. That is the only way past `maxPendingSuggestions`, which is a
compiled constant of three, and it is the honest emulation of an owner who
accepts what the sweep offers. One consequence rides on every row: a kept
storyline is active before the assign pass runs, so any rule that treats an
unanswered suggestion more strictly is exercised here by the sweep's own member
confirms and never by the assign pass.

Scoring is by MEMBERSHIP. Each app storyline is mapped to a registry slug by
the plurality of its members' gold ids, needing at least half of the members
that carry a slug and at least two of them; anything else is `unmapped`. An
item's derived `storyline.id` is its storyline's slug, `unmapped` when its
storyline answers to no effort, and `none` when its thread was filed nowhere.
`unmapped` is a miss on every gold value including `none`, which is what filing
into junk is. That goes into a run file `make golden-score` reads with the same
must, should, may and forbidden rules as every other row. `make
golden-baseline` resolves the app's stored TITLE to a slug instead, so the two
42 of 99 numbers are one stage read two ways. Beside the scorer the run prints
its own arithmetic: storylines formed and tombstoned, purity per storyline,
coverage per gold effort, the largest storyline's share of every filed thread,
correct positives, forbidden hits, model calls per kind and per pass, the
cosine of every pair inside a formed group in five bins, and wall per pass.

Three limits belong on every row. The pool is 95 conversations, 71 of them
with a kept inbound message, against a
live mailbox of hundreds, so the run UNDER-states chaining. The owner's kept
and removed examples and the recruit laps never run, because a seeded mailbox
has no owner history. And the gate verdict seeded is GOLD's rather than the
app's, so this measures the sweep over a correctly gated pool; `make
golden-gate` is what measures the gates.

```sh
make golden-sweep GOLDEN_RUN=tmp/bench/golden-run-<bulk>-….json                    # the card the app ships
make golden-sweep GOLDEN_RUN=… SWEEP_CARD=participants                             # the same, people back in the vector
make golden-score R=tmp/bench/golden-run-<bulk>-<prose>-sweep-….json                # storyline.id, must/should/forbidden rules
```

**The gates, replayed offline.** `make golden-gate` needs no server at all:
the app's gates are pure functions, so the run replays them over the set
itself — each item's direction through `triageStatusOnInsert`, its sender
address and its body through `gateFor`, the same two calls the ingest makes.
It prints verdict agreement, the drops it caught, the keeps it kept and the
misses on the `gate-keep-trap` stratum, a breakdown per stratum and a count
per drop-reason slug, and it writes a run file whose `gate.verdict`
`make golden-score` reads like any other.

Two things go UNMEASURED, and the run says so on its own line rather than
counting them as passes. The mail header gates — `newsletter` and
`auto_generated`, Tier 2 — read headers the set does not carry, so a
header-only gold drop is KEPT here. The Teams bot and self gates are decided
at ingest from Graph fields the set does not carry either. A third is
unmeasurable in principle rather than by omission: the per-sender `drop` rule
is data the owner writes, and a replay with no `sender_prefs` behind it reads
every gate of that kind as a miss. That is exactly why
this number and `make golden-baseline`'s gate number are two different
questions and are recorded side by side, never compared as if one beat the
other: the baseline is what the shipping app did on 2026-09-12 with headers in
front of it, and this is what the set alone can ask.

`GOLDEN_RUN=` adds one column and moves no verdict: triage's own `category`
per item from a bulk run file, which is the model's `notification` verdict
read as a proxy. It fired on 0 of 24 gold drops when it was measured on
2026-09-16, which is why there is no `notification` gate reason and no code
path — the decision is recorded in `docs/pipeline/03-triage.md` — and the
column is here so a prompt change can be re-read against it. It is read, never
enforced. The replay is deterministic, so the house rule about running a row
twice is the only reason to run it twice.

```sh
make golden-gate                                   # the app's gates, offline
make golden-gate GOLDEN_RUN=tmp/bench/golden-run-<bulk>-….json   # + the notification proxy
make golden-score R=tmp/bench/golden-run-app-gates-….json BREAKDOWN=stratum
```

### Golden ledger

Keep-only numbers, per the population rule above. Rubric columns come from the
judge, not from `score_run.py`. Rows sit with the run they compare against,
not in date order.

| date | slot | label | ctx | run file | keep-only: category / urgency / needs_action / reply_expected / needs_you / intent / importance / project / topics / people | rubric | p50 ms | gen t/s | msgs/min | $/1K msgs | note |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-12 | — | the shipping app, as stored | tail3 | none — `--baseline` | 94% / 88% / 68% / 77% / 94% / 84% / 45% / 67% / 31% / 86% | Opus 4.5 judge: label 86% · action items 59% · summary 54% · needs-you evidence 37% · extract evidence 24% — Claude Code subagent judge: label 82% · action items 54% · summary 37% · needs-you evidence 29% · extract evidence 22% | — | — | — | — | the shipping app's stored output; gate 76/100, storyline 42/99 with no correct positive |
| 2026-09-14 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | tail3 | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-174707.json` | 89% / 89% / 66% / 70% / 92% / 75% / 39% / 66% / 26% / 87% | label 84% · action items 67% · summary 39% · needs-you evidence 27% · extract evidence 25% | 2436 / 1616 / 1950 (triage / needs_you / extraction) | 41.4 | 8.9 | $0.00 | the shipping bulk model, replayed; second of two passes |
| 2026-09-16 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | tail3 | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260916-184707.json` | 88% / 88% / 72% / 75% / 89% / 75% / 39% / 66% / 26% / 87% | label 86% · action items 60% · summary 66% · needs-you evidence 36% · extract evidence 25% | 7321 / 4809 / 5399 (triage / needs_you / extraction) | 16.9 | 12.4 | $0.00 | round B phase 1, summary rule + needs-you evidence bullet v1 ("naming the specific words… and who is asking") — the bullet is NOT shipped: 27 of 64 evidence sentences reached the 300-character clamp (1 before) and the verdict fell 92 → 89; second of two passes (first: summary 63, evidence 34, traps 5); K=4 on 4 slots, so p50s include batching and msgs/min is not comparable with the K=1 rows; traps 4 items |
| 2026-09-16 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | tail3 | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260916-192254.json` | 88% / 88% / 71% / 74% / 86% / 75% / 39% / 66% / 26% / 87% | label 88% · action items 60% · summary 63% · needs-you evidence 9% · extract evidence 25% | 7669 / 3006 / 5454 (triage / needs_you / extraction) | 16.1 | 13.1 | $0.00 | round B phase 1, summary rule + evidence bullet v2 ("ONE short sentence, under 30 words, quoting…") — NOT shipped: the verdict fell to 86 and the sentence to 9%; evidence avg 121 chars, none at the cap; second of two passes; K=4; traps 4 items |
| 2026-09-16 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | tail3 | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260916-194031.json` | 88% / 88% / 71% / 72% / 92% / 75% / 39% / 66% / 26% / 87% | label 86% · action items 60% · summary 63% · needs-you evidence 28% · extract evidence 25% | 7563 / 3569 / 5891 (triage / needs_you / extraction) | 16.2 | 12.5 | $0.00 | ROW OF RECORD for round B phase 1: the summary rule alone, the evidence bullet as it was; second of two passes (first: 71 / 74 / 92, not judged); K=4 on 4 slots, so p50s include batching and msgs/min is not comparable with the K=1 rows; traps 4 items (3 on the before row); summaries avg 237 / median 212 chars, 1 of 76 at the 500 cap (before avg 128, none at the cap); kept items carrying any action item 45 (before 51) |
| 2026-09-16 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | none | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260916-233417.json` | 84% / 91% / 70% / 68% / 93% / 75% / 39% / 66% / 26% / 87% | label 82% · action items 56% · summary 64% · needs-you evidence 34% · extract evidence 25% | 6713 / 3317 / 5189 (triage / needs_you / extraction) | 17.0 | 13.4 | $0.00 | round B phase 3 ladder, run A: `none` under the Phase 1 prompt, extract ctx none; second of two passes (first `…232638`: 70 / 70 / 93, not judged); extraction identical to every prior 4B row; K=4; summaries avg 236 chars, 3 of 76 at the cap; against round 0's `none` (78 / 78, old prompt) the summary rule changed what the message alone buys |
| 2026-09-16 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | digest | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260916-235139.json` | 88% / 88% / 70% / 74% / 92% / 76% / 37% / 53% / 30% / 66% | label 89% · action items 62% · summary 68% · needs-you evidence 30% · extract evidence 26% | 8518 / 3825 / 5942 (triage / needs_you / extraction) | 15.9 | 11.9 | $0.00 | round B phase 3 ladder, run B: the digest as its own 900-char fence above the tail (39 items carry one, 17 trimmed), extract ctx digest; second of two passes (first `…234306`: 67 / 70 / 92, not judged); NOT SHIPPED — the booleans did not move by 4 against none or tail3 while label / summary / action items rose 82 → 89 / 64 → 68 / 56 → 62 and needs-you evidence fell 34 → 30; extraction with digest + tail loses people 87 → 66 and project 66 → 53; K=4; summaries avg 245 chars, 6 of 76 at the cap |
| 2026-09-17 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | tail3 | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-000817.json` | 88% / 88% / 71% / 72% / 92% / 78% / 39% / 53% / 25% / 75% | — | 7467 / 3791 / 5703 (triage / needs_you / extraction) | 16.4 | 12.6 | $0.00 | round B phase 3 ladder, run C: a third `tail3` sample of the Phase 1 prompt for triage / needs-you (matches the `…194031` record within the floor; first pass `…000012`: 72 / 75 / 92), extract ctx tail3 — extraction WITH the tail, NOT SHIPPED: intent 75 → 78, people 87 → 75, project 66 → 53; not judged (the record row is the judged tail3 point); K=4 |
| 2026-09-16 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | none | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260916-032602.json` | 88% / 91% / 78% / 78% / 93% / 75% / 39% / 66% / 26% / 87% | pass 1 judge: label 83% · action items 71% · summary 34% · needs-you evidence 34% · extract evidence 24% (pass 2 not judged) | 2232 / 1513 / 2113 (triage / needs_you / extraction) | 40.3 | 8.9 | $0.00 | context ladder: message alone; second of two passes — pass 1 (2026-09-14) read needs_action 75 / reply_expected 75; 4 slots at 4096 tokens each, no failures |
| 2026-09-14 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | compressed | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-181030.json` | 89% / 89% / 68% / 74% / 91% / 75% / 39% / 66% / 26% / 87% | label 80% · action items 62% · summary 33% · needs-you evidence 25% · extract evidence 24% | 2452 / 1684 / 2028 (triage / needs_you / extraction) | 40.4 | 8.7 | $0.00 | context ladder: digest + two newest tail messages, 300-char clip — lower bound (one pass) |
| 2026-09-14 | bulk | llamacpp/Qwen3.5-4B-UD-Q4_K_XL | tail3 | `golden-run-llamacpp-qwen3-5-4b-ud-q4-k-xl-20260914-190503.json` | 91% / 89% / 66% / 83% / 87% / 79% / 66% / 63% / 29% / 88% | label 82% · action items 53% · summary 16% · needs-you evidence 23% · extract evidence 33% | 2838 / 1716 / 2745 (triage / needs_you / extraction) | 36.9 | 7.5 | $0.00 | candidate bulk model, 1 slot on :8083; second of two passes |
| 2026-09-14 | bulk | llamacpp/Qwen3.5-9B-Q4_K_M | tail3 | `golden-run-llamacpp-qwen3-5-9b-q4-k-m-20260914-200430.json` | 91% / 93% / 64% / 70% / 83% / 82% / 74% / 64% / 24% / 83% | label 78% · action items 62% · summary 24% · needs-you evidence 25% · extract evidence 38% | 4394 / 2648 / 4444 (triage / needs_you / extraction) | 22.8 | 4.6 | $0.00 | candidate bulk model, 1 slot on :8083; second of two passes |
| 2026-09-14 | bulk | llamacpp/Qwen3.8-27B-Q4_K_M (as bulk) | tail3 | `golden-run-llamacpp-qwen3-8-27b-q4-k-m-as-bulk-20260914-223320.json` | 92% / 95% / 72% / 84% / 93% / 86% / 74% / 58% / 32% / 93% | label 89% · action items 64% · summary 41% · needs-you evidence 39% · extract evidence 41% | 13412 / 8969 / 13907 (triage / needs_you / extraction) | 7.1 | 1.5 | $0.00 | accuracy ceiling for these prompts: the prose model doing bulk work, 1 slot, no MTP; second of two passes |
| 2026-09-17 | bulk | vllm-g6e/Qwen3.8-27B-FP8 (as bulk) | tail3 | `golden-run-vllm-g6e-qwen3-8-27b-fp8-as-bulk-20260917-054258.json` | 89% / 95% / 71% / 79% / 93% / 87% / 70% / 62% / 32% / 93% | label 93% · action items 64% · summary 71% · needs-you evidence 42% · extract evidence 34% | 5583 / 3034 / 5733 (triage / needs_you / extraction) | 22.0 | 4.2 | $7.31 | GPU spike: the FP8 27B on vLLM doing the bulk work, one L40S, one stream, no MTP, through an SSH tunnel; against the 2026-09-14 ceiling row above every prompt-stable enum is within 4 points (needs_you 0, intent +1, importance −4, project +4 — the last two on the edge; topics 0, people 0; category −3 and urgency 0 inside their floor) while needs_action −1 / reply_expected −5 are not cleanly comparable — the ceiling row predates Round B's summary rule, which moved the 4B's booleans +5 / +2 and lifts summary 41 → 71 here; extract evidence 41 → 34 is the one rubric field that fell beyond judge noise (the 4B reads 25 there); second of two passes — needs-you and extraction identical on all 100 items, triage (sampled at 0.2) identical on 7; summaries avg 198 chars, none at the cap; priced at $1.86/h at 4.24 msgs/min |
| 2026-09-14 | prose | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | tail (fixed) | `golden-run-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260914-230921.json` | — / — / — / 82% / — / — / — / — / — / — | draft 20% | 6578 / 16589 (reply_decision / draft_reply) | 7.1 | 4.4 | $0.00 | prose slot: reply decision for the 76 gold-keep items (scored as reply_expected) + 25 drafts for the reply-rubric items, judged in Phase 3; message + tail only; second of two passes |
| 2026-09-16 | prose | llamacpp/Qwen3-4B (decision) | tail (fixed) | `golden-run-llamacpp-qwen3-4b-decision-20260916-031409.json` | — / — / — / 64% / — / — / — / — / — / — | drafts not judged | 1158 / 2715 (reply_decision / draft_reply) | 38.6 | 26.2 | $0.00 | the 4B on ReplyDecisionTask, served by the bulk model on :8082 (4 slots at 4096): reply decision for the 76 gold-keep items (scored as reply_expected) + 25 drafts; message + tail only; second of two passes, both 64% at temperature 0; recommendation item 5's missing half |
| 2026-09-15 | bulk | bedrock/nemotron-nano-3-30b | tail3 | `golden-run-bedrock-nemotron-nano-3-30b-20260915-011152.json` | 88% / 88% / 64% / 65% / 79% / 69% / 69% / 65% / 31% / 80% | label 72% · action items 36% · summary 19% · needs-you evidence 8% · extract evidence 15% | 1129 / 847 / 1226 (triage / needs_you / extraction) | 86.8 | 70.7 | $0.28 | OpenAI wire; K=4 |
| 2026-09-15 | bulk | bedrock/nemotron-super-3-120b | tail3 | `golden-run-bedrock-nemotron-super-3-120b-20260915-011547.json` | 91% / 95% / 74% / 75% / 93% / 83% / 79% / 70% / 37% / 93% | label 87% · action items 67% · summary 47% · needs-you evidence 19% · extract evidence 41% | 1284 / 883 / 1218 (triage / needs_you / extraction) | 79.1 | 70.7 | $0.69 | OpenAI wire; K=4 |
| 2026-09-15 | bulk | bedrock/glm-4.7-flash | tail3 | `golden-run-bedrock-glm-4-7-flash-20260915-012130.json` | 84% / 92% / 68% / 74% / 76% / 76% / 82% / 87% / 28% / 83% | label 87% · action items 60% · summary 21% · needs-you evidence 22% · extract evidence 28% | 1296 / 998 / 1304 (triage / needs_you / extraction) | 55.8 | 63.9 | $0.30 | OpenAI wire; K=4 |
| 2026-09-15 | bulk | bedrock/gemma-3-12b-it | tail3 | `golden-run-bedrock-gemma-3-12b-it-20260915-012458.json` | 91% / 93% / 72% / 87% / 71% / 86% / 79% / 80% / 25% / 86% | label 71% · action items 62% · summary 30% · needs-you evidence 5% · extract evidence 17% | 1302 / 700 / 1178 (triage / needs_you / extraction) | 82.9 | 71.5 | $0.39 | OpenAI wire; K=4 |
| 2026-09-15 | bulk | bedrock/deepseek-v3.2 | tail3 | `golden-run-bedrock-deepseek-v3-2-20260915-013258.json` | 96% / 92% / 68% / 74% / 89% / 83% / 79% / 71% / 20% / 95% | label 91% · action items 69% · summary 42% · needs-you evidence 39% · extract evidence 22% | 1905 / 1125 / 1818 (triage / needs_you / extraction) | 27.8 | 26.3 | $2.41 | OpenAI wire; K=4 |
| 2026-09-15 | bulk | bedrock/claude-haiku-4.5 | tail3 | `golden-run-bedrock-claude-haiku-4-5-20260915-013812.json` | 86% / 88% / 72% / 82% / 92% / 84% / 63% / 67% / 34% / 91% | label 95% · action items 62% · summary 53% · needs-you evidence 48% · extract evidence 38% | 1995 / 1593 / 1802 (triage / needs_you / extraction) | 93.9 | 44.7 | $8.27 | Converse, no temperature; K=4 |
| 2026-09-15 | prose | bedrock/claude-sonnet-5 | tail (fixed) | `golden-run-bedrock-claude-sonnet-5-20260915-014246.json` | — / — / — / 68% / — / — / — / — / — / — | draft 40% | 2409 / 4374 (reply_decision / draft_reply) | 47.4 | 59.8 | $6.80 | Converse, no temperature; K=4 |
| 2026-09-15 | prose | bedrock/claude-opus-5 | tail (fixed) | `golden-run-bedrock-claude-opus-5-20260915-014610.json` | — / — / — / 78% / — / — / — / — / — / — | draft 48% | 2162 / 5365 (reply_decision / draft_reply) | 51.9 | 56.8 | $17.17 | Converse, no temperature; K=4 |
| 2026-09-15 | prose | bedrock/nemotron-super-3-120b | tail (fixed) | `golden-run-bedrock-nemotron-super-3-120b-20260915-014735.json` | — / — / — / 66% / — / — / — / — / — / — | draft 28% | 760 / 1319 (reply_decision / draft_reply) | 70.7 | 189.1 | $0.24 | OpenAI wire; K=4 |
| 2026-09-15 | prose | bedrock/deepseek-v3.2 | tail (fixed) | `golden-run-bedrock-deepseek-v3-2-20260915-015039.json` | — / — / — / 78% / — / — / — / — / — / — | draft 40% | 1045 / 3011 (reply_decision / draft_reply) | 20.7 | 64.0 | $0.84 | OpenAI wire; K=4 |
| 2026-09-16 | prose | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | tail (fixed) | `golden-run-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260916-210618.json` | — / — / — / 82% / — / — / — / — / — / — | draft 32% | 6138 / 12324 (reply_decision / draft_reply) | 8.2 | 5.0 | $0.00 | invention rules v2, draft budget 768, K=1 with MTP; invented 11 of 17 failing; second of two passes |
| 2026-09-16 | prose | bedrock/claude-opus-5 | tail (fixed) | `golden-run-bedrock-claude-opus-5-20260916-211138.json` | — / — / — / 78% / — / — / — / — / — / — | draft 48% | 2586 / 6324 (reply_decision / draft_reply) | 44.1 | 34.5 | $17.85 | invention rules v2, draft budget 768; invented 11 of 13 failing; 25 throttle retries, all recovered; Converse, no temperature; K=4 |
| 2026-09-16 | prose | bedrock/claude-sonnet-5 | tail (fixed) | `golden-run-bedrock-claude-sonnet-5-20260916-211454.json` | — / — / — / 67% / — / — / — / — / — / — | draft 68% | 2416 / 4498 (reply_decision / draft_reply) | 48.0 | 59.8 | $7.02 | invention rules v2, draft budget 768; invented 6 of 8 failing; Converse, no temperature; K=4 |
| 2026-09-16 | prose | bedrock/deepseek-v3.2 | tail (fixed) | `golden-run-bedrock-deepseek-v3-2-20260916-211815.json` | — / — / — / 72% / — / — / — / — / — / — | draft 36% | 961 / 2095 (reply_decision / draft_reply) | 35.2 | 109.3 | $0.90 | invention rules v2, draft budget 768; invented 9 of 16 failing; OpenAI wire; K=4 |
| 2026-09-16 | prose | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | tail (fixed) | `golden-run-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260916-214911.json` | — / — / — / 82% / — / — / — / — / — / — | draft 24% | 6077 / 13269 (reply_decision / draft_reply) | 8.2 | 5.0 | $0.00 | invention rules v3 SHIPPED, draft budget 768, K=1 with MTP; invented 14 of 19 failing; identical drafts to pass 1, which a second judge run scored 32% / invented 12 — judge noise ±2 |
| 2026-09-16 | prose | bedrock/claude-opus-5 | tail (fixed) | `golden-run-bedrock-claude-opus-5-20260916-215244.json` | — / — / — / 75% / — / — / — / — / — / — | draft 68% | 2252 / 5606 (reply_decision / draft_reply) | 50.9 | 55.6 | $17.98 | invention rules v3 SHIPPED, draft budget 768; invented 6 of 8 failing; Converse, no temperature; K=4 |
| 2026-09-17 | prose | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | tail (fixed) | `golden-run-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260917-020022.json` | — / — / — / 82% / — / — / — / — / — / — | draft 20% | 6110 / 12453 (reply_decision / draft_reply) | 8.4 | 4.9 | $0.00 | invention rules v4 SHIPPED (the two-options example no longer contradicts the owner-only bullet); 5 of 25 against v3's 6, inside the judge's ±2; invented 14 of 20 — the SAME 14 items as v3, none new, none cleared, with 21 of 25 texts changed; drafts asking a question 3 → 8; max completion 322; MTP; K=1; pass 2 `…021535` byte-identical on all 25 drafts and every decision (this row cites the judged pass 1) |
| 2026-09-18 | prose | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | tail (fixed) | `golden-run-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260918-000138.json` | — / — / — / 82% / — / — / — / — / — / — | draft — (not re-judged) | 6087 / 12515 (reply_decision / draft_reply) | 8.5 | 5.0 | $0.00 | Round C phase 4 reproduction on the branch tip (three lanes, DraftPolicy, streamed client in the tree; the harness itself calls the plain path): all 76 decisions and all 25 drafts BYTE-IDENTICAL to the v4 row `…-020022` two lines up, so the round moved no accuracy by construction and the drafts were not re-judged; prompts, budgets, MTP and K=1 unchanged; 76 items in 910 s |
| 2026-09-17 | prose | vllm-g6e/Qwen3.8-27B-FP8 | tail (fixed) | `golden-run-vllm-g6e-qwen3-8-27b-fp8-20260917-044752.json` | — / — / — / 82% / — / — / — / — / — / — | draft 24% | 1947 / 6606 (reply_decision / draft_reply) | 22.9 | 13.6 | $2.28 | GPU spike: the same 27B as `Qwen/Qwen3.8-27B-FP8` on vLLM 0.29.0, one L40S (AWS g6e.xlarge), no MTP, 32K ctx, one stream, reached through an SSH tunnel (~50 ms a call, nothing against these p50s); invention rules v4, draft budget 768, K=1; 6 of 25 against the local row's 5 with invented 10 of 19 failing against 14 of 20 — the favourable side of judge noise plus FP8 text drift, recorded as a tie; second of two passes, the first (`…044212`) identical on all 76 decisions and all 25 drafts; wall-clock tok/s (vLLM sends no timings block); priced at the box's $1.86/h on-demand rate at the measured msgs/min, not per token — the harness itself prices a localhost URL at $0.00 |
| 2026-09-17 | prose | vllm-g6e/Qwen3.8-27B-FP8 | tail (fixed) | `golden-run-vllm-g6e-qwen3-8-27b-fp8-20260917-045439.json` | — / — / — / 82% / — / — / — / — / — / — | — | 2377 / 7382 (reply_decision / draft_reply) | 18.6 | 43.1 | $0.72 | GPU spike, throughput read only — one pass, not judged; its own decision read 82 as well, but the judged accuracy is the K=1 row's; four streams lift throughput 3.2× while the p50s rise 22% / 12%, which is what batching on one GPU looks like; priced at $1.86/h at 43.1 msgs/min; K=4 |
| 2026-09-17 | prose | vllm-g6e/Qwen3.8-27B-FP8+MTP | tail (fixed) | `golden-run-vllm-g6e-qwen3-8-27b-fp8-mtp-20260917-064431.json` | — / — / — / 83% / — / — / — / — / — / — | draft 28% | 1313 / 3711 (reply_decision / draft_reply) | 37.6 | 21.6 | $1.43 | GPU spike, the FP8 repo's MTP head loaded (`--speculative-config '{"method":"mtp","num_speculative_tokens":2}'`, ~6.5 min of recompile): one pass; 7 of 25 against the no-MTP row's 6, invented 10 of 18 failing; 75 of 76 decisions and 9 of 25 drafts byte-identical to the no-MTP row — vLLM's speculation is not bit-exact under FP8, so the drafts were judged on their own; draft p50 3.7 s against 12.5 s locally (3.4×), decode 37.6 tok/s against 8.4; priced at $1.86/h at 21.6 msgs/min |
| 2026-09-17 | prose | vllm-g6e/Qwen3.8-27B-FP8+MTP | tail (fixed) | `golden-run-vllm-g6e-qwen3-8-27b-fp8-mtp-20260917-064603.json` | — / — / — / 82% / — / — / — / — / — / — | — | 2196 / 5144 (reply_decision / draft_reply) | 23.2 | 54.6 | $0.57 | GPU spike, MTP on, throughput read only — one pass, not judged; 54.6 msgs/min is Opus 5's 55.1 at $0.57 against $18.03; the concurrency figure Round C's C1 reads for a GPU-served prose slot; priced at $1.86/h at 54.6 msgs/min; K=4 |
| 2026-09-17 | prose | bedrock/claude-opus-5 | tail (fixed) | `golden-run-bedrock-claude-opus-5-20260917-014357.json` | — / — / — / 78% / — / — / — / — / — / — | draft 68% | 2264 / 5580 (reply_decision / draft_reply) | 50.5 | 55.1 | $18.03 | invention rules v4 SHIPPED; 17 of 25 with invented 6 of 8, identical to v3; ONE pass (Converse, no temperature — a noisier read than the local row by design of the budget); max completion 672; K=4 |

**What the first rows say** (2026-09-14, all at `GOLDEN_K=1`, keep-only, every
row the second of two passes unless its note says otherwise; the 2026-09-16
rows are read in items 5 and 7). Bigger bulk
models buy the enums, not the booleans: category and urgency reach 91–95% on
anything from Qwen3.5-4B up, against 89% on the shipping 4B, and importance
jumps from 39% to 66–74% — but needs-you FALLS as the bulk model grows (92 →
87 → 83) until the 27B recovers it (93), and project is flat or worse. The
context ladder on the 4B is the row worth re-reading: the thread tail lowers
needs-action (75% alone → 66% with it) and reply-expected (75 → 70; the
`none` rung's second pass of 2026-09-16 reads 78 and 78, item 7), on the
items whose gold label needs the tail as much as on the rest, and the digest
rung sits between the two. Extraction was identical across those rungs by
construction — it had no thread field until round B phase 3, and since then
it reads its own knob (`GOLDEN_EXTRACT_CTX`), so a `GOLDEN_CTX` rung still
moves nothing in it. The 27B doing bulk work is the ceiling
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

**What the judged rows say** (2026-09-14, keep-only, the same Claude Code judge
for every row). Read the rubric column against the `baseline-cc` half of the
baseline cell, never against the Opus 4.5 half: the same stored output scores
54% on summary under one reader and 37% under the other, which is the size of
the judge effect and the reason the column compares rows only. The replayed 4B
lands where the re-judged baseline does (label 84 vs 82, summary 39 vs 37,
evidence 25 / 27 vs 22 / 29). The context ladder barely moves the rubric fields
on the 4B — summary 34 / 39 / 33 and action items 71 / 67 / 62 for none / tail3
/ compressed — so the tail buys a little on action items and nothing on
summaries. The candidate small models are worse writers than the shipping 4B
even where they are better classifiers: Qwen3.5-4B passes 16% of summaries and
Qwen3.5-9B 24%, against 39%, while both write better extract evidence (33% and
38% against 25%). The 27B as bulk is the ceiling on label, summary and both
evidence fields (89 / 41 / 39 / 41) and even it passes fewer than half the
summaries. The summary failures are almost entirely omitted required facts, not
asserted traps: across the six bulk rows the forbidden-fact traps fire on 0–4
items of 76 while 46–60 items miss a required fact, and summaries average
113–129 characters against a 500-character cap. That is a prompt-and-budget
problem, not a model problem, and it goes on the follow-up list ahead of any
model swap. Drafts: 5 of 25 pass on the 27B; of the 20 failures, 10 invent an
owner-only fact, 9 commit a forbidden move and 8 miss a required point
(overlapping), at an average of 148 characters — the draft prompt needs its
"ask, don't invent" rule made explicit before any cloud model is compared on
this column.


**What the cloud rows say** (2026-09-15, keep-only, `GOLDEN_K=4`, the same
judge, second pass kept, every target through `bench-verify` first, `retried 0`
on every pass). Read the enum columns against the replayed 4B and the
27B-as-bulk rows, and the rubric column against `baseline-cc`. Nemotron Super
3 120B is the first bulk candidate that beats the shipping 4B on needs_action
(74 against 66) without losing needs_you (93 against 92) and matches or exceeds the
local 27B ceiling on every enum but reply_expected (75 against 84) — at 70
messages a minute against the 27B's
1.5, and $0.69 per thousand messages. It also writes the best summaries of any
non-Claude row (47%). Haiku 4.5 on Converse is the best writer of any bulk row
— label 95%, summary 53%, needs-you evidence 48%, every one above the 27B's 89
/ 41 / 39 — but at twelve times the 120B's price and with the weakest
importance (63%) of the cloud rows. DeepSeek V3.2 has the best category (96%)
and the best label of the non-Claude rows (91%) and is 2.7x slower and 3.5x
dearer than the 120B for no gain on the booleans. Gemma 3 12B and GLM 4.7 Flash classify well (reply_expected 87%,
project 87%) and write badly (needs-you evidence 5%, summary 21%); Nemotron
Nano 3 is worse than the 4B on every rubric field. No cloud model passes more
than 53% of summaries, which confirms the summary-omission finding above as
model-independent. On the prose slot, Opus 5 and Sonnet 5 pass 12 and 10 of
25 drafts (48% and 40%) against the local 27B's 5, DeepSeek matches Sonnet at
40% for an eighth of the price, and Nemotron Super passes 7 at 189 messages a
minute; the reply decision is best on the local 27B (82%) with Opus and
DeepSeek at 78% — Sonnet's 68% is below the 4B's own triage boolean. The draft
failures have one shape everywhere: of the failing drafts, 10–15 per model
invent an owner-only fact (Sonnet 12 of 15, Opus 10 of 13, DeepSeek 10 of 15,
Nemotron 15 of 18, the 27B 10 of 20), so the "ask, don't invent" prompt change
is model-independent and comes before any prose model swap. The Converse rows
sampled at the models' default temperature; the OpenAI-wire rows ran the
handlers' own.

**Prompt round (2026-09-16), phase 1 — the summary rule, and an evidence
sentence that was measured and not shipped.** The triage prompt's summary
bullet now names what the sentence must carry — the concrete thing the message
is about, what it asks of the reader or that it asks nothing, and the date,
amount, place or name the matter turns on — and forbids both guessing a fact
the message does not state and restating the label. The before is the replayed
4B `tail3` row of 2026-09-14 (`…174707`, K=1) and the row of record is
`…194031`, the second of two passes at K=4 with the summary rule alone; K is
the one setting that differs between the pair, and it is not what moved the
numbers, because extraction and the needs-you verdict reproduced the K=1 row
exactly at K=4. Keep-only, the summary went 39% to 63% on the row of record
and read 66 / 63 / 63 / 63 across the four judged runs of the phase, so the
gain is twenty-plus points and stable, well outside any move the judge has
shown between identical passes. needs_action went 66 to 71 (71–72 across the
runs) and reply_expected 70 to 72 (72–76); category and urgency went 89 to 88,
inside the floor; needs_you is unchanged at 92; extraction is unchanged by
construction, its prompt having not changed. The forbidden-fact traps fired on
4 items against 3 before — one first pass reached 5, which is above the
ceiling of 4 the phase set for itself and is recorded here as such. Summaries
nearly doubled in length, an average of 237 characters against 128, with 1 of
76 reaching the 500-character hard clamp on the row of record and 2 to 4 on
the other passes; a summary that reaches the clamp is cut mid-word. The cost
is action items, 67% to 60% (58–60 across the four runs), which is 3 of 45
judged items and outside the four-point guard the round set. The mechanism is
in the counts rather than guessed at: kept items carrying any action item fell
from 51 to 45 (42 on the two runs that also carried evidence bullet v1), the
rubric points the action items now miss are required steps (10 to 14 missing
points) rather than invented ones ("none for the owner" failures went 6 to 5),
and the same conservatism is what lifted `needs_action` — recorded as the
trade the phase shipped, with the action-items bullet itself untouched and the
next experiment. The needs-you evidence sentence (recommendation item 2) was
run and is NOT shipped: a bullet asking for the specific words that point at
the owner lifted the judged sentence 27 to 36 but put 27 of 64 sentences at
the 300-character clamp against 1 before, and cost the verdict 92 to 89, while
a second wording asking for one short sentence under thirty words kept every
sentence under the clamp at an average of 121 characters and scored 9% with
the verdict at 86. The verdict is the chip the owner sees and the sentence
sits behind it, so the original bullet ships — 28% on the row of record,
inside the noise of its 27 — and both rows stay in the ledger for the next
attempt to read first. The lesson is worth its own sentence: a rubric pass
rate does not see a clamp, so every prompt change that lengthens a shown field
now gets an at-the-cap count on the same tally.

**Prompt round (2026-09-16), phase 2 — drafts that ask instead of invent, and
the budgets.** The draft prompt's invention rule became invention *rules*.
Version 2 added four bullets: a fact only the owner knows is never supplied
and is asked for or left as a bracketed placeholder; the owner's own next step
is not an invention; the whole of what the sender proposed is answered, never
half of it; and the reply matches the sender's register. All four prose models
were re-run and re-judged on v2, none met the round's exit of three or fewer
invented per model, and the plan's one allowed revision was spent the same
day. Version 3, which ships, changes three things: the two-options bullet now
says that two answers differing only by a fact the owner has not given are one
option that asks; the owner-only bullet asks the model to enumerate the
missing owner-only facts before it writes and states outright that accepting
or declining what the sender proposed IS supplying such a fact; and the
next-step bullet no longer licenses proposing a time — it permits asking to
set one up, as long as it names no time. Per the plan, v3 was re-run on the
27B and on the worst cloud model under v2, which was Opus 5; Sonnet 5 and
DeepSeek V3.2 are measured on v2 only. Drafts passing of the 25 reply-rubric
items, baseline → v2 → v3: the 27B 5 → 8 → 6, Opus 5 12 → 12 → 17, Sonnet 5
10 → 17, DeepSeek V3.2 10 → 9. Invented, counted over each row's failing
drafts: the 27B 10 of 20 → 11 of 17 → 14 of 19, Opus 10 of 13 → 11 of 13 → 6
of 8, Sonnet 12 of 15 → 6 of 8, DeepSeek 10 of 15 → 9 of 16. So the exit was
missed on every model and the best any row reached is six — Opus on v3 and
Sonnet on v2 — twice the number the round set out to hit, and the shipped
change is worth five drafts on Opus and nothing on the local model.

The per-item counts say why, and they are the finding of the phase. On the
27B the same nine items are flagged invented under baseline, v2 and v3 — plus
two more under v2 and three under v3 — while 24 of the 25 draft texts changed
under v2, so the model rewrote almost everything and went on supplying the
same facts. On Opus the overlap is real but moves: v2 flagged the same eight
items baseline did plus three, and v3 flagged six, all of them among v2's
eleven. The shapes agree. Drafts containing a question, baseline → v2 → v3,
were 9 → 4 → 3 on the 27B and 13 of 25 on Opus v3; drafts offering two options
went 10 → 17 → 14 on the 27B and 14 of 25 on Opus v3; and not one 27B draft in
any pass left a bracketed placeholder, against none on Opus v3 either. A local
model that writes fewer questions under a rule telling it to ask more is not
failing to understand the wording, and no further wording is likely to move
it: the next lever on the 27B is structural — a separate owner-only-facts step
that runs before drafting and hands the writer the list — which is a Round C
or F item, not a prompt edit.

Three caveats travel with the numbers. The judge has a noise floor of its own
and this phase measured it: the 27B's v3 pass 1 (`…213355`) produced drafts
byte-identical to the row of record on all 25 items, and a second judge run
over those identical drafts scored 8 of 25 with invented 12, against the row
of record's 6 and 14 — two either way on both counts, so no two-point
difference in this paragraph is a finding. The decision stage did not change
and its prompt was untouched: the 27B reproduced 82% on every pass, while the
cloud rows sample at their default temperature and DeepSeek's decision moved
six items between its own two passes today (78 then 72) and Sonnet's five, so
cloud decision numbers carry a floor of about six points and none of today's
decision movement is a prompt effect. And the local row is K=1 while every
cloud row is K=4. On budgets the round is clean: no run's draft reached 700
completion tokens — the largest is 655, on Opus v3 — so the 768 ceiling holds
with room, and the evidence sentence reached its 300-character clamp on one
Opus draft under v2 and one under v3 and on nothing else. Draft p50 on the 27B
is 12.3 s on v2 and 13.3 s on v3 against the 2026-09-14 row's 16.6 s, and
that gap is MTP rather than the budget — the 2026-09-14 row is pre-MTP. The
budget bought no speed at all, which `bench-prose` says plainly: the row of
record (`prose-…-20260917-012727.json`, second of two passes, re-run on the
round's whole-branch review because the 2026-09-16 row's recap leg had run
at the generic 512 while saying 384 — a harness gap, since fixed) reads draft
p50 16.1 s, recap 11.8 s and name 8.6 s against round 0's 16.1 s kept /
14.9 s first pass, 12.7 s and 8.5 s — unchanged within that bench's own
noise. The reason is that neither ceiling is ever reached: the bench's drafts
generated 1,104 tokens over five, about 221 each against 768, and its recaps
537 over three, about 179 against 384 — the same token totals to the digit as
the 512 run, which is what "the budget binds nothing" looks like at
temperature 0. What a smaller ceiling buys is the WORST case. A
rambling or wedged generation now stops at 768 tokens, roughly 43 s of
generation, where 1,536 would have run to about 86 s — and that, not any p50,
is what lets the prose timeout come down from 120 s to 90 s. The phase's other
budget went the same way: the confirm task's charter clamp was raised to 800
and 1200 against the same cards and made the 4B worse both times —
`storyline.id` 81 / 78 / 77%, forbidden-accept 20 / 25 / 26% — so the cap
stays at 400 and only the knob that measured it is new. The confirm rows carry
that ladder in full. The v3 text carried one contradiction its measurement did not resolve, found on the round's whole-branch review: its two-options bullet still offered "accepting versus declining" as its example and its stance examples read "Confirm Friday" / "Decline politely", while the owner-only bullet said accepting or declining what the sender proposed IS supplying a fact only the owner holds. A model reading both was being told two things, which is a plausible part of why the 27B's nine flagged items never moved. v4 (2026-09-17) is the fix, measured before it shipped: the example replaced by two answers the thread can support, the conjunct "AND the thread already holds what each one needs" added, and "accepting or declining what was proposed" added to the one-option-that-asks list — under a rule written first (27B within 2 drafts of v3's 6 and within 2 invented of 14; Opus within 3 of 17): Opus 5 read 17 of 25 with 6 of 8 invented, identical; the 27B read 5 of 25 with the same 14 items flagged, none new and none cleared, across 21 changed texts (fourteen against the nine above: nine is the set flagged under baseline, v2 and v3 alike, fourteen is v3's whole flagged set). v4 shipped — the contradiction gone at no measured cost — and the local model's invention is now known not to hinge on that example either.

**Prompt round (2026-09-16/17), phase 3 — the digest as its own fence,
extraction's first thread, and the ladder decided.** What was built: a
`threadDigest` field on all three bulk tasks, rendered as its own
`thread_digest` fence above the tail and capped at 900 characters by
`fitThreadDigest`, which trims whole lines from the OLD end and keeps the
header; a shared `buildThreadTailText` so triage, needs-you and extraction
render a tail the same way; a `digest` rung that supersedes `compressed`; a
`GOLDEN_EXTRACT_CTX` knob giving extraction its own axis; and a Dart port of
the packer's digest builder, kept in `app/test/fixtures/thread_digest.dart`
because no stage ships one. The design was six passes on the 4B at
`GOLDEN_K=4` under Phase 1's prompt, keep-only (76 items), second pass kept:
run A `none` / `none`, run B `digest` / `digest`, run C `tail3` / `tail3`,
with `none` as the control and the temperature-0 stages reproducing token for
token inside each pair. The rule was pre-registered — the message alone had to
beat the tail by 4 points on `needs_action` or `reply_expected` before triage
would drop the tail, and only then would the digest be tried — and it failed:
`none` read 70 / 70 then 70 / 68 against `tail3`'s 72 / 75 then 71 / 72 and a
record of 71 / 72, so triage keeps the tail and the digest branch was never
reached (against `none` the digest moved needs_action −3 / 0 and
reply_expected 0 / +6, which would have failed it anyway). Needs-you keeps the
tail as well, on verdict 92 against 93 and judged evidence 30 against 34; and
extraction stays message-alone, because the tail buys intent 75 → 78 but costs
people 87 → 75 and project 66 → 53, while the digest costs people 87 → 66 and
project 66 → 53. So no stage ships the digest. What it DID move is the reason
the fields stay: on triage the judged label went 82 → 89, the summary 64 → 68
and action items 56 → 62 (against the tail3 record's 86 / 63 / 60), and
`reply_expected` on the 21 keep items whose gold label needs the thread went
10 → 13 of 21 — bought at needs-you evidence 34 → 30, the extraction losses
above, triage p50 +27% at K=4 and throughput 13.4 → 11.9 messages a minute,
with the judge's own noise floor at 2 points. Round 0's finding that `none`
beat `tail3` by 12 and 8 does not survive Phase 1's summary rule: under the
new prompt `none` reads 70 / 70 where round 0 read 78 / 78 on the old one, so
a context result is valid only for the prompt it was measured with. The
follow-up candidate is a triage-only digest judged on summary and label; the
27B never saw the digest, because the bulk stages run on the 4B.

**GPU spike (2026-09-17) — the 27B on an L40S, apples to apples.** The
question was whether `Qwen/Qwen3.8-27B-FP8` on vLLM 0.29.0 on an AWS
`g6e.xlarge` (one L40S, $1.86 an hour on-demand, us-east-2 — the only one of
the three regions tried with g6e capacity on 2026-09-16) gives the same accuracy as the local 27B
(llama.cpp Q4_K_M with MTP, one slot) with better throughput: roadmap Round E
item E3, run early between Rounds B and C so the later rounds read its
numbers, with no harness, prompt or configuration change and nothing adopted.
Same targets, same knobs but a 32K context against the Mac's 16K, the v4
prompts, two passes with the second kept for every row of record (the two
K=4 rows and the MTP golden row are single passes and say so), the same
Opus judge; the box reached through an SSH tunnel on a local port
(about 50 ms a call, nothing against these p50s); tok/s wall-clock because
vLLM sends no timings block; every price the box's hourly rate at the
measured throughput, never a per-token tariff, because the harness prices a
localhost URL at $0.00. The read rules were written before the runs
(`tmp/PLAN-gpu-spike.md`, decision 3): decision within 4 of 82, drafts
within 3 of 5 and invented within 3 of 14, every prompt-stable as-bulk enum
within 4 of the 2026-09-14 ceiling row. What came back, box against local:
the reply decision **82% against 82%**, identical; drafts passing **6 of 25
against 5** (inside its band), invented **10 of 19 failing against 14 of
20** — four fewer, one past the pre-registered ±3 band on the favourable
side, with the judge's own re-read noise at ±2 on this count; recorded as a
tie, not a gain; draft p50 **6.6 s against 12.5 s** on the golden run (1.9×) and **10.8 s
against 16.1 s** on `bench-prose` (1.5×, where the FP8 model wrote longer
drafts, ≈ 273 tokens against ≈ 221); decode **22.9 against 8.4 tok/s** on the
golden run (2.7×) and 24.6 against 13.9 on the bench (1.8×); names 4.4 s
against 8.6, recaps 7.4 s against 11.8; throughput **13.6 against 4.9
messages a minute** single-stream (2.8×) and **43.1 at K=4** with p50s up
only 22% / 12%; price **$2.28 per thousand messages at K=1, $0.72 at K=4**
against $0.00 local and $18.03 for Opus 5. Then the MTP head the FP8 repo
ships, which vLLM loads after ~6.5 min of recompile: drafts **5.7 s** on the
bench at 46.5 tok/s and **3.7 s** on the golden run, names 2.4 s, recaps
3.6 s — 2.8× / 3.6× / 3.3× the local MTP row — with **21.6 messages a minute
single-stream and 54.6 at K=4**, which is Opus 5's 55.1 at $0.57 per
thousand; the decision read 83%, and because only 9 of 25 drafts came back
byte-identical to the no-MTP pass (speculation under FP8 is not bit-exact)
the MTP drafts were judged on their own: **7 of 25, invented
10 of 18 failing**. As bulk, the FP8 27B read 89 / 95 / 71 / 79 / 93 / 87 / 70 / 62
/ 32 / 93 against the local ceiling's 92 / 95 / 72 / 84 / 93 / 86 / 74 / 58
/ 32 / 93: every prompt-stable enum within the 4-point band (needs_you 0,
intent +1, importance −4, project +4 — the last two on its edge — topics 0,
people 0), category −3 and urgency 0 inside their floor, and the two booleans −1 / −5 not cleanly comparable, because the
ceiling row predates Round B's summary rule — the rule that moved the 4B's
booleans +5 / +2 and its summary 39 → 63, and that lifts summary 41 → 71
here;
judged label 89 → 93, action items 64 → 64, needs-you evidence 39 → 42, and
extract evidence 41 → 34, the one rubric field that fell beyond judge noise
(the 4B reads 25 there). The confirm task read `storyline.id` 87% against the
local 27B's 90%, forbidden accepts 9% against 7%, at 4.3 messages a minute
against 2.0. Reproducibility on the box: the two
prose passes identical on all 76 decisions and 25 drafts, needs-you and
extraction identical on all 100 items, triage (sampled at 0.2) identical on
7, the two confirm passes identical on every count. **Decision (E3): (a).**
The box is a valid prose target — the same accuracy: decision and drafts
inside their pre-registered bands, invention one past its band on the
favourable side, every prompt-stable as-bulk enum within 4 — and with the
MTP head, the optional configuration, it clears the 2× per-stream bar (2.8× on drafts,
3.4× on the golden draft leg) while four streams give eleven times the Mac's
throughput at $0.57 per thousand messages; without MTP it is 1.5–1.9× per
stream — between the rule's letters (≥ 2× for (a), < 1.5× for (c)) — and its
case is concurrency alone. Round E's E1 makes it a
first-class target behind consent, with MTP on in its serve script; Round
C's C1 sizes prose parallelism from the K=4 rows; nothing is adopted now —
`local.mk` and Settings stay on the Mac, and the roadmap's economics
paragraph still holds for one user.

#### Storyline confirm

The confirm task against the gold registry, per the block above.
`storyline.id` is the scorer's number over the items it counts — a `may` item
is skipped unless it was filed under a forbidden slug, so the denominator is
98 or 99 — and the rest are the replay's own rates.

| date | bulk label | cards from | run file | storyline.id | gold-accept must / should | forbidden-accept | extra-accept | derived none on gold-none | low-yes | p50 ms | calls/min | msgs/min | $/1K msgs | note |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-09-15 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-174707.json` | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-storyline-20260915-031444.json` | 80/98 (82%) | 47/48 (98%) / 10/15 (67%) | 17/88 (19%) | 14/300 (5%) | 26/35 (74%) | 0 | 1146 | 51.4 | 11.3 | $0.00 | shipping 4B; cards from its own tail3 run; ties 15; derived gold 50 / none 32 / other 18; 4 storylines without items, 13 gold candidates with an empty People line, 22 charters over the clamp |
| 2026-09-15 | llamacpp/Qwen3.8-27B-Q4_K_M (as bulk) | `golden-run-llamacpp-qwen3-8-27b-q4-k-m-as-bulk-20260914-223320.json` | `golden-run-llamacpp-qwen3-8-27b-q4-k-m-as-bulk-storyline-20260915-045507.json` | 88/98 (90%) | 43/48 (90%) / 8/15 (53%) | 6/88 (7%) | 1/300 (0%) | 33/35 (94%) | 0 | 6373 | 9.2 | 2.0 | $0.00 | 27B in the bulk slot; cards from its own as-bulk run; ties 3; derived gold 50 / none 45 / other 5; 4 storylines without items, 13 gold candidates with an empty People line, 22 charters over the clamp |
| 2026-09-17 | vllm-g6e/Qwen3.8-27B-FP8 (as bulk) | `golden-run-vllm-g6e-qwen3-8-27b-fp8-as-bulk-20260917-054258.json` | `golden-run-vllm-g6e-qwen3-8-27b-fp8-as-bulk-storyline-20260917-062927.json` | 85/98 (87%) | 41/48 (85%) / 7/15 (47%) | 8/88 (9%) | 0/300 (0%) | 33/35 (94%) | 0 | 2964 | 19.7 | 4.3 | $7.14 | GPU spike: the FP8 27B on vLLM in the bulk slot, one L40S, one stream, charter cap 400; cards from its own as-bulk run; against the local 27B's 2026-09-15 row (90% / 90% / 53% / 7%) within 3 on `storyline.id` (gold-accept must 43 → 41 of 48, should 8 → 7 of 15, forbidden 6 → 8 of 88) at 2.2× the throughput; ties 3; derived gold 46 / none 48 / other 6; 4 storylines without items, 13 gold candidates with an empty People line, 22 charters over the clamp; second of two passes, the first (`…060618`) identical on `storyline.id` and every derived count; priced at $1.86/h at 4.34 msgs/min |
| 2026-09-15 | bedrock/nemotron-super-3-120b | `golden-run-bedrock-nemotron-super-3-120b-20260915-011547.json` | `golden-run-bedrock-nemotron-super-3-120b-storyline-20260915-050910.json` | 86/97 (89%) | 45/48 (94%) / 7/15 (47%) | 15/88 (17%) | 2/299 (1%) | 32/35 (91%) | 0 | 909 | 251.6 | 55.5 | $0.75 | OpenAI wire; cards from its own Phase 4 run; the failed call's item is unfiled (not attempted); 1 failed calls; ties 5; incomplete 1; derived gold 49 / none 41 / other 9; 4 storylines without items, 13 gold candidates with an empty People line, 22 charters over the clamp |
| 2026-09-16 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-174707.json` | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-storyline-20260916-220403.json` | 79/98 (81%) | 47/48 (98%) / 10/15 (67%) | 18/88 (20%) | 14/300 (5%) | 26/35 (74%) | 0 | 2685 | 87.5 | 19.3 | $0.00 | charter cap 400 — the new-harness control, reproduces the 2026-09-15 row within one item; K=4, p50 not comparable with the K=1 rows; cards from the 4B's tail3 run; ties 16; derived gold 49 / none 32 / other 19; 4 storylines without items, 13 gold candidates with an empty People line, 22 charters over the clamp; second of two identical passes |
| 2026-09-16 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-174707.json` | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-storyline-20260916-221503.json` | 76/98 (78%) | 46/48 (96%) / 9/15 (60%) | 22/88 (25%) | 16/300 (5%) | 24/35 (69%) | 0 | 2774 | 84.6 | 18.7 | $0.00 | charter cap 800; K=4, p50 not comparable with the K=1 rows; cards from the 4B's tail3 run; ties 15; derived gold 49 / none 30 / other 21; 4 storylines without items, 13 gold candidates with an empty People line, 1 charter over the clamp; second of two identical passes |
| 2026-09-16 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-174707.json` | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-storyline-20260916-222606.json` | 75/98 (77%) | 46/48 (96%) / 9/15 (60%) | 23/88 (26%) | 15/300 (5%) | 23/35 (66%) | 0 | 2829 | 83.7 | 18.5 | $0.00 | charter cap 1200; K=4, p50 not comparable with the K=1 rows; cards from the 4B's tail3 run; ties 15; derived gold 49 / none 29 / other 22; 4 storylines without items, 13 gold candidates with an empty People line, 0 charters over the clamp; second of two identical passes |
| 2026-09-18 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-174707.json` | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-storyline-20260918-212404.json` | 84/98 (86%) | 45/48 (94%) / 10/15 (67%) | 15/88 (17%) | 11/300 (4%) | 30/35 (86%) | 0 | 1116 | 53.5 | 11.8 | $0.00 | Round D Phase 4: the confirm prompt's three rules, the same cards as the 2026-09-15 row; against that row storyline.id 80 → 84, gold-accept must 47 → 45 of 48, forbidden-accept 17 → 15 of 88, gold-none filed nowhere 26 → 30 of 35, ties 15 → 15; decision 6's rule read forbidden fell and must within 4 points, so the prompt ships, the 10% target not reached on the 4B; second of two passes, the first identical on every count; derived gold 50 / none 37 / other 13 |
| 2026-09-18 | vllm-g6e/Qwen3.8-27B-FP8 (as bulk) | `golden-run-vllm-g6e-qwen3-8-27b-fp8-as-bulk-20260917-054258.json` | `golden-run-vllm-g6e-qwen3-8-27b-fp8-as-bulk-storyline-20260918-224336.json` | 83/98 (85%) | 40/48 (83%) / 7/15 (47%) | 8/88 (9%) | 0/300 (0%) | 33/35 (94%) | 0 | 1773 | 33.3 | 7.4 | $4.19 | Round D Phase 4: the confirm prompt's three rules, the same cards and box as the 2026-09-17 row, bulk slot on llguidance; against that row storyline.id 85 → 83, must 41 → 40 of 48, forbidden-accept 8 → 8 of 88, gold-none filed nowhere 33 → 33 of 35, ties 3 → 4; the prompt is neutral on the 27B; second of two passes, the first identical on every count; derived gold 44 / none 49 / other 7; priced at $1.86/h at 7.4 msgs/min |
| 2026-09-19 | vllm-g6e/Qwen3-4B-Instruct-2507-FP8 | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-174707.json` | `golden-run-vllm-g6e-qwen3-4b-instruct-2507-fp8-storyline-20260919-020723.json` | 80/98 (82%) | 46/48 (96%) / 9/15 (60%) | 19/88 (22%) | 15/300 (5%) | 27/35 (77%) | 0 | 517 | 116.4 | 25.7 | $0.00 | Round D Phase 6: the confirm prompt as shipped in Phase 4, the box's FP8 4B on the vLLM bulk slot, cards as the local 4B rows; second of two passes, the first identical on every count; priced at $1.86/h; ties 15; derived gold 48 / none 34 / other 18; 4 storylines without items, 13 gold candidates with an empty People line, 22 charters over the clamp |
| 2026-09-19 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-174707.json` | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-storyline-20260919-024443.json` | 84/98 (86%) | 45/48 (94%) / 10/15 (67%) | 15/88 (17%) | 11/300 (4%) | 30/35 (86%) | 0 | 1133 | 52.9 | 11.7 | $0.00 | Round D Phase 6: the reproduction on the final tree, one pass, the same cards and prompt as the 2026-09-18 row, identical to it on every count; ties 15; derived gold 50 / none 37 / other 13; 4 storylines without items, 13 gold candidates with an empty People line, 22 charters over the clamp |

**What the confirm rows say.** Handed a candidate list a person wrote, every
model files far better than the app ever has: the shipping app's own filing
scored 42 of 99 with no correct positive, and against the bounded list the 4B
scores 82%, the 27B 90% and Nemotron Super 3 120B 89% — each accepting its
gold storyline on 90–98% of `must` items. So the model half of storyline
filing is not where the stage fails; the sweep and the shortlist that decide
WHICH storyline the model is asked about are, and that is code. The three
differ in what they say no to. The 4B is the loosest: it accepts 19% of the
forbidden neighbours gold names and 5% of storylines drawn at random, and
fifteen times it said yes with the same confidence to two storylines at once —
so a shortlist that offers it a neighbour gets a wrong filing. The 27B is the
strictest — 7% of neighbours, none of the random draws, 33 of 35 gold-`none`
items filed nowhere, three ties — at nine confirmations a minute, five times
slower than the 4B. Nemotron sits between: the 27B's precision on the random
draws and the gold-`none` items, the 4B's looseness on the named neighbours
(17%), 250 confirmations a minute for 75 cents a thousand messages; one of its
453 answers was not valid JSON and that item is left unfiled, and its numbers
moved two to three points between two passes at temperature 0 where both local
rows reproduced exactly. `should` items are where all three decline (47–67%
accepted), which the scorer forgives. Two caveats ride on every row: thirteen
gold candidates were judged with an empty People line because the set holds no
other thread of theirs, which is a lower bound on recall, and 22 of the 30
charters are cut at the task's 400-character clamp, so a longer charter budget
is a follow-up worth measuring before a model swap.

**The charter cap, measured (2026-09-16).** The follow-up above was run: the
same cards through the 4B at clamps of 400, 800 and 1200, two passes each,
every pair token-identical. It went the other way. `storyline.id` falls as the
model reads more of the charter — 81%, 78%, 77% — and the reason is visible in
the column beside it: forbidden-accept climbs 20%, 25%, 26%, and the gold-none
items the model leaves unfiled fall 26, 24, 23 of 35. Gold-accept barely moves
(47, 46, 46 of 48 on `must`). More charter is more surface for a candidate to
match against, and the 4B matches on it. **Decision 7's rule therefore gives
cap 400**, which is the value the app already shipped: 400 has the best
`storyline.id` outright, and 800 is three points below it on the id and four
worse on forbidden-accept. The clamp stays a parameter with a
`GOLDEN_CHARTER_CAP` knob so a different model can be asked the same question.

The 400 row doubles as the new harness's control, and it passes: 79 of 98
against the 2026-09-15 row's 80, forbidden-accept 18 of 88 against 17, ties 16
against 15 — within one item on every count, at K=4 where that row ran K=1.
Accuracy is comparable across K and p50 is not, which is why the 2,685 ms here
sits beside that row's 1,146 without being read against it. **The 27B
confirmation run was skipped, deliberately.** The chosen cap is the existing
default, the 27B's own 400 row is already on the ledger at 90% with
forbidden-accept 6 of 88, a temperature-0 rerun on the same cards reproduces
token for token, and the 4B control shows the new harness reproduces — so the
forty-nine minutes would have bought no information. One thing the ladder
settles for item 6: the missing half of a charter is not what the 4B's 19%
forbidden-accept is made of, because giving it the missing half made that
number worse.

#### Storyline sweep

The app's OWN filing path against the gold registry, per "The sweep,
replayed." above. `storyline.id` is the scorer's number over the items it
counts, derived by MEMBERSHIP plurality rather than by the stored title, so it
is read against `make golden-baseline`'s 42 of 99 as the same stage seen a
second way. Every row keeps everything it is offered, sweeps the 95
conversations behind the set, 71 of them with a kept inbound message, and
seeds the GOLD gate verdict.

| date | confirm label | name label | card | run file | storyline.id | correct positives | purity | coverage | largest share | formed / tombstoned / lint | calls name / confirm | wall | note |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-09-18 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | participants | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-llamacpp-qwen3-8-27b-gguf-q4-k-m-sweep-20260918-161310.json` | 23/98 (23%), keep-only 21/85 (25%) | 0 | 44% over 6 of 7 storylines | 0% over 13 efforts | 56% | 7 / 0 / 3 would be refused | 7 / 142 | 240 s | the card the app ships; prose slot served with the MTP head; cards from `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-000817.json`; 95 conversations seeded, 71 with a kept inbound message, 24 fully gated, 71 embedded, 0 embed failures; 5 sweep passes, every suggestion kept; assign rejected 1; items unmapped 75, filed nowhere 25; lint counted and not applied; the third pass, on the review-fixed tree; the two earlier passes (`…153447` 259 s, `…153923` 231 s) were identical on every count, and the purity mean then averaged in the one storyline with no gold-carrying member as a zero, reading 37% |
| 2026-09-18 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | topics | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-llamacpp-qwen3-8-27b-gguf-q4-k-m-sweep-20260918-162005.json` | 31/98 (32%), keep-only 26/85 (31%) | 0 | 71% over 7 of 7 storylines | 0% over 13 efforts | 47% | 7 / 1 / 4 would be refused | 8 / 291 | 411 s | the same mailbox with the people out of the vector; same servers, same cards, same seeding counts; 8 sweep passes, every suggestion kept; assign rejected 24, assigned 2; items unmapped 52, filed nowhere 48; the third pass, on the review-fixed tree; the two earlier passes (`…154658` 446 s, `…155344` 401 s) were identical on every count |
| 2026-09-18 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | topics | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-llamacpp-qwen3-8-27b-gguf-q4-k-m-sweep-20260918-171650.json` | 37/98 (38%), keep-only 30/85 (35%) | 11 | 51% over 13 of 14 storylines | 8% over 13 efforts | 14% | 14 / 1 / 6 would be refused | 15 / 106 | 312 s | the Phase 2 rule, two links and half the members, the cap of twelve and the coherence floor of 0.60, with the topics card shipped; second of two identical passes, the first `…-sweep-20260918-171100.json` at 330 s; same servers, same cards from `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-000817.json`, same seeding counts: 95 conversations, 71 with a kept inbound message, 24 fully gated, 71 embedded, 0 embed failures; 6 sweep passes, every suggestion kept; calls per pass 24, 22, 28, 19, 16, 0; assign assigned 6, rejected 6; items unmapped 52, filed nowhere 30; forbidden hits 4 in 1 anti-storyline bucket; incoherent 0; lint counted and not applied, all 6 hits placeholder |
| 2026-09-18 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | topics | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-llamacpp-qwen3-8-27b-gguf-q4-k-m-sweep-20260918-192251.json` | 47/98 (48%), keep-only 38/85 (45%) | 7 | 43% over 2 of 2 storylines | 4% over 13 efforts | 71% | 2 / 12 / 3 refused | 14 / 71 | 182 s | the Phase 3 rules on top of Phase 2: the lexical series pre-pass, the namer that can decline a cluster and name outliers, twelve whole numbered central cards, and the charter lint wired into the naming branch. Second of two identical passes, the first `...-sweep-20260918-191812.json` at 203 s. Same servers, same cards from `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-000817.json`, same seeding counts: 95 conversations, 71 with a kept inbound message, 24 fully gated, 71 embedded, 0 embed failures. 4 sweep passes, every suggestion kept; calls per pass 11, 8, 1, 0. Series seeded 0, excluded 0. Outliers dropped 3. Incoherent 9, lint 3, both now applied rather than counted. Assign assigned 28, rejected 37; items unmapped 27, filed nowhere 63; forbidden hits 1 in 1 anti-storyline bucket. In-cluster cosine bins 0 / 4 / 37 / 86 / 194 over 321 pairs. The namer declined 9 of 14 clusters; the lint refused 3; the 2 that shipped then took 28 assign adds, which is the 71% |
| 2026-09-18 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | topics | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-llamacpp-qwen3-8-27b-gguf-q4-k-m-sweep-20260918-225817.json` | 48/98 (49%) | 6 | 60% over 2 of 2 storylines | 4% over 13 efforts | 80% | 2 / 12 / 3 refused | 14 / 76 | 203 s | Phase 4: the confirm prompt's three rules, `_accepts` with `high` for a suggested storyline, overlap needs two shared non-owner people, near-tie confirms both, catch-all detector; second of two passes, the first identical on every count; same servers, same cards from `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-000817.json`; seed 95 conversations / 71 kept / 24 gated / 71 embedded; 4 sweep passes, every suggestion kept, wall per pass 124665, 63993, 14826, 47 ms; incoherent 9, outliers dropped 3, series 0 seeded / 0 excluded; assign assigned 24 / rejected 41; unmapped 27, filed nowhere 67, forbidden hits 0 over 0; cosine bins 0 / 1 / 34 / 87 / 169 |
| 2026-09-19 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | topics | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-llamacpp-qwen3-8-27b-gguf-q4-k-m-sweep-20260919-005938.json` | 46/98 (47%) | 0 | 47% over 1 of 1 storylines | 0% over 13 efforts | 100% | 1 / 10 / 1 refused | 11 / 71 | 213 s | Phase 5: the settle gate, the 14-day expiry and the fragment fold keyed on the raw subject; the gate and the expiry cannot fire on the bench store; the fold folds one row per pass and one storyline forms that maps to no gold effort and takes 16 assign adds; second of two passes, the first identical on every count except the lint / incoherent split of the ten tombstones, 2 / 8 against 1 / 9, the namer at temperature; same servers, same cards from `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-000817.json`; seed 95 / 71 / 24 / 71 / 0; 3 sweep passes, wall per pass 79004, 61751, 48 ms; incoherent 9, outliers dropped 3, series 0 seeded / 0 excluded, fragments joined 0, rows folded 1 per pass; assign assigned 16 / rejected 52; cosine bins 0 / 2 / 18 / 48 / 103 |
| 2026-09-19 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | llamacpp/Qwen3.8-27B-GGUF:Q4_K_M | topics | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-llamacpp-qwen3-8-27b-gguf-q4-k-m-sweep-20260919-023532.json` | 46/98 (47%) | 0 | 47% over 1 of 1 storylines | 0% over 13 efforts | 100% | 1 / 10 / 1 refused | 11 / 71 | 214 s | Round D Phase 6, the final tree with the pre-naming observer: identical to the Phase 5 keeper on every count the sweep files; first pass identical except the lint/incoherent split 2/8 against 1/9 and 238 s; clusters judged 11, the one formed at 50% gold purity, the ten declined at a mean of 39% and none at 70%; pool pairs at or above 0.65: same effort 63 of 85, different efforts 653 of 1,346, with a gold-none thread 531 of 1,054; assign assigned 16 / rejected 52; unmapped 19 / filed nowhere 81; a third pass `…sweep-20260919-031635.json` at 234 s, after the review moved the member confirms' people list onto the kept threads, identical on every count |

**What the two sweep rows say (2026-09-18).** Both cards were run three
times, twice before the phase's review and once after its fixes, and every
pass of each was identical on every count, so the bench is deterministic at
temperature 0 and the last pass of each is the row.

| read | participants | topics |
|---|---|---|
| `storyline.id`, all items | 23/98 (23%) | 31/98 (32%) |
| `storyline.id`, keep-only | 21/85 (25%) | 26/85 (31%) |
| correct positives | 0 | 0 |
| purity mean, over the storylines with a gold-carrying member | 44% over 6 of 7 | 71% over 7 of 7 |
| purity per storyline, sorted | 0.12, 0.24, 0.25, 0.50, 0.50, 1.00 and one with no gold-carrying member | 0.25, 0.33, 0.38, 1.00, 1.00, 1.00, 1.00 |
| coverage mean over 13 efforts | 0% | 0% |
| largest storyline's share of filed threads | 56% | 47% |
| storylines formed / tombstoned | 7 / 0 | 7 / 1 |
| naming / confirm calls | 7 / 142 | 8 / 291 |
| calls per sweep pass | 72, 59, 13, 4, 0 | 71, 46, 36, 34, 32, 29, 25, 0 |
| sweep passes | 5 | 8 |
| wall, kept pass | 240 s | 411 s |
| items unmapped / filed nowhere | 75 / 25 | 52 / 48 |
| charter lint, counted: clean / placeholder / person / category | 4 / 3 / 0 / 0 | 3 / 4 / 0 / 0 |

**The card decision is met, so `topics` ships.** The rule written into
`StorylineTuning.participantsInClusteringCard` before the runs asks for four
points on `storyline.id` on both passes. `topics` beats `participants` by
eight, with a smaller largest share and no fewer correct positives. Phase 1
changed no code for it; Phase 2 flipped the const to false, bumped
`EmbeddingsClient.modelTag` to `embeddinggemma-300M/clustering-v2`, added the
`clustering_card_v2` one-shot re-embed on the sync, and moved `SWEEP_CARD`'s
default to `topics` so the bench keeps following the app. The cost is proposals rather than
accuracy: smaller clusters mean more of them, which is 291 confirms over eight
passes against 142 over five.

**The coherence floor for Phase 2 is 0.60**, read off the cosine of every pair
INSIDE a formed storyline. Below 0.55 there are 17 pairs out of 861 even
inside the chained blobs, so a 0.55 floor would never bite. The 0.55 to 0.60
band is where a blob's mean pairwise similarity drifts and a tight cluster's
does not.

| pairs inside a formed storyline | <0.50 | 0.50-0.55 | 0.55-0.60 | 0.60-0.65 | >=0.65 | total | under the 0.65 link threshold |
|---|---|---|---|---|---|---|---|
| participants | 1 | 16 | 96 | 281 | 467 | 861 | 46% |
| topics | 0 | 1 | 18 | 93 | 188 | 300 | 37% |

**Neither card produces a correct positive, and that is the honest reading.**
No formed storyline holds two threads of one gold effort at a plurality, so
coverage is zero on all thirteen efforts that have at least two golden threads,
and the largest storyline is still 47% to 56% of everything filed. That is the
chaining Phase 2 removes. The card change alone moves purity from 44% to 71%
and the scorer from 23 to 31 of 98, which is real and is not enough on its own.
The lint counted beside the run says where the rest of it goes: the namer wrote
a placeholder title or charter for three of the seven storylines it was handed
under the participants card and four of seven under topics, which is what
decision 5's `coherent` field and the lint wired into the naming pass in Phase
3 exist to catch. The lint counts ride in `extra.sweep.lint` of the result
JSON, counted in Phase 1 and applied to nothing.

**This bench's 23 of 98 is the round's "before" of record**, not
`make golden-baseline`'s 42 of 99. The two are the same stage read two ways and
neither supersedes the other, but only this one runs the app's own sweep, and
only this one can be re-run after a code change. The gap between them is the
keep-all owner: seven blobs were accepted and they swallowed 75 items into
storylines that answer to no gold effort, where the baseline reads a stored
title per thread instead.

**What the Phase 2 row says (2026-09-18).** The same mailbox, the same
servers and the same cards, swept by the clustering rule Phase 2 shipped: two
links and half the members to join, a cap of twelve, and a split at 0.05
higher for any cluster at the cap or under the 0.60 coherence floor. Run
twice, identical on every count, second pass kept.

| read | participants | topics | Phase 2 rule |
|---|---|---|---|
| `storyline.id`, all items | 23/98 (23%) | 31/98 (32%) | 37/98 (38%) |
| correct positives | 0 | 0 | 11 |
| purity mean, over the storylines with a gold-carrying member | 44% over 6 of 7 | 71% over 7 of 7 | 51% over 13 of 14 |
| largest storyline's share of filed threads | 56% | 47% | 14% |
| naming / confirm calls | 7 / 142 | 8 / 291 | 15 / 106 |
| wall, kept pass | 240 s | 411 s | 312 s |

**The chaining is gone and the bench has its first correct positives.**
Eleven items are now filed under the gold effort they belong to, where both
Phase 1 cards produced none at all. The largest storyline holds 14% of every
filed thread against 47% under the same card a rule ago, which is the number
this phase existed to move. The model spends less to get there: 106 confirms
against 291, because fourteen small groups cost fewer member questions than
seven blobs, and the wall falls from 411 s to 312 s.

**Purity fell, from 71% to 51%, and that is not a regression hiding in the
average.** It is fourteen storylines instead of seven, and the plurality
mapping is harsher on a group of three than on a blob: one wrong member in a
trio costs 33 points where one wrong member in a group of twenty costs 5. Six
of the fourteen carry a title or charter the lint already reads as a
placeholder, counted and not applied until Phase 3, so the namer is still
being handed groups it cannot describe and is still describing them anyway.

**Coverage is 8% and is the next thing to fix, not this phase's.** An effort
whose threads now sit in three small storylines scores against none of them,
so cutting the blobs up moved coverage from 0% to 8% and no further. The two
answers to that are already planned: the series pre-pass in Phase 3, which
groups a recurring subject before the cosine sees it, and the fragment
handling in Phase 5. The cosine inside a formed storyline is tighter
throughout, which is the floor doing its work.

| pairs inside a formed storyline | <0.50 | 0.50-0.55 | 0.55-0.60 | 0.60-0.65 | >=0.65 | total | under the 0.65 link threshold |
|---|---|---|---|---|---|---|---|
| Phase 2 rule, topics | 0 | 0 | 1 | 26 | 132 | 159 | 17% |

**What the Phase 3 row says (2026-09-18).** The same mailbox, the same servers
and the same cards, swept with the series pre-pass in front of the clustering,
a namer that may decline a cluster or name the threads in it that do not
belong, twelve whole numbered central cards, and the charter lint applied
rather than counted. Run twice, identical on every count, second pass kept.

| read | Phase 2 rule | Phase 3 rules |
|---|---|---|
| `storyline.id`, all items | 37/98 (38%) | 47/98 (48%) |
| correct positives | 11 | 7 |
| largest storyline's share of filed threads | 14% | 71% |
| storylines formed | 14 | 2 |
| placeholder charters that shipped | 6 | 0 |
| naming calls | 15 | 14 |
| confirm calls | 106 | 71 |
| sweep wall, kept pass | 312 s | 182 s |
| items unmapped | 52 | 27 |
| assign pass, threads assigned | 6 | 28 |

**A reference number nobody working on this scorer should forget: a sweep that
files NOTHING scores 50 of 98.** Every correct abstention is credited, so an
app that formed no storyline at all would beat both rules on this column. The
bench measured exactly that by accident, which is the next paragraph. Phase 3's
47 sits three items UNDER that floor while carrying 7 correct positives, where
an empty run carries none. The round's target, at least 70 with positives,
needs both halves and neither number is evidence on its own.

**How this row was reached, in the order it happened.** The rule as first
shipped tombstoned every cluster the 27B called `coherent: false`, and the
first pass on the golden pool formed 0 storylines: 8 clusters named, 8
declined, 50 of 98 on the scorer and 0 correct positives. A counts-only probe
of the live 27B over fictional trios showed the prompt behaving exactly as
written. On a coherent trio it answered true with no outliers. Whenever any
thread did not belong it answered false, listed the outlier numbers, and wrote
a title and charter for the largest group, which is what the prompt's own
sentence asks of it. On the golden pool 14 of 14 clusters came back false at
some point across the passes, and in the diagnostic pass 4 of 8 listed every
thread as an outlier. So the code now reads false as "not all of them": a false
carrying no outliers, or a kept set of fewer than two threads, is a tombstone,
and otherwise the kept threads go to the confirms. That change and the reruns
are the row above. The prompt text did not move.

**The series pre-pass is unmeasured by this bench.** It seeded 0 series and
excluded 0, because no three golden conversations share a folded subject: the
set was sampled for diversity, which is the one shape a recurring-series rule
cannot be read against. It will be read on the live rail instead, where a
weekly digest and a vendor feed are ordinary. The zero is not evidence the rule
does nothing.

**The namer is strict and the lint bites.** It declined 9 of the 14 clusters it
was handed, and the sets it kept are small at 3, 3 and 2 threads. The lint then
refused 3 placeholder charters that Phase 2 would have shipped, so the 6
placeholder charters of the Phase 2 row become 0 here. Three threads were
dropped as outliers across the run. Between them those three gates are why only
2 storylines formed against 14.

**The 71% largest share is the assign pass, not the sweep.** The two storylines
that did form then received 28 automatic assign adds against 37 rejections,
which is more assign filing than every earlier row combined, and it is where
both the 71% and the 27 unmapped items come from. A sweep that proposes two
tight groups and an assign pass that pours the mailbox into them is the same
blob arriving by a different door. Phase 4 is aimed at exactly that: the
catch-all detector, the near-tie confirm and the confirm-prompt rule that
mirrors the charter rule.

**The whole-card change cost nothing measurable in prompt size.** The cards the
namer saw ran from 837 to 2,493 characters for 3 to 7 cards, far under the
7,300-character set cap, so no card was dropped from the far end and no clamp
bit.

**This is the cheapest row the sweep has produced.** 71 confirms and 182 s
against 106 and 312 s a phase ago, and against 291 and 411 s two phases ago.
The balance has flipped with it: the 14 naming calls on the 27B are now the
larger share of the wall, where the 4B confirms used to be.

**What the Phase 4 rows say (2026-09-18).** The confirm task gained three
sentences, naming the specific occasion a storyline is about and telling the
model to answer no when a thread only shares the people or the general subject.
On the 4B, against the 2026-09-15 row and the same cards:

| row | storyline.id | gold-accept must | forbidden-accept | gold-none filed nowhere | ties |
|---|---|---|---|---|---|
| 2026-09-15, the prompt before | 80/98 | 47/48 | 17/88 | 26/35 | 15 |
| Phase 4, the three rules | 84/98 | 45/48 | 15/88 | 30/35 | 15 |

Decision 6's rule was written before the runs: ship if forbidden-accept falls
and gold-accept `must` stays within four points. Both held, so the three
sentences ship. The target of ten percent forbidden-accept was not reached on
the 4B.

**The same prompt is neutral on the box 27B.** It was already refusing what the
new sentences name, so there is nothing for them to take away.

storyline.id 85 to 83 of 98, gold-accept `must` 41 to 40 of 48,
forbidden-accept 8 of 88 on both rows.

No local 27B-as-bulk row was taken this phase. The box serves the same model at
the same accuracy and faster, so the local pair would have bought no reading.

**The sweep forms the same two storylines as Phase 3**, and the phase's four
assign rules move the filing around them rather than the count of them.

storyline.id 47 to 48 of 98, purity 43% to 60%, correct positives 7 to 6,
largest share 71% to 80%, forbidden hits 1 to 0, confirms 71 to 76, assign 28
filed and 37 rejected to 24 and 41.

The five extra confirms are the near-tie asking both candidates. The catch-all
threshold is `max(0.30, 2 / k)` over the storylines that took an automatic add
in the window, so with two storylines it cannot fire by construction and this
row does not measure it. It is pinned by unit tests and will be read on the
live rail.

**Where the accuracy is stuck is visible in the rows.** The sweep forms two
storylines out of thirteen gold efforts because the namer declines nine of the
fourteen clusters it is handed and the lint refuses three more, so the assign
pass has only two groups to file into. The next number to take, in Phase 6, is
each cluster's gold-slug plurality share BEFORE naming, computed offline from
the bench's membership map, counts only, so a declined pure cluster is visible.
That number decides whether the naming rule or the clustering moves next.

**What the Phase 5 rows say (2026-09-19).** The phase shipped three lifecycle
rules and this bench can see one of them. The settle gate and the 14-day
expiry cannot fire on the bench store, which has no queue behind it and whose
suggestions are minutes old; the run now fails outright if a sweep row ever
carries `deferred`. The fragment fold does run. As shipped it keys fragment
identity on the raw subject, with `Re` and `Fw` stripped and case and
whitespace folded while digits are kept. On this pool it folds one row per
pass onto its representative, and an offline count over the golden set finds
that the pair carries the same gold storyline id, so the fold is right where
it fires.

**The fold is the whole difference between this row and Phase 4's**, and the
diagnostics below say so from two directions.

| variant | storyline.id | correct positives | formed | names | confirms | wall |
|---|---|---|---|---|---|---|
| Phase 4 (fold absent) | 48/98 | 6 | 2 | 14 | 76 | 203 s |
| Phase 5 as shipped | 46/98 | 0 | 1 | 11 | 71 | 213 s |
| Phase 5, first cut, series-key identity (not shipped) | 50/98 | 0 | 0 | 6 | 0 | 71 s |
| Phase 5, fragment window 0 (diagnostic, not shipped) | 48/98 | 6 | 2 | 14 | 76 | 294 s |

The fold-off diagnostic was taken against the first cut, and with the fold
switched off it matched Phase 4 on every count. Under the shipped identity one
row folds per pass and one storyline forms. It is impure and it holds every one
of the 16 threads the assign pass then filed, which is the 100% largest share.
So the six positives Phase 4 carried are gone under either identity. 50 of 98
is the score a sweep that files nothing earns from the abstentions alone, and
the round's exit needs positives on top of it.

**Three diagnostics tried to bring the clusters back and none of them
shipped.** All three were taken on the first cut, before the fragment identity
moved to the raw subject.

| variant | storyline.id | correct positives | formed | names | confirms | forbidden hits | wall |
|---|---|---|---|---|---|---|---|
| propose floor 2 | 51/98 | 9 | 6 | 35 | 106 | 3 | 597 s |
| propose floor counting folded rows | 50/98 | 0 | 0 | 6 | 0 | 0 | 99 s |
| link threshold 0.60 | 41/98 | 2 | 3 | 14 | 108 | 0 | 345 s |

The floor is not the mechanism, because counting a representative's folded
rows toward it changes nothing. A lower link threshold forms three storylines
and loses seven scorer points. A floor of two buys nine positives at three
times Phase 4's wall, thirty-five naming calls and three forbidden hits, which
is the trade the round set out not to make. All three constants stand where
Phase 2 and Phase 3 left them.

**The clustering is what is brittle, not the fold.** A folded row is a
near-duplicate vector of its representative, and the Phase 2 join rule asks a
candidate for two links into a cluster. On this pool the duplicate was the
second link, so the clusters Phase 3 and Phase 4 formed, and the six positives
they carried, rested on rows the sweep was counting twice. The number to take
next is still the one the Phase 4 block named: each cluster's gold purity
before naming, so that the six clusters the namer still declines can be told
from the eight that no longer form.

**What the phase did prove is read off the unit tests, not off this bench.**
The sweep defers above 10 extractions, 25 embeddings or 20 unjudged messages,
and the fast lane re-arms it only after a drain that processed something. An
automatic suggestion left unanswered for 14 days is dismissed, and the room it
held is reused in the same pass. Fragments join on their representative's
verdict with one confirm instead of three. The live rail after the round is
where those three are read.

**What the Phase 6 rows say (2026-09-19).** The final tree's sweep row is the
Phase 5 keeper again on every count the sweep files, and the phase's two new
tally lines say why. The first watches every cluster before the namer sees it,
through a constructor seam the app never passes: eleven clusters were judged,
one was named and formed, nine were declined as not one storyline and one was
refused by the charter lint. The one formed cluster is 50% gold-pure. The ten
declined clusters average 39% gold purity, none of them reaches 70% and none
is a single effort. That is the number the Phase 4 and Phase 5 blocks asked
for, and it answers against the clustering rather than against the naming
rule: what the namer declines is mixed.

**The second line prices the vector itself.** It is the cosine of every pair
of the 71 embedded pool threads, 2,485 pairs, split by whether the two threads
share a gold effort.

| pairs | count | <0.50 | 0.50–0.55 | 0.55–0.60 | 0.60–0.65 | ≥0.65 | share ≥0.65 |
|---|---|---|---|---|---|---|---|
| same gold effort | 85 | 0 | 1 | 3 | 18 | 63 | 74% |
| different gold efforts | 1,346 | 2 | 23 | 187 | 481 | 653 | 49% |
| at least one thread gold files nowhere | 1,054 | 1 | 25 | 138 | 359 | 531 | 50% |

At the shipped link threshold of 0.65 a link is a same-effort pair 63 times in
1,247, about 5%. A rule that reads links off this vector is choosing among
pairs that are mostly wrong before it starts.

**The reading, which is the round's finding.** The namer is right to decline,
because the clusters it declines are mixed. The clustering is building mixed
clusters because the vector cannot separate this mailbox's efforts, and no
join rule or threshold on that vector can fix it. The lever is the vector
itself: another embedding model, another card recipe, a lexical or participant
signal beside the cosine. A model-read grouping in place of the cosine
clustering is the other lever. This is where Round D stops, and Round E's plan
reads these bins before it writes anything.

**The confirm rows and the D8 decision.** Four candidates, `make
golden-storyline` on the Phase 4 prompt, cards for the 4B rows from
`golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-174707.json`,
each row the second of two identical passes unless noted.

| date | confirm model | storyline.id | must / should | forbidden-accept | derived none on gold-none | p50 ms | msgs/min | run file |
|---|---|---|---|---|---|---|---|---|
| 2026-09-18 | local 4B Q8_0 (llama.cpp) | 84/98 (86%) | 45/48 / 10/15 | 15/88 (17%) | 30/35 | 1116 | 11.8 | `…4b…-storyline-20260918-212404.json` |
| 2026-09-18 | box 27B-FP8 as bulk (vLLM, L40S) | 83/98 (85%) | 40/48 / 7/15 | 8/88 (9%) | 33/35 | 1773 | 7.4 | `…27b-fp8-as-bulk-storyline-20260918-224336.json` |
| 2026-09-19 | box 4B-FP8 (vLLM, L40S) | 80/98 (82%) | 46/48 / 9/15 | 19/88 (22%) | 27/35 | 517 | 25.7 | `golden-run-vllm-g6e-qwen3-4b-instruct-2507-fp8-storyline-20260919-020723.json` |
| 2026-09-15 | local 27B Q4_K_M as bulk, BEFORE the prompt | 88/98 (90%) | 43/48 / 8/15 | 6/88 (7%) | | 6373 | | already in the table |

The 4B row was reproduced on the final tree in one pass on 2026-09-19,
`…-storyline-20260919-024443.json`, identical to the 2026-09-18 row on every
count. The local 27B-as-bulk was not re-measured after the prompt: the pair was
stopped in Phase 4 on the user's instruction to use the box instead. From
those rows, D8. Local tier: the confirm stays on the 4B. It is the most
accurate of the four on the scorer at 84 of 98, 5.7 times faster per confirm
than the local 27B, and off the prose slot that names and drafts; its 17%
neighbour rate is what decision 6's `high`-for-`suggested` rule tightens in
code. GPU tier: the 27B over the box's 4B. The 27B accepts 9% of the named
neighbours where the box's 4B accepts 22%, the loosest of the four, and that
speed buys nothing a confirm needs. No candidate meets the roadmap's target of
at or above 88% with neighbours at or below 10% after the prompt. The target
stands unmet and the rows say so. For E1, where targets become settings, the
confirm stage defaults to `Local fast`, and to the GPU 27B target whenever one
is configured.



### Gate replay ledger

What `make golden-gate` measures is the app's gate FUNCTIONS against the set,
offline and with no server: each item's direction through
`triageStatusOnInsert` and its sender and body through `gateFor`. That is a
narrower question than the baseline row above asks, and the two numbers are
recorded side by side rather than compared. The baseline is what the shipping
app did on 2026-09-12 with mail headers and the Teams ingest's own gates in
front of it; the replay is what the set alone can ask, and the header gates
(`newsletter`, `auto_generated`) and the Teams bot and self gates go
unmeasured in it by construction. A data rule — the per-sender `drop` — cannot
show in a replay either: the set carries no `sender_prefs`, so every gate the
owner would have written by hand reads here as a miss.

| date | gates at | run file | gate.verdict /100 | gate.reason on caught drops | drops caught /24 | keeps kept /76 | trap misses /12 | model proxy notification: drops / keeps / trap | note |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-12 | the shipping app, Tier 1 + Tier 2 + Teams ingest, as stored | none — `--baseline` | 76 | 6 / 11 | — | — | — | — | headers were in front of the app; not comparable to the replay rows |
| 2026-09-16 | `main @ 982f21f` (prefix regex + direction) | `golden-run-app-gates-20260916-162650.json` | 80 | 4 / 7 | 7 | 73 | 3 | `0 / 24 · 1 / 76 · 0 / 12` | the 17 missed drops by gold reason: `newsletter` 3 and `auto_generated` 2 (header-only, Tier 2 — the set carries no headers, and the app catches 4 of these 5 live); `monitoring` 2 and `machine_sender` 1 (the shapes round A adds); `ticket_system` 2, `identity_service` 2, `share_notification` 2, `cold_outreach` 1 and `no_reply` 1 (tenant-specific senders and one loose shape — data, not a name rule); `empty` 1 (a Teams post whose stored block is not blank in the set). The 3 trap misses are all `no_reply`-prefix humans |
| 2026-09-16 | `feat/pipeline-round-a` (`noreply` anywhere — compact substring, punctuated token — `monitoring`, `machine_sender`, `sender_rule`) | `golden-run-app-gates-20260916-164818.json` | 83 | 5 / 10 | 10 | 73 | 3 | `0 / 24 · 1 / 76 · 0 / 12` | second of two identical passes. The three new catches: both `monitoring` shapes (one gold `monitoring`; one gold `machine_sender` sent from a monitoring mailbox, which the reason column scores as a miss) and one compact `noreply` buried in a twenty-letter local part (gold `monitoring`, so also a reason miss — the delimited-token rule alone scored 82 and this one item is why the compact word is a bare substring). Trap misses unchanged at 3. The sender rule is data and cannot show in a replay that has no `sender_prefs`. The 14 remaining misses: Tier 2 (5 — `newsletter` 3, `auto_generated` 2), tenant data (8 — `ticket_system` 2, `identity_service` 2, `share_notification` 2, `cold_outreach` 1, `no_reply` 1 on a person-shaped address) and one Teams post (`empty`). Per stratum only `gate-drop-missed` moved, 0/9 → 3/9 |

Per stratum on the 2026-09-16 `main` row, `gate.verdict`: gate-drop-clear 4/8,
gate-drop-missed 0/9, gate-edge 3/7, gate-keep-trap 9/12, needsyou-hard 8/8,
storyline-core 23/23, storyline-trap 12/12, thread-recap 6/6, triage-spread
15/15. Three of the four `no_reply` catches on that row carry a gold slug that
is not `no_reply` — `identity_service`, `machine_sender` and
`teams_missed_activity_digest` — which is why the verdict column counts them
and the reason column does not.

### Recommendations (golden set, 2026-09)

Everything below rests on the rows above: nineteen ledger rows and three
confirm rows, keep-only, the second of two passes except where a row's note
says one, one judge for every rubric number. The `## Recommendations` section
further down is the fictional-corpus bakeoff's, about runtimes and quants;
this one is about models per stage on real traffic, and where the two overlap
they agree — keep the 4B, keep the 27B. Three reading rules travel with the
numbers. Candidates are read against the REPLAYED 4B, not the stored baseline
(the stored run is one sample of the same model on a different day's thread).
Rubric numbers are read against other rubric numbers under the same judge,
never as absolutes — the same stored summaries score 54% under one reader and
37% under the other. And a difference under four points is not a finding:
triage at its shipping temperature moves one to three points between identical
passes, and the one Bedrock row that was run twice at temperature zero moved
two to three.

**Per stage, the best of each kind.** Keep-only accuracy, the rubric fields
that stage owns, the stage's p50, and the run's throughput and price.
Throughput is the whole three-stage run for a bulk row (K=1 local, K=4 cloud),
so it is comparable down a column and not across slots.

| stage | the shipping 4B, replayed | best local | best cloud |
| --- | --- | --- | --- |
| triage | category 89 · urgency 89 · needs_action 66 · reply_expected 70; label 84 · action items 67 · summary 39; p50 2.4 s; 8.9 msgs/min; $0 | the 4B itself. The 27B as bulk is the ceiling (92 / 95 / 72 / 84; label 89, summary 41) at 13.4 s and 1.5 msgs/min; Qwen3.5-4B gains reply_expected (83) and loses the text (summary 16, action items 53) | Nemotron Super 3 120B: 91 / 95 / 74 / 75; label 87 · action items 67 · summary 47; p50 1.3 s; 70.7 msgs/min; $0.69 / 1K |
| needs-you | verdict 92; evidence 27; p50 1.6 s | the 4B. The 27B's 93 is one point; its evidence (39) is the only gain | Nemotron Super 93 (evidence 19); Haiku 4.5 92 with the best evidence of any row (48) at $8.27 / 1K |
| extraction | intent 75 · importance 39 · project 66 · topics 26 · people 87; evidence 25; p50 2.0 s | the 27B as bulk: 86 / 74 / 58 / 32 / 93, evidence 41, at 13.9 s. Qwen3.5-4B: 79 / 66 / 63 / 29 / 88, evidence 33, at 2.7 s | Nemotron Super: 83 / 79 / 70 / 37 / 93, evidence 41, p50 1.2 s, $0.69 / 1K. GLM 4.7 Flash has the best project (87) and importance (82) with weak evidence (28) |
| reply decision | the 4B on the dedicated task: 64% at 1.2 s (2026-09-16); its triage boolean for the same question: 70 (tail3), 78 (none, second pass) | the 27B on the dedicated task: 82% at 6.6 s | none beats it: Opus 5 78, DeepSeek V3.2 78, Sonnet 5 68, Nemotron Super 66 |
| drafts (25 reply-rubric items) | — | the 27B: 5 of 25 (20%) at 16.6 s | Opus 5 12 of 25 (48%) at 5.4 s, $17.17 / 1K; Sonnet 5 10 (40%) at 4.4 s, $6.80; DeepSeek V3.2 10 (40%) at 3.0 s, $0.84; Nemotron Super 7 (28%) at 1.3 s, $0.24 |
| storyline confirm | the 4B: 82%; accepts 19% of named neighbours and 5% of random draws; 15 ties; 1.1 s a call, 51 calls/min | the 27B: 90%; 7% and 0%; 3 ties; 6.4 s a call, 9 calls/min | Nemotron Super: 89%; 17% and 1%; 5 ties; 0.9 s a call, 251.6 calls/min, $0.75 / 1K |

**1. Bulk slot: keep Qwen3-4B-Instruct Q8_0. There is no local swap worth
making.** The same verdict the fictional corpus gave, for a better reason: the
candidates that classify better write worse, and the label and summary are
what the user reads. Qwen3.5-4B passes 16% of summaries against the 4B's 39%
and Qwen3.5-9B 24%; and the drain bench of 2026-09-13 (not a golden number;
`make drain`, K=6, same llama.cpp build) has the Qwen3.5-4B at about 70% of
the 4B's throughput (36 against 51 messages a minute) and the 9B at a third.
The 27B in the bulk slot is a ceiling, not a slot: it beats the 4B on every
enum but project (58 against 66) and on label and both evidence fields, with
summary and action items inside the floor, at six times the time per message
and 1.5 messages a minute, and the bulk slot's defining workload is the drain.
What the 4B leaves on the table is now a number rather than a feeling —
importance 39 against a ceiling of 74, needs_action 66 against 72, and summary
39 against 41, which is inside the floor — and the cheapest way to close most
of it is in the prompts (item 7), not in the model.

**Measured 2026-09-16 (round B, phase 1):** the summary rule alone moved the
judged summary from 39 to 63 on the same judge — 66 / 63 / 63 / 63 across the
four judged runs of the phase — with the forbidden-fact traps at 4 items
against 3 and needs_action 66 to 71; action items fell 67 to 60, which is the
trade the prompt-round paragraph in the ledger above sets out. The row of
record is `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260916-194031.json`.

**2. Needs-you stays local on every tier.** The verdict is 92% on the 4B, 93
on the 27B and on the 120B, 92 on Haiku; nothing beats the shipping model
beyond the noise floor, and part of that recall is the deterministic floor,
which costs no model at all. The models differ on the evidence sentence (27 on
the 4B, 39 on the 27B, 48 on Haiku), which is a shown sentence and worth a
prompt experiment, not a model swap for a one-point verdict. **Measured 2026-09-16
(round B, phase 1):** the prompt experiment was run twice and is not shipped.
Asking the bullet to quote the words that point at the owner lifted the
sentence 27 to 36, but put 27 of 64 sentences at the 300-character clamp and
cost the verdict 92 to 89; a short-sentence wording scored 9 with the verdict
at 86. The original bullet stays, at 28 and 92 (`…184707`, `…192254`,
`…194031`).

**3. If a cloud bulk model is ever wanted, it is Nemotron Super 3 120B and no
other.** It is the first candidate that beats the 4B on needs_action (74
against 66) while matching it on needs_you (93 against 92, inside the floor),
it matches or exceeds the local 27B ceiling on every enum but reply_expected
(75 against 84), it writes the best summaries of any non-Claude row (47%), and
it does so at 70 messages a minute for $0.69 per thousand messages — four
cents for a sixty-message day. The others each lose on one axis that matters:
Haiku 4.5 is the best writer of any bulk row (label 95, summary 53) at twelve
times the price and with the weakest importance of the cloud rows (63);
DeepSeek V3.2 has the best category (96) and the best label of the non-Claude
rows (91) and is 2.7x slower and 3.5x dearer for no gain on the booleans;
Gemma 3 12B and GLM 4.7 Flash classify well and write badly (needs-you
evidence 5 and 22); Nemotron Nano 3 is worse than the 4B on every rubric
field. Using Nemotron Super for bulk work would break the speed design's rule
2 — cloud is never used for triage or extraction and never in a drain — and
that rule is about consent and what leaves the machine, so a bakeoff does not
amend it and this round does not. What the numbers do is price the rule:
staying local costs about forty points of importance, eight of needs_action
and eight of summary against the one cloud model worth having. If the rule is
ever reopened for the tiers that cannot hold the 27B (item 8), this is the
model the amendment would name, and this is what it would buy; that is a
product decision not taken here.

**4. Prose slot: the 27B keeps the reply decision; drafts are where cloud
pays.** The dedicated decision on the 27B scores 82% against gold and no cloud
model reaches it — Opus 5 and DeepSeek 78, Sonnet 68, which is below the 4B's
own triage boolean. Drafts are the opposite picture: the 27B passes 5 of 25,
Opus 5 passes 12, Sonnet 5 and DeepSeek V3.2 10 each, Nemotron Super 7. That
is the speed design's §4 conclusion measured: the opt-in "better draft" should
be **Claude Opus 5** (the best pass rate, about three cents a draft at the
design's 5K-in / 300-out shape, $17 per thousand messages in the ledger's
accounting), with **Sonnet 5** as the cheaper option at 40% of the price and
40% of drafts passing. DeepSeek V3.2 matching Sonnet at an eighth of the price
is a fact worth keeping; whether a second provider belongs on the consent
screen is a product call, not a bakeoff call. Since 2026-09-17 (Round C) the
prose slot's work runs on two lanes of its own — the six storyline passes in
one, `DraftHandler` alone in the other at the **Drafts in flight** width — and
a draft a person asked for skips this decision entirely, because they have
already made it. Two caveats sit on the whole
column. Every model's draft failures have the same shape — of the failing
drafts, 10 to 15 per model invent a fact only the owner knows — so the "ask,
don't invent" rule in the draft prompt precedes any swap and any escalation,
and the four prose rows are re-run after it. And the replay drafts from the
message and its tail alone, with no directory pack, style examples, about-me
or storyline summary, so every pass rate here is a floor on what the app would
produce.

**Measured 2026-09-16 (round B, phase 2):** the "ask, don't invent" rule was
written, measured, revised and measured again, and it does not change this
item's conclusion. Drafts passing of 25, baseline → shipped v3: the 27B 5 → 6,
Opus 5 12 → 17; on v2 only, Sonnet 5 10 → 17 and DeepSeek V3.2 10 → 9.
Invented over each row's failing drafts fell on every cloud model — Opus 10 of
13 → 6 of 8, Sonnet 12 of 15 → 6 of 8 — and rose on the local one, 10 of 20 →
14 of 19. So Opus 5 stays the default "better draft" and its measured number
for the consent screen is 17 of 25 rather than 12 (v4, 2026-09-17, re-read the same 17 of 25 and 6 of 8). Sonnet 5 also reached 17 of
25, at 40% of the price — a fact to record with its caveat, since that is
Sonnet on v2 against Opus on v3 and Sonnet has no v3 run; what the escalation
ships is not this phase's call. The rule did NOT precede the swap in the way this item
assumed it would: it is worth five drafts on the best cloud model and nothing
on the 27B, whose inventions are the same nine items under every wording. The
decision half is unchanged — the prompt did not move and the 27B reproduced
82% on every pass.

**5. The reply decision on the 4B is one run away.** The speed design wants
the decision off the 27B and onto the fast slot behind an A/B. The set now
holds half of that A/B: the dedicated decision on the 27B is 82%, and the 4B's
triage answer to the same question is 70% (75% without the tail, on one pass).
The half that is missing is `ReplyDecisionTask` itself on the 4B:

```sh
make golden-prose PROSE_URL=http://localhost:8082/v1/chat/completions \
                  PROSE_MODEL=<the bulk model name> PROSE_LABEL='llamacpp/Qwen3-4B (decision)'
```

Seventy-six decisions and twenty-five drafts, a few minutes; only the decision
number needs reading, and the drafts need not be judged. Within four points of
82 and the 27B leaves the per-message path, as the design hopes; near 70 and
the decision stays on the 27B at its measured 6.6 s, which the design's
per-message budget already absorbs.

**Answered 2026-09-16:** the run was made, twice, on the fast slot at 4096
tokens a slot, and both passes agree — the 4B's dedicated decision scores
64% keep-only, 49 of 76 — the same score on both passes, as temperature 0
predicts — at p50 1.2 s. That is six points under the 4B's own triage
boolean (70) and eighteen under the 27B's 82, nowhere near within four of
it. So the decision stays on the 27B, overlapped with the bulk stages rather
than ahead of them, and the speed design's §1.3 item 2 is settled that way:
the 27B's 6.6 s is the cost the per-message budget carries. The surprise is worth recording
honestly — asked the question on its own the 4B answers it worse than it
answers it inside triage, where the same boolean reads 70 with the tail and
78 without one. If the decision ever does leave the 27B, then, the candidate
is triage's own boolean on the `none` context, not a second call — and at
78 it sits exactly four points under 82, on the edge of this item's own
threshold and on one second pass, so it is the follow-up round's A/B and
not a decision taken here.

**6. Storyline filing: fix the code, then choose the model.** Handed a
candidate list a person wrote, every model files far better than the app has
ever filed — 82%, 90% and 89% against the app's 42 of 99 with no correct
positive, each accepting its gold storyline on 90–98% of `must` items. The
confirm task is therefore not where filing fails; the sweep that proposes
storylines and the shortlist that picks the candidate are, and both are code.
The rework of those two comes before any model decision, and the confirm
replay is its before-and-after. What the rows say about the model half, for
when that day comes: the confirm runs on the fast client today, and the 4B is
the loosest judge of the three — it accepts 19% of the neighbours gold names
as traps and tied with itself fifteen times — so a shortlist that offers it a
plausible neighbour gets a wrong filing. The 27B is the strictest (7% of
neighbours, none of the random draws, 33 of 35 gold-`none` items filed
nowhere) and a confirm is one call per assignment rather than per message, so
its 6.4 s is affordable off the critical path; the 120B is 27B-like on random
draws and gold-`none` and 4B-like on neighbours, at 250 confirmations a
minute. Before either, one measurement is free: 22 of the 30 real charters are
cut at the task's 400-character clamp, and `make golden-storyline` against a
longer clamp says what the missing half of a charter is worth.

**Measured 2026-09-16 (round B, phase 2):** the free measurement above is now
runnable. The clamp was a private constant inside `ConfirmMembershipTask`; it
is a constructor parameter, the app passes `StorylineTuning.charterCap` at
every call site, and the harness carries `GOLDEN_CHARTER_CAP` so one set of
cards replays at several clamps — `make golden-storyline GOLDEN_CHARTER_CAP=…`,
which records the clamp it ran at beside `charters_over_cap` in the timing
JSON. The three-clamp replay was then run on the 4B, and it answers this
item's free measurement in the negative: 400 / 800 / 1200 give `storyline.id`
81 / 78 / 77% with forbidden-accept 20 / 25 / 26% and gold-none left unfiled
26 / 24 / 23 of 35, so the cap stays at 400. The missing half of a charter is
not what the 4B's looseness on named neighbours is made of — handed the
missing half, it accepted more of them. The confirm rows above carry the
detail, including why the 27B confirmation run was skipped.

**7. The context ladder: the tail as given does not help the 4B, and
compression was not measurable.** On the shipping model the thread tail lowers
needs_action (75% alone, 66% with it) and reply_expected (75, 70), on the
items whose gold label needs the tail as much as on the rest; action items
rise without it (71 against 67) and summaries fall (34 against 39); the
needs-you verdict and extraction do not move, though the needs-you evidence sentence
does (34 / 27 / 25 for `none` / `tail3` / `compressed`, a nine-point spread on
a rubric field). The `none` and `compressed` rows are single passes and
triage's noise floor is three points, so the nine on needs_action is outside
the noise and still wants a second pass before anything acts on it. The
`compressed` rung (needs_action 68, reply_expected 74, summary 33) is a lower
bound and says nothing about compression itself: the digest rides in as the
third of three thread slots and is clipped to 300 characters like any thread
message, and the median digest is about 670, so the model saw the head of most
digests and nothing more. What real compression would buy is unmeasurable
until the digest is its own unclipped prompt field, which is a prompt change
and the first experiment of the follow-up round. Two more rows would cost
minutes: `none` on Nemotron Super (every cloud row ran at `tail3`), and
extraction with a thread at all — it has never seen one, and no knob for it
was built this round.

**Second pass, 2026-09-16:** `none` ran again on the 4B at 4096 tokens a
slot and read needs_action 78 and reply_expected 78, against pass 1's 75 /
75 and `tail3`'s 66 / 70 — twelve points and eight, well outside the
three-point floor. Category and urgency stayed inside it (88 / 91 against
89 / 89), and the needs-you verdict and extraction did not move at all —
those two stages run at temperature 0 and reproduced pass 1 exactly, which
is also the evidence that the smaller per-slot context between the passes
(4096 tokens a slot, against the unified 32K pool the 2026-09-14 rows ran
under, before phase 1's `CTX_SIZE = 16384`) changed nothing the model saw.
The nine points pass 1 saw were not noise. So the follow-up round's digest
experiment — the thread digest as its own field, item 1 of "what to change
next" below — takes `none` as its control, and a triage prompt without the
tail is a live candidate for shipping, pending that round's before-and-after.
The rubric side of the ladder still rests on pass 1: the summary and
needs-you-evidence fields were not re-judged on this pass.

**Measured 2026-09-17 (round B, phase 3):** both gaps are closed. The digest
is now its own unclipped `thread_digest` field on all three bulk tasks, capped
at 900 characters and trimmed by whole lines from the old end, and extraction
has its own knob (`GOLDEN_EXTRACT_CTX`). Six passes on the 4B at `GOLDEN_K=4`
under Phase 1's prompt settled it and nothing ships: triage keeps the tail
(`none` 70 / 70 then 70 / 68 against `tail3` 72 / 75 then 71 / 72, never the 4
points the rule asked for), needs-you keeps the tail (verdict 92 against 93,
judged evidence 30 against 34), and extraction stays message-alone (the tail
buys intent 75 → 78 and costs people 87 → 75 and project 66 → 53; the digest
costs people 87 → 66 and project 66 → 53). Two things did move, and they are
why the fields stay: triage's judged label / summary / action items rose 82 →
89 / 64 → 68 / 56 → 62 against the tail3 record's 86 / 63 / 60, and
`reply_expected` on the 21 keep items whose gold label needs the thread went
10 → 13 of 21 — costing needs-you evidence 34 → 30, triage p50 +27% at K=4 and
throughput 13.4 → 11.9 messages a minute. The pass-1/pass-2 finding above is
also superseded: under the new prompt `none` reads 70 / 70 where it read 78 /
78 on the old one, so a triage prompt without the tail is no longer a
candidate. The open follow-up is a triage-only digest, judged on summary and
label rather than on the booleans.

**8. The local/cloud split by machine tier**, as the speed design's §2.3 table
now reads with the set's numbers beside it. The 64 GB row is measured; the 32
GB and 16 GB rows reuse its bulk numbers, because the bulk slot is the same
model with a smaller context; the 8 GB row is the one tier whose bulk model
the set measured separately.

| machine | bulk | prose | what the set measured | cloud, opt-in |
| --- | --- | --- | --- | --- |
| 64 GB | 4B | 27B + MTP | triage 89 / 89 / 66 / 70, needs-you 92, extraction importance 39, decision 82, drafts 20%, confirm 82% on the 4B / 90% on the 27B | drafts on Opus 5 (48%) or Sonnet 5 (40%). Nothing else beats local beyond noise except extraction's importance and the summary field, and both are cheaper to move in the prompt than in the model |
| 32 GB | 4B, ctx 8K | none local | the 64 GB bulk numbers; no local decision, draft or recap | drafts on Opus 5 or Sonnet 5; the decision is triage's own boolean on `none` (78) — the dedicated task on the 4B answered 64 (item 5) — or Opus 5 / DeepSeek V3.2 (78) when a cloud call is being made anyway; confirm on the 4B, loose, so the shortlist fix matters most here |
| 16 GB | 4B, ctx 8K | cloud on demand | as above | as above. Nemotron Super (70 msgs/min, $0.69 / 1K) is the only cloud bulk model that beats the 4B on needs_action, but using it for bulk work needs rule 2 amended first (item 3), which this round does not do |
| 8 GB | Qwen3.5-4B Q4 | cloud on demand | triage 91 / 89 / 66 / 83, needs-you 87, summaries 16%, action items 53 — better enums, far worse text than the 4B | as the 16 GB row |

The tiers below 64 GB were sized, not measured, in the speed design; the table
above is the first measurement any of them has, and the 8 GB row's summary
number is the honest caveat the installer's "Your Mac" step should carry.

**9. What the set could not measure.** The gates: Tier 1 and 2 need mail
headers the set does not carry, so the gate verdict (76 of 100) is what the
app did on 2026-09-12 and no candidate was asked; the model-side proxy — does
triage call a gold-drop item a `notification` — is in every all-items pass and
was not read this round. The storyline sweep, the embedding shortlist, the
recruit laps and the chaining: the confirm replay hands the model a list a
human wrote. Drafts without the directory pack, style examples, about-me or
storyline summary, so the draft column is a floor. `thread_state`, which is
computed rather than asked. Attachment digests and this machine's custom
needs-you rules, both left out of the needs-you replay on purpose. The judge's
family bias: the rubrics were written with Claude's help and the judge is
Claude, so the rubric column compares rows and states no truth. The Converse
rows sampled at the models' default temperature. And two caveats on every
confirm row: thirteen gold candidates were judged with an empty People line,
and 22 of 30 charters were clipped. One more, about the harness: before commit
20ce25f a constrained answer that was not JSON was counted as `ok` on the
OpenAI wire, so the failure line of every bulk and prose row above may
under-count that case; their run files omit the section honestly and the scorer read
it as not attempted, so no accuracy number is affected.

**Where the app's own 76 comes from, and where the next points are.** The
stored baseline's 24 errors split 12 misses, 11 overreaches and 1 unknown (a
row still `pending` when the set was packed). The overreaches are gold keeps
the app dropped: 4 under `newsletter` headers and 3 under `auto_generated`
headers, 3 under the `no_reply` prefix, 1 as `backlog` — and 9 of the 11 are
`gate-keep-trap` items, human prose arriving under machine headers. Folding
the replay's new catches into the stored verdicts projects the live gate at
80 of 100 after round A (the four gold drops the app kept that the new shapes
catch; the trap unchanged, since the app already dropped those three). So the
larger remaining gate loss is Tier 2 overreach on the trap, not missed drops,
and it is header-side — a name rule cannot reach it, and the set cannot
replay it. That is a candidate for a later round, measured through
`make golden-baseline` after a live re-sync rather than through this replay.

**Measured 2026-09-16 (round A):** the notification proxy is 0 of 24 on gold
drops, 1 of 76 on gold keeps and 0 of 12 on the trap, identical across five 4B
runs; as a gate it would catch nothing and lose one keep, so it was not built
(`docs/pipeline/03-triage.md`). `make golden-gate` now replays the gates
offline and prints the proxy on every run; Tier 2 and the Teams ingest gates
remain unmeasured by the set.

**10. What to change next, in order.**

1. **A prompt-and-budget round with a golden before and after**, because every
   item in it is model-independent and so precedes every swap: summaries,
   where 46 to 60 of 76 items omit a required fact while the traps fire on 0
   to 4 and the text averages 113–129 characters against a 500-character cap;
   the draft prompt's "ask, don't invent" rule, since 10 to 15 of the failing
   drafts per model invent an owner-only fact; the thread digest as its own
   unclipped field for triage and needs-you and, for the first time,
   extraction, with `none` as the control and a second pass on both; the
   confirm task's 400-character charter clamp. The first two have their
   commands already (`make golden`, `make golden-prose`, then the judge); the
   digest field and the charter clamp each need a code change first — the
   clamp is a constant inside the task, and no extraction-context knob exists
   — and then `make golden` and `make golden-storyline` are their
   before-and-after. Summaries: done 2026-09-16 (round B,
   phase 1) — 39 → 63 on the same judge, action items 67 → 60 as the cost. The
   needs-you evidence sentence: measured twice the same day and not shipped
   (36 with a third of the sentences clamped, or 9 kept short; the verdict
   fell either way). The drafts: done 2026-09-16 (round B, phase 2) — the
   invention rules went to v2, missed the round's exit of three or fewer
   invented per model on all four, were revised once and shipped as v3. Of 25,
   baseline → shipped: the 27B 5 → 6 and Opus 5 12 → 17, with Sonnet 5 10 → 17
   and DeepSeek V3.2 10 → 9 on v2 only. Invented over the failing drafts fell
   on every cloud model and rose on the 27B (10 of 20 → 14 of 19), whose nine
   invented items are the same nine under every wording — so the local model's
   next lever is a separate owner-only-facts step before drafting, not more
   prompt text. v4 (2026-09-17) removed the two-options example that
   contradicted the owner-only bullet and re-measured: Opus 17 of 25 and 6 of 8
   invented, identical; the 27B 5 of 25 with the same fourteen items flagged
   (v3's whole set; the nine are the ones common to every wording since the
   baseline) across 21 changed texts — shipped, and the structural conclusion
   stands. The charter clamp: also done in phase 2 — it is a parameter
   with a `GOLDEN_CHARTER_CAP` knob now, and the replay at 400 / 800 / 1200
   gave `storyline.id` 81 / 78 / 77% with forbidden-accept 20 / 25 / 26%, so
   it stays at 400 and a longer charter is not the improvement this item
   guessed it might be. The digest field: done 2026-09-17 (round B, phase 3) —
   measured on the 4B at all three rungs, two passes each, `none` re-run under
   the new prompt; no rung ships (triage keeps the tail, needs-you keeps the
   tail, extraction stays message-alone); the digest lifted triage's judged
   label / summary / action items 82 → 89 / 64 → 68 / 56 → 62 and
   `reply_expected` on thread-dependent items 10 → 13 of 21 while costing
   needs-you evidence 34 → 30 and extraction people 87 → 66 — a triage-only
   digest is the follow-up. With that, every half of this item has a done
   note.
2. **The reply decision on the 4B**, item 5 — done 2026-09-16: 64%, so the
   decision stays on the 27B and the speed design's §1.3 item 2 is settled the
   slow way.
3. **The storyline sweep and shortlist rework**, item 6 — code, with the app's
   own 42 of 99 as the before and the confirm replay as the after — done
   2026-09-19 (Round D): five phases of code and two prompts, with `make
   golden-sweep` as the ruler; the final tree files 46 of 98 with 0 correct
   positives, against 23 of 98 and 0 on the round's first row. The exit of at
   or above 70 with correct positives was NOT met. The finding is measured:
   the clustering vector does not separate this mailbox's efforts, with
   same-effort pairs 74% at or above 0.65 against 49% for cross-effort pairs,
   and the ten clusters the namer declines 39% pure. The confirm stays on the
   4B locally and on the 27B wherever a GPU serves it.
4. **Cloud escalation** (speed design §4) with Opus 5 as the default "better
   draft" and Sonnet 5 as the cheaper option — after the prompt round, not
   before, so the consent screen promises a measured number.
5. **The gate fixes the set already encodes**: the `gate-drop-missed` (9),
   `gate-edge` (7) and `gate-keep-trap` (12) strata are tests waiting to be
   written against a gate that scores 76 of 100 today — done 2026-09-16
   (round A): `make golden-gate` replays the gate strata offline; 80 → 83
   of 100 on the replay with the trap's misses unchanged at 3; see the gate
   replay ledger.
6. **Harness housekeeping**, none of it urgent: two of the golden fixtures
   (the set loader and the registry loader) carry their own copies of the
   JSON-shape helpers; the storyline run parses a `GOLDEN_CTX` it ignores;
   `calls_per_min` divides the planned call count rather than the made one; a
   decode error escapes the loaders without the file's path; a pseudonymised
   public fixture; and whether `golden/tools/` should be versioned separately
   from the data it sits beside.
7. **The prose critical path**, the roadmap's Round C — done 2026-09-17:
   three drain lanes (fast, storyline, draft) so the 4B's work never queues
   behind the 27B's; **Suggested replies** as a setting, "For messages that
   need you" by default and at most ten prefetched; drafts streamed over the
   OpenAI wire, with the reply decision skipped for a draft somebody asked
   for. A message arriving mid-backlog is extracted in 50–98 s against
   767–800 s before, and 33 s with both slots on the box, while the fast wall
   (200–240 s for 48 messages) is the 4B's own throughput and no lane moves
   it. Not adopted: a second local prose slot (slower end to end) and the
   box's 4B as the bulk slot (a speed row, not an accuracy tie).


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
| 7 | prose (and as bulk) | vLLM 0.29.0 on an AWS `g6e.xlarge` (one L40S), `Qwen/Qwen3.8-27B-FP8` (served as the alias `qwen3.8` by `--served-model-name qwen3.8` on the box's vLLM command), served on the box's loopback :8000 and reached through `ssh -N -L 18100:127.0.0.1:8000 ubuntu@<box>` (local 18100, never 8000) | `make bench-prose PROSE_URL=http://localhost:18100/v1/chat/completions PROSE_MODEL=qwen3.8 PROSE_LABEL=vllm-g6e/Qwen3.8-27B-FP8` and the same three defines on `make golden-prose`; as bulk, the `BENCH_*` triple with `BENCH_LABEL='vllm-g6e/Qwen3.8-27B-FP8 (as bulk)'` on `make golden` and `make golden-storyline`; the MTP head with `/opt/bond/serve.sh --speculative-config '{"method":"mtp","num_speculative_tokens":2}'` on the box (label `…-FP8+MTP`). The harness prices a localhost URL at $0.00, so these rows carry the box's hourly rate by hand (`1000 / (msgs_per_min × 60) × $1.86`) |
| 8 | both | **the pipeline end to end**, not a candidate — the app's own queues over the fixture corpus | `make bench-pipeline PIPE_SHAPE=single` and `make bench-pipeline PIPE_SHAPE=lanes`, each twice, with BOTH servers up; `PIPE_COPIES` sets the corpus size (3 ≈ 48 ungated messages), `PIPE_WIDTH` the drafts in flight (the server must have been started with that many slots — `make model SLOTS=2 MODEL_CTX=32768` for two), `PIPE_LATE=0` drops the late-arrival leg. A prose slot elsewhere is the usual three `PROSE_*` defines |
| 9 | all three | **the app's own filing path**, not a candidate: the sweep, the naming, the confirms and the assign shortlist over the golden set | `make golden-sweep GOLDEN_RUN=<bulk run file>` twice on the default card, `topics`, which is the card the app ships; `SWEEP_CARD=participants` is the explicit alternative and takes two passes of its own. All of them with the embed, bulk and prose servers up. `make golden-score R=<sweep run file>` on each. The bulk run file is the newest local-4B `make golden` run; a storyline or sweep run file carries no cards and is refused |
| 10 | — | further candidates | Added here as they come up, one command per row. What is worth trying is best judged after the rows above have numbers |

## Ledger

Appended after each run, second-run numbers only (see the protocol). Prose
rows quote the draft_reply p50 in the "p50 triage ms" column's place — marked
(draft) — since prose runs never triage; from 2026-09-17 a prose row may also
carry `ttft N` in that cell, which is the streamed draft's time to first
token (`first_token_p50_ms` in the run JSON). gen t/s is wall-clock throughout;
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
| 2026-09-16 | llamacpp/Qwen3.8-27B-Q4_K_M + MTP, ctx 16K | `prose-…-20260916-023304.json` | 10.2 (12.1 srv) draft · 13.2 (15.3 srv) name · 14.2 (17.0 srv) recap | 16083 (draft) · 8460 (name) · 12733 (recap) | prose read by hand; MTP draft acceptance 66–77%, mean accepted run ~3.2 tokens | — | names and recaps are the clear win — name p50 8.5s against ~12s and recap 12.7s against ~22.6s in the app's activity log; the draft row is muddied by one 35s call (p95 35010ms) in the kept pass — the first pass read draft p50 14933ms, 13.4 tok/s (16.8 srv), p95 18783 — taken with the machine at 15GB of compressor and under 200MB unused; adopted in `local.mk`; re-bench drafts once the prose work is off the per-message critical path and the machine is not swapping |
| 2026-09-16 | llamacpp/Qwen3.8-27B-Q4_K_M + MTP, ctx 16K | `prose-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260916-223602.json` | 14.0 (17.0 srv) draft | 15722 (draft) · 8609 (name) · 11679 (recap) | prose read by hand | — | round B phase 2 — draft budget 768, invention rules v3; the recap leg ran at the generic 512 (the harness did not pass the 384 — found on the whole-branch review, fixed, re-run below); third of three passes, second identical; drafts ≈ 221 tokens and recaps ≈ 179 |
| 2026-09-17 | llamacpp/Qwen3.8-27B-Q4_K_M + MTP, ctx 16K | `prose-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260917-012727.json` | 13.9 (16.9 srv) draft | 16062 (draft) · 8605 (name) · 11833 (recap) | prose read by hand | — | ROW OF RECORD for round B's budgets — draft 768 AND recap 384 both in force, invention rules v3; second of two passes (first 16344 / 8383 / 11528); drafts 1,104 tokens over 5 (≈ 221) and recaps 537 over 3 (≈ 179), identical totals to the 512 run, so neither budget was reached and the p50s are round 0's within noise; the budgets bound the worst case, which is what the 90 s prose timeout rests on |
| 2026-09-17 | llamacpp/Qwen3.8-27B-Q4_K_M + MTP, ctx 16K | `prose-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260917-232905.json` | 14.2 (17.0 srv) draft | 17624 (draft, ttft 2955) · 8340 (name) · 11568 (recap) | prose read by hand | — | Round C phase 3 — the draft leg STREAMS; second of two passes (first 17614 / 8307 / 11548, ttft 2959). Names and recaps sit on the row of record (8605 / 11833) with identical token counts (523 / 537); the draft p50 is +1.6 s because the five drafts came out LONGER — 1,332 generated tokens against 1,104 at 14.2 tok/s against 13.9 — the date anchor in the user message moved by a day between the two runs, which is enough to change a temperature-0 draft's wording. Streaming itself costs nothing: the verify check's same-prompt pair ran plain at 17.2 tok/s (server clock) and streamed at 17.4, and on the box 5,037 ms plain against 5,000 ms streamed. TTFT per case 534 / 4,484 / 2,726 / 2,955 / 4,482 ms — the system prompt is prefix-cached, so the first token waits only on the per-message part of the prompt (1.1K tokens here); a full app draft carries 2–5K tokens of thread, passages and style, so its first words land later than these |
| 2026-09-18 | llamacpp/Qwen3.8-27B-Q4_K_M + MTP, ctx 16K | `prose-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260918-045642.json` | 14.2 (16.9 srv) draft | 17625 (draft, ttft 2956) · 8314 (name) · 11622 (recap) | prose read by hand | — | Round C phase 4 after-row, final tree, first of two passes; the draft leg streams; 1,332 generated draft tokens, the same length as the phase 3 row; TTFT per case 594 / 4,531 / 2,811 / 2,956 / 4,481 ms; the verify's same-prompt pair 13,497 ms streamed with first token at 213 ms of 229 deltas, streamed == plain |
| 2026-09-18 | llamacpp/Qwen3.8-27B-Q4_K_M + MTP, ctx 16K | `prose-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260918-050050.json` | 14.2 (17.0 srv) draft | 17612 (draft, ttft 2957) · 8342 (name) · 11531 (recap) | prose read by hand | — | Round C phase 4 after-row, final tree, second of two passes (KEPT): the draft leg streams; against the phase 3 row 17624 / 8340 / 11568 every p50 is inside 40 ms and the draft token count is the same 1,332 — the streamed client and the three lanes cost the prose slot nothing measurable; TTFT per case 444 / 4,541 / 2,726 / 2,957 / 4,480 ms (prefix-cache-bound); the verify's same-prompt pair 13,598 ms streamed with first token at 273 ms, streamed == plain |
| 2026-09-17 | vllm-g6e/Qwen3.8-27B-FP8 (AWS g6e.xlarge, one L40S, vLLM 0.29.0, no MTP, 32K ctx) | `prose-vllm-g6e-qwen3-8-27b-fp8-20260917-045218.json` | 24.6 draft · 23.6 name · 24.1 recap (wall; no server clock) | 10795 (draft) · 4415 (name) · 7362 (recap) | prose read by hand | — | GPU spike, one stream through an SSH tunnel; against the local MTP row above (16062 / 8605 / 11833) drafts 1.5×, names 1.9×, recaps 1.6× faster on wall p50 and 1.8× per token (24.6 against 13.9) — the FP8 model writes longer drafts here, 1,364 tokens over five (≈ 273 against ≈ 221) and 568 over three recaps (≈ 189 against ≈ 179); second of two passes, first 10764 / 4419 / 7364 |
| 2026-09-17 | vllm-g6e/Qwen3.8-27B-FP8+MTP (same box, `--speculative-config '{"method":"mtp","num_speculative_tokens":2}'`) | `prose-vllm-g6e-qwen3-8-27b-fp8-mtp-20260917-064055.json` | 46.5 draft · 43.8 name · 46.4 recap (wall) | 5730 (draft) · 2363 (name) · 3627 (recap) | prose read by hand | — | GPU spike, the MTP head the FP8 repo ships, ~6.5 min of recompile to load; against the same box without MTP drafts 1.9×, names 1.9×, recaps 2.0× faster, and against the local MTP row 2.8× / 3.6× / 3.3×; 1,390 draft tokens over five, 538 over three recaps; second of two passes, first 5736 / 2363 / 3622 at 46.4 / 43.4 / 46.5 tok/s; vLLM warns that speculative decoding caps `max_num_scheduled_tokens` at 2048, left as is |
| 2026-09-16 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0, ctx 16K (4096 per slot, 4 slots) | `triage-extract-…-20260916-023642.json` | 54.3 (62.9 srv) | 2234 | cat 81% · label 88% · needs_action 100% (16 items, 0 format failures, same three category misses as the 2026-09-04 baseline) | — (see the drain row below) | unchanged against the 2026-09-04 baseline (p50 2176, 54.8 tok/s) — halving the context to 4096 tokens a slot costs nothing on the fictional corpus; extraction p50 1808ms, 50.8 tok/s (61.1 srv) |
| 2026-09-16 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0, ctx 16K, 4 slots (drain) | `drain-…-k-{1,3}-20260916-023910.json` | 52.8 at K=1 · 21.9 per stream at K=3 | 2164 (K=1) · 5479 (K=3) | — | 26.6 / 31.1 / — (K=6 not run: the shipping FAST_SLOTS is 4) | K=1 matches the baseline (26.1); K=3 is 31.1 against the baseline's 25.3 on 6 slots — 1.17x over K=1, queue-wait 47ms; the K=6 champion figure (56.9) needs `FAST_SLOTS=6` and was not re-measured this round |
| 2026-09-17 | llamacpp/Qwen3.8-27B-Q4_K_M + MTP, ctx 16K, ONE slot | `prose-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260917-191414.json` | 13.8 (16.9 srv) | 18095 (draft) · 8364 (name) · 11596 (recap) | prose read by hand | — | round C phase 1 — today's control for the two-slot read below, taken on the same tree the same hour |
| 2026-09-17 | llamacpp/Qwen3.8-27B-Q4_K_M + MTP, ctx 32K, TWO slots | `prose-llamacpp-qwen3-8-27b-gguf-q4-k-m-20260917-192135.json` | 14.4 (16.9 srv) | 17193 (draft) · 8341 (name) · 11560 (recap) | prose read by hand | — | `SLOTS=2 MODEL_CTX=32768`: single-stream prose is unchanged against the row above and MTP is still active, so the second slot costs nothing per call — but the PIPELINE at width 2 was slower end to end (drafts 1,102.6 s against 896.6 at width 1, `#### Pipeline bench`), so it is not adopted and `local.mk` stays at one slot |
| 2026-09-17 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0, ctx 16K, 4 slots (drain) | `drain-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-k-1-20260917-145236.json` | 54.0 at K=1 · 21.7 per stream at K=3 | — | — | 19.2 / 22.2 / — | round C control, 16 messages per round, taken BEFORE phase 1's code — K=1 49.9 s, queue-wait 23 ms; K=3 43.3 s, queue-wait 334 ms, 1.15× over K=1. The round changes no bulk path, so this is the row a later drain is compared against |
| 2026-09-18 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0, ctx 16K, 4 slots (drain) | `drain-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-k-1-20260918-045214.json` | 53.9 at K=1 · 32.9 per stream at K=3 | — | — | 19.2 / 33.8 / — | round C after-row on the final tree, 16 messages per round — K=1 49.9 s, queue-wait 22 ms, IDENTICAL to the control; K=3 28.4 s, queue-wait 654 ms, 1.76× over K=1 against the control's 1.15× (43.3 s). The round changes no bulk path, so the K=1 identity is the reading; the K=3 gain is the idle machine (the control ran beside an editing agent), not the code |

#### Pipeline bench

`make bench-pipeline`: the whole backlog through the real `TriageQueue`,
`NeedsYouHandler`, `ExtractHandler` and `DraftHandler`. "Fast wall" is the
wall clock to every seeded message's needs-you and extract work rows being
terminal — the T2 proxy, and the point at which the inbox is usable. "Late
arrival" is one more message upserted at the moment the prose server starts
its first draft, timed to its own extraction finishing — the T1 read.

Two honest limits of the bench, which bound every row: the seed writes no
conversation rows, so the extraction leg measures the model call rather than
the card, the bucket filing or the thread embedding; and `_embedMessage` dials
a refused port once per message. Both shapes are measured on the same tree the
same day. And it is a subset of the pipeline on purpose: no storyline lane (the
sweep needs the embed server and the index), two of the fast lane's eight
handlers, a draft handler without its retrievers, and the plain draft call —
so it reads what the lanes and the width do to the walls and the late arrival,
and nothing about names, recaps or first-token time, which are `bench-prose`'s.

| date | shape | width | copies | fast wall s | drafts wall s | fast msgs/min | late arrival s | result json | notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-17 | single | 1 | 3 | 209.1 | 968.9 | 13.8 | 767.4 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-154305.json` | local 27B + MTP, one slot; 36 drafts; pass 1 |
| 2026-09-17 | single | 1 | 3 | 234.2 | 1025.7 | 12.3 | 800.0 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-160101.json` | same server; pass 2 (kept) |
| 2026-09-17 | lanes | 1 | 3 | 240.6 | 896.6 | 12.0 | 98.2 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-173049.json` | local 27B; 37 drafts; one clean pass — the first 3-copy `lanes` pass hung to the 45-minute timeout before the heartbeat and the re-pump existed, and has not reproduced since |
| 2026-09-17 | lanes | 2 | 3 | 272.7 | 1102.6 | 10.6 | 111.4 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-194024.json` | local 27B started `SLOTS=2 MODEL_CTX=32768` — SLOWER than width 1 end to end, so two local slots are not adopted |
| 2026-09-17 | single | 1 | 3 | 181.6 | 578.0 | 15.9 | 405.4 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-174148.json` | prose = vLLM on the g6e box, plain (no MTP), over the :18100 tunnel; pass 1 |
| 2026-09-17 | single | 1 | 3 | 202.0 | 596.9 | 14.3 | 403.9 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-175211.json` | box plain; pass 2 (kept) |
| 2026-09-17 | lanes | 1 | 3 | 204.2 | 565.4 | 14.1 | 51.0 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-180159.json` | box plain; pass 1 |
| 2026-09-17 | lanes | 1 | 3 | 214.3 | 577.0 | 13.4 | 49.6 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-181144.json` | box plain; pass 2 (kept) |
| 2026-09-17 | lanes | 4 | 3 | 221.7 | 285.2 | 13.0 | 73.7 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-181641.json` | box plain; pass 1 |
| 2026-09-17 | lanes | 4 | 3 | 223.9 | 288.3 | 12.9 | 73.8 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-182136.json` | box plain; pass 2 (kept) |
| 2026-09-17 | lanes | 1 | 3 | 196.5 | 381.4 | 14.7 | 49.7 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-184005.json` | box + MTP (`num_speculative_tokens` 2); draft p50 5.5 s; pass 1 |
| 2026-09-17 | lanes | 1 | 3 | 225.0 | 384.3 | 12.8 | 75.0 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-184637.json` | box + MTP; pass 2 (kept) |
| 2026-09-17 | lanes | 4 | 3 | 214.1 | 254.3 | 13.5 | 51.7 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-185101.json` | box + MTP; draft p50 6.7 s with four in flight; pass 1 |
| 2026-09-17 | lanes | 4 | 3 | 208.6 | 249.9 | 13.8 | 49.6 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-185518.json` | box + MTP; pass 2 (kept) |
| 2026-09-17 | single | 1 | 3 | 210.1 | 432.2 | 13.7 | 228.2 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-190247.json` | box + MTP; pass 1 |
| 2026-09-17 | single | 1 | 3 | 219.6 | 441.6 | 13.1 | 228.5 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260917-191028.json` | box + MTP; pass 2 (kept) |
| 2026-09-17 | lanes | 4 | 3 | 60.3 | 139.3 | 47.8 | 32.4 | `pipeline-vllm-g6e-qwen3-4b-instruct-2507-fp8-20260917-214712.json` | BOTH slots on the box — bulk = vLLM `Qwen/Qwen3-4B-Instruct-2507-FP8` on :8001, prose = vLLM `Qwen/Qwen3.8-27B-FP8` + MTP on :8000; 37 drafts; p50 triage 1,510 ms · needs-you 542 · extraction 1,764 · decision 1,960 · draft 7,801; pass 1 |
| 2026-09-17 | lanes | 4 | 3 | 60.3 | 139.4 | 47.7 | 33.2 | `pipeline-vllm-g6e-qwen3-4b-instruct-2507-fp8-20260917-215052.json` | both slots on the box; 37 drafts; p50 triage 1,504 ms · needs-you 545 · extraction 1,754 · decision 2,138 · draft 7,397; pass 2 (kept) |
| 2026-09-18 | single | 1 | 3 | 157.9 | 826.4 | 18.2 | 677.1 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260918-001746.json` | Round C phase 4, final tree, local 27B + MTP one slot, policy `all`; 36 drafts; p50 triage 4,519 ms · needs-you 2,031 · extraction 2,705 · decision 2,878 · draft 15,228; pass 1 |
| 2026-09-18 | single | 1 | 3 | 174.0 | 847.4 | 16.5 | 681.8 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260918-041751.json` | same tree and servers; 36 drafts; p50 triage 4,532 ms · needs-you 2,714 · extraction 2,718 · decision 2,840 · draft 15,235; pass 2 (kept) |
| 2026-09-18 | lanes | 1 | 3 | 218.1 | 871.5 | 13.2 | 98.0 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260918-043401.json` | same tree and servers; 37 drafts; late arrival upserted at 133 s, needs-you done 94.2 s later, extract 98.0 s later; p50 triage 4,595 ms · needs-you 2,955 · extraction 4,560 · decision 3,061 · draft 14,977; no re-pumps; pass 1 |
| 2026-09-18 | lanes | 1 | 3 | 210.5 | 865.4 | 13.7 | 95.7 | `pipeline-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260918-045009.json` | same tree and servers; 37 drafts; late arrival upserted at 128 s, needs-you done 92.7 s later, extract 95.7 s later; p50 triage 4,641 ms · needs-you 2,727 · extraction 4,731 · decision 3,070 · draft 15,326; no re-pumps; pass 2 (kept) |

**Phase 1 read (2026-09-17).** Every row is 3 copies of the fixture corpus —
48 ungated messages — through the real queues. Across the Phase 1 rows (the
2026-09-17 rows whose bulk label is the local 4B) the bulk slot is the local 4B
on :8082 at four slots throughout; only the prose slot and the shape move. The
two `vllm-g6e-qwen3-4b` rows and the 2026-09-18 group are read below.

The lanes do what they were cut for. A message arriving mid-backlog is
extracted in **50–98 s** instead of **767–800 s** locally on 2026-09-17
(677–682 s in the 2026-09-18 pair), **404–405 s** against the box, and
**228 s** against the box with MTP: in `single` that message waits
for the pass in flight, every draft in it, and in `lanes` it costs one triage
plus one needs-you plus one extraction. Width pays where the server has slots
for it: 4 on the box finishes the drafts **40–60 s** after the fast phase
(285.2 s against a 221.7 s fast wall; 254.3 against 214.1 with MTP), where
width 1 on the same box takes 565–577 s.

The fast wall is the floor this round does not move: **≈200–240 s** for those
48 messages, 12–14 msgs/min on the 4B, in every 2026-09-17 row and every shape
— and 158–218 s (13–18 msgs/min) in the 2026-09-18 group, taken on an idle
machine: the same floor, set by the same server. Nothing here touches it — it
is the bulk slot's own throughput, which `make drain` measures directly.

The second local slot was measured and not adopted. `SLOTS=2
MODEL_CTX=32768` leaves single-stream prose unchanged (the two `bench-prose`
rows in the ledger below), but at pipeline width 2 the drafts took **1,102.6 s**
against **896.6 s** at width 1, so `local.mk` stays at one slot. 4 remains the
measured value for a GPU-served target, not for this Mac. Both of those are
single passes, against the house rule of two: the 23% margin is read as
decisive only because it runs the wrong way on the fast wall too (272.7 s
against 240.6), and a second pair is owed before two local slots are reopened.

Two caveats on the reading. The local `lanes` row is ONE clean pass, and its
98.2 s late arrival includes a 4B that was still mid-backlog when the message
landed. And the bench asserts nothing about accuracy — it prints answers and
times them; the golden set is where quality is read.

**Both slots on the box (2026-09-17, Phase 2).** Every row above keeps the
bulk work on the local 4B, and reads a fast wall of **200–240 s** (12–14
msgs/min) on that day — the floor Round C does not move. With the bulk slot on the box as
well, the same 48 messages clear the fast phase in **60 s** (47.7 msgs/min) and
every draft is written by **139 s**. A message arriving mid-backlog is triaged,
judged and extracted in **≈33 s**, against 50 s with the box's prose slot alone
and 98 s all-local.

Two things this row is not. It is a SPEED row and not an adoption: the box's 4B
is not an accuracy tie with the local Q8_0 4B on the golden set (those rows sit
on the `feat/inference-endpoint` branch), so the bulk slot stays local per the
roadmap's settled list until that gap is explained. And the 33 s late arrival
is not model time — the newcomer's three calls total about 4 s. It is the fast
lane's drain granularity: the triage drain, and then the worker pass, each
finish the batch they are already holding before the new row is reached. That
is a Round C observation for T1, not something this phase changes.

**Round C after-rows (2026-09-18, Phase 4).** The same 48 messages on the
final tree, both shapes twice, the local 4B on the bulk slot and the local 27B
with MTP on the prose slot. These four rows are read against EACH OTHER and
not against the Phase 1 rows above: they were taken on an idle machine, where
the Phase 1 rows were taken while an agent was editing beside them, so their
absolute walls are faster for a reason that has nothing to do with the code —
Phase 1's rows keep their own within-day comparison, and this group has its
own. `single` pass 1 reads a fast wall of 157.9 s (18.2 msgs/min), 826.4 s to
the drafts and a 677.1 s late arrival, and pass 2 — the kept one — 174.0 s
(16.5 msgs/min), 847.4 s and 681.8 s; `lanes` pass 1 reads 218.1 s (13.2
msgs/min), 871.5 s and 98.0 s, and pass 2 — the kept one — 210.5 s (13.7
msgs/min), 865.4 s and 95.7 s. Every row in this table runs draft policy
`all` — the bench has no `PIPE_POLICY` knob — so the drafts column is
the WORST case and not what the app does: the shipped default is "For messages
that need you", which prefetches at most ten and writes the rest when somebody
asks.

What the two shapes cost each other on THIS machine, kept pass against kept
pass: `single` 174.0 s fast wall / 847.4 s drafts / 681.8 s late arrival
against `lanes` 210.5 / 865.4 / 95.7 — a **7.1× shorter wait** for a message
arriving mid-backlog, bought with 36 s on the fast wall and 18 s on the
drafts wall. The two lanes share one GPU here, so the 27B's drafts now decode
beside the 4B's triage and extraction instead of after them, and extraction's
p50 goes 2,718 → 4,731 ms. The Phase 1 rows show the same shape (`single`
209–234 s fast wall, `lanes` 240.6 s). That trade is the point of the split
for the person using the app — the inbox is usable half a minute later, and a
message that arrives mid-backlog is triaged and extracted nearly ten minutes
sooner (the clock stops at its extraction; its own draft is not timed) — and
it disappears on a target with a GPU of its own for the prose slot, which is
what the box rows above read.

**Round C (2026-09) — the prose critical path.** What shipped on branch
`feat/pipeline-round-c`: three drain lanes instead of one handler list (fast,
storyline, draft), each behind its own gate, so the 4B's work never queues
behind the 27B's; the draft lane's width as a setting (**Drafts in flight**,
`AppPrefs.proseParallel`, 1 by default); **Suggested replies**, which
prefetches at most ten drafts for the messages the pipeline judged to need
their owner and leaves the rest until somebody asks; and drafts streamed over
the OpenAI wire, with the reply decision skipped for a draft that was asked
for. `make bench-pipeline` was built to measure it, and its rows read: a
message arriving mid-backlog extracted in 50–98 s against 677–800 s in the old
shape, while the fast wall — 158–240 s for 48 messages across the two days,
13–18 msgs/min — is the bulk slot's own throughput and does not move with the
shape. Golden-prose was re-run once
to show the prompts had not shifted: the decision reads 82% and 25 of 25
drafts are byte-identical to `…-020022.json`, all 76 decisions with them, so
nothing was re-judged. Not adopted: a second local prose slot (`SLOTS=2
MODEL_CTX=32768` leaves single-stream prose unchanged but the pipeline is
slower end to end) and the box's 4B as the bulk slot (a speed row, not an
accuracy tie). The three simplifications this round wrote down rather than
built — one shared `LlmClient` test double, `firstTokenMs` in the activity
log, a `PIPE_POLICY` knob — are in the roadmap's §10.

**Round D (2026-09) — storyline formation.** What shipped on branch
`feat/pipeline-round-d`: `make golden-sweep`, the bench that puts the golden
conversations through the app's own clustering, naming, confirms and assign
shortlist and scores the filing by membership; a clustering rule that asks a
candidate for two links and half of a cluster's members, caps a cluster at
twelve and splits anything under a 0.60 coherence floor; the `topics`
clustering card under the tag `embeddinggemma-300M/clustering-v2`, shipped
with a one-shot re-embed on the sync; a lexical series pre-pass that seeds a
recurring series as its own cluster and keeps notification-shaped ones out of
the pool; a namer that can answer `coherent: false`, name its outliers and
read up to twelve whole central cards; a charter lint; three confirm rules and
`high` for a suggested storyline through one `_accepts` helper; an assign
shortlist that discounts only on two shared non-owner people, confirms a
near-tie both ways and audits a catch-all at `max(0.30, 2/k)`; and a sweep
that defers above three queue floors, is re-armed by the fast lane, expires an
unanswered suggestion at 14 days and folds thread fragments onto one
representative. Every phase carries its own row on the same mailbox.

| phase | what it added | storyline.id | correct positives |
|---|---|---|---|
| 1, participants card | the bench itself | 23/98 | 0 |
| 1, topics card | the card comparison | 31/98 | 0 |
| 2 | the join rule and the topics card | 37/98 | 11 |
| 3 | the series pre-pass, the namer's out, the lint | 47/98 | 7 |
| 4 | the confirm rules and the shortlist | 48/98 | 6 |
| 5 and 6 | the lifecycle rules, the final tree | 46/98 | 0 |

**The round's exit, 70 of 98 with correct positives, was NOT met.** A sweep
that files nothing scores 50 of 98 on this scorer, so the final row sits
below the abstention floor with no positives on top of it. Phase 6 measured
why rather than guessing: the ten clusters the namer declines are
39% gold-pure, and the pool's same-effort pairs sit in the same cosine band as
its cross-effort pairs, 74% against 49% at or above 0.65, so the clustering
vector is the ceiling and no join rule on it can lift the filing. The
confirm model is decided rather than switched: the 4B locally, the 27B
wherever a GPU serves the stage, with no candidate reaching the target of 88%
at neighbours of 10% or under. Not adopted, each measured: a propose floor of
two, a link threshold of 0.60, the propose floor counting folded rows, the
series-key fragment identity, and the box's 4B as the confirm model. The three
simplifications this round wrote down rather than built are in the roadmap's
§10.

**Memory, round 0 (2026-09-16).** With MTP on and both chat servers at 16K
context, the three servers' resident sizes are 22.0GB (27B + MTP sidecar),
4.1GB (4B, 4 slots) and 0.3GB (embed) — 26.4GB, inside the speed design's
≤ 28–30GB target for the app's servers. The machine-wide reading did not move
(35GB wired, 15GB compressor with Docker quit, against 31GB wired with Docker
running before the change) because other processes fill what the servers
release; the number to hold the servers to is their own footprint.

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
candidates were a speed tie on drafts as measured 2026-09-04, before MTP
(p50 22.2–22.5s, gen t/s within ±4%), so the only thing left to switch for is
prose quality, and that is a reading judgement, not a scorecard — the
verbatim titles and drafts from every run are in the bench logs and JSONs for
exactly that comparison. On the measurables there is no reason to move.
Since round 0 (2026-09-16) the ggml-org Q4_K_M runs with its MTP head and a
16K context on the maintainer's machine (`SPEC_TYPE = draft-mtp` and
`CTX_SIZE = 16384` in the gitignored `local.mk`; a fresh clone still gets the
Makefile defaults) — names 29% and recaps 44% faster, ledger rows above. The Unsloth UD-Q4_K_XL quant costs nothing to keep cached if a quality
read later favors it. GPU spike (2026-09-17): the same 27B as `Qwen/Qwen3.8-27B-FP8` on vLLM on one L40S matched the local 27B on the reply decision (82% against 82%) and the drafts (6 of 25 against 5), with invention four fewer (10 against 14) and every prompt-stable as-bulk enum within 4 points, at 1.5–1.9× the per-stream draft speed without its MTP head and 2.8× with it, and 43.1 / 54.6 messages a minute at K=4 without / with MTP — rows above, decision in the roadmap's E3; not adopted, `local.mk` and Settings unchanged.
Since Round C (2026-09-17) the prose slot serves two lanes rather than a
tail of one list — the storyline passes and the drafts — with **Drafts in
flight** as the draft lane's width (1 locally, 4 the value measured on the
L40S box), and drafts stream.

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
