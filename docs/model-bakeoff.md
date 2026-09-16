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
| 2026-09-16 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | none | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260916-032602.json` | 88% / 91% / 78% / 78% / 93% / 75% / 39% / 66% / 26% / 87% | pass 1 judge: label 83% · action items 71% · summary 34% · needs-you evidence 34% · extract evidence 24% (pass 2 not judged) | 2232 / 1513 / 2113 (triage / needs_you / extraction) | 40.3 | 8.9 | $0.00 | context ladder: message alone; second of two passes — pass 1 (2026-09-14) read needs_action 75 / reply_expected 75; 4 slots at 4096 tokens each, no failures |
| 2026-09-14 | bulk | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | compressed | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-181030.json` | 89% / 89% / 68% / 74% / 91% / 75% / 39% / 66% / 26% / 87% | label 80% · action items 62% · summary 33% · needs-you evidence 25% · extract evidence 24% | 2452 / 1684 / 2028 (triage / needs_you / extraction) | 40.4 | 8.7 | $0.00 | context ladder: digest + two newest tail messages, 300-char clip — lower bound (one pass) |
| 2026-09-14 | bulk | llamacpp/Qwen3.5-4B-UD-Q4_K_XL | tail3 | `golden-run-llamacpp-qwen3-5-4b-ud-q4-k-xl-20260914-190503.json` | 91% / 89% / 66% / 83% / 87% / 79% / 66% / 63% / 29% / 88% | label 82% · action items 53% · summary 16% · needs-you evidence 23% · extract evidence 33% | 2838 / 1716 / 2745 (triage / needs_you / extraction) | 36.9 | 7.5 | $0.00 | candidate bulk model, 1 slot on :8083; second of two passes |
| 2026-09-14 | bulk | llamacpp/Qwen3.5-9B-Q4_K_M | tail3 | `golden-run-llamacpp-qwen3-5-9b-q4-k-m-20260914-200430.json` | 91% / 93% / 64% / 70% / 83% / 82% / 74% / 64% / 24% / 83% | label 78% · action items 62% · summary 24% · needs-you evidence 25% · extract evidence 38% | 4394 / 2648 / 4444 (triage / needs_you / extraction) | 22.8 | 4.6 | $0.00 | candidate bulk model, 1 slot on :8083; second of two passes |
| 2026-09-14 | bulk | llamacpp/Qwen3.8-27B-Q4_K_M (as bulk) | tail3 | `golden-run-llamacpp-qwen3-8-27b-q4-k-m-as-bulk-20260914-223320.json` | 92% / 95% / 72% / 84% / 93% / 86% / 74% / 58% / 32% / 93% | label 89% · action items 64% · summary 41% · needs-you evidence 39% · extract evidence 41% | 13412 / 8969 / 13907 (triage / needs_you / extraction) | 7.1 | 1.5 | $0.00 | accuracy ceiling for these prompts: the prose model doing bulk work, 1 slot, no MTP; second of two passes |
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

#### Storyline confirm

The confirm task against the gold registry, per the block above.
`storyline.id` is the scorer's number over the items it counts — a `may` item
is skipped unless it was filed under a forbidden slug, so the denominator is
98 or 99 — and the rest are the replay's own rates.

| date | bulk label | cards from | run file | storyline.id | gold-accept must / should | forbidden-accept | extra-accept | derived none on gold-none | low-yes | p50 ms | calls/min | msgs/min | $/1K msgs | note |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-09-15 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0-GGUF | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-20260914-174707.json` | `golden-run-llamacpp-qwen3-4b-instruct-2507-q8-0-gguf-storyline-20260915-031444.json` | 80/98 (82%) | 47/48 (98%) / 10/15 (67%) | 17/88 (19%) | 14/300 (5%) | 26/35 (74%) | 0 | 1146 | 51.4 | 11.3 | $0.00 | shipping 4B; cards from its own tail3 run; ties 15; derived gold 50 / none 32 / other 18; 4 storylines without items, 13 gold candidates with an empty People line, 22 charters over the clamp |
| 2026-09-15 | llamacpp/Qwen3.8-27B-Q4_K_M (as bulk) | `golden-run-llamacpp-qwen3-8-27b-q4-k-m-as-bulk-20260914-223320.json` | `golden-run-llamacpp-qwen3-8-27b-q4-k-m-as-bulk-storyline-20260915-045507.json` | 88/98 (90%) | 43/48 (90%) / 8/15 (53%) | 6/88 (7%) | 1/300 (0%) | 33/35 (94%) | 0 | 6373 | 9.2 | 2.0 | $0.00 | 27B in the bulk slot; cards from its own as-bulk run; ties 3; derived gold 50 / none 45 / other 5; 4 storylines without items, 13 gold candidates with an empty People line, 22 charters over the clamp |
| 2026-09-15 | bedrock/nemotron-super-3-120b | `golden-run-bedrock-nemotron-super-3-120b-20260915-011547.json` | `golden-run-bedrock-nemotron-super-3-120b-storyline-20260915-050910.json` | 86/97 (89%) | 45/48 (94%) / 7/15 (47%) | 15/88 (17%) | 2/299 (1%) | 32/35 (91%) | 0 | 909 | 251.6 | 55.5 | $0.75 | OpenAI wire; cards from its own Phase 4 run; the failed call's item is unfiled (not attempted); 1 failed calls; ties 5; incomplete 1; derived gold 49 / none 41 / other 9; 4 storylines without items, 13 gold candidates with an empty People line, 22 charters over the clamp |

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

**2. Needs-you stays local on every tier.** The verdict is 92% on the 4B, 93
on the 27B and on the 120B, 92 on Haiku; nothing beats the shipping model
beyond the noise floor, and part of that recall is the deterministic floor,
which costs no model at all. The models differ on the evidence sentence (27 on
the 4B, 39 on the 27B, 48 on Haiku), which is a shown sentence and worth a
prompt experiment, not a model swap for a one-point verdict.

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
screen is a product call, not a bakeoff call. Two caveats sit on the whole
column. Every model's draft failures have the same shape — of the failing
drafts, 10 to 15 per model invent a fact only the owner knows — so the "ask,
don't invent" rule in the draft prompt precedes any swap and any escalation,
and the four prose rows are re-run after it. And the replay drafts from the
message and its tail alone, with no directory pack, style examples, about-me
or storyline summary, so every pass rate here is a floor on what the app would
produce.

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
   before-and-after.
2. **The reply decision on the 4B**, item 5 — done 2026-09-16: 64%, so the
   decision stays on the 27B and the speed design's §1.3 item 2 is settled the
   slow way.
3. **The storyline sweep and shortlist rework**, item 6 — code, with the app's
   own 42 of 99 as the before and the confirm replay as the after.
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
| 2026-09-16 | llamacpp/Qwen3.8-27B-Q4_K_M + MTP, ctx 16K | `prose-…-20260916-023304.json` | 10.2 (12.1 srv) draft · 13.2 (15.3 srv) name · 14.2 (17.0 srv) recap | 16083 (draft) · 8460 (name) · 12733 (recap) | prose read by hand; MTP draft acceptance 66–77%, mean accepted run ~3.2 tokens | — | names and recaps are the clear win — name p50 8.5s against ~12s and recap 12.7s against ~22.6s in the app's activity log; the draft row is muddied by one 35s call (p95 35010ms) in the kept pass — the first pass read draft p50 14933ms, 13.4 tok/s (16.8 srv), p95 18783 — taken with the machine at 15GB of compressor and under 200MB unused; adopted in `local.mk`; re-bench drafts once the prose work is off the per-message critical path and the machine is not swapping |
| 2026-09-16 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0, ctx 16K (4096 per slot, 4 slots) | `triage-extract-…-20260916-023642.json` | 54.3 (62.9 srv) | 2234 | cat 81% · label 88% · needs_action 100% (16 items, 0 format failures, same three category misses as the 2026-09-04 baseline) | — (see the drain row below) | unchanged against the 2026-09-04 baseline (p50 2176, 54.8 tok/s) — halving the context to 4096 tokens a slot costs nothing on the fictional corpus; extraction p50 1808ms, 50.8 tok/s (61.1 srv) |
| 2026-09-16 | llamacpp/Qwen3-4B-Instruct-2507-Q8_0, ctx 16K, 4 slots (drain) | `drain-…-k-{1,3}-20260916-023910.json` | 52.8 at K=1 · 21.9 per stream at K=3 | 2164 (K=1) · 5479 (K=3) | — | 26.6 / 31.1 / — (K=6 not run: the shipping FAST_SLOTS is 4) | K=1 matches the baseline (26.1); K=3 is 31.1 against the baseline's 25.3 on 6 slots — 1.17x over K=1, queue-wait 47ms; the K=6 champion figure (56.9) needs `FAST_SLOTS=6` and was not re-measured this round |

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
read later favors it.

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
