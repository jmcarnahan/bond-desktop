# 10 · Model routing, failure policy, and the prompt fence

Since the decision-model round (2026-09-27) the app talks to THREE models, one
per role, and which server a stage dials is a RULE over the role placements
rather than a stored map:

| Role | What it does | Where it can run |
|------|--------------|------------------|
| **Decision** | Every choice-shaped answer, twelve questions: the nine message fields (one call per message) and the three storyline questions. The fine-tuned ModernBERT classifier (one embedding call, heads applied in Dart from this Mac's heads file) on this Mac or at a llama-server URL; a Kev 4B server (`/v1/systemone`) answers the questions itself and needs no files here | this Mac (Managed) or Your server |
| **Generative** | Every piece of text: summaries, digests, briefs, storyline names and recaps, drafts | this Mac (Managed: the 27B or the 4B) or Your server |
| **Embeddings** | Clustering and search vectors | this Mac, always; not a choice |

Plus one optional target that is not a role: **cloud drafts**, the one place a
third-party service may serve, and only the two draft stages.

The code is `app/lib/services/llm/model_slots.dart` (the stage table, the ids,
the host rules) and `AppPrefs` in `app/lib/providers/prefs_provider.dart` (the
resolution). The words on screen are in `docs/settings.md`.

## Three roles, one rule

Every stage that dials a model has a row in `pipelineStages`, and the row's
`slot` is its role (`ModelSlot { generative, decide, embed }`;
`roleOfStage` maps it to `StageRole { decision, generative, embed }`):

| Stage | Role |
|-------|------|
| `decision` | Decision |
| `message_text`, `attachment_digest`, `context_file_digest`, `context_brief`, `context_select` | Generative |
| `storyline_name`, `storyline_refresh`, `storyline_recap` | Generative |
| `draft_reply`, `draft_improve` | Generative, or cloud drafts (below) |
| `meeting_brief` | Generative — never cloud drafts |
| `calendar_intent` | Generative — never cloud drafts; on demand, not a lane |
| `ask_read` | Generative — never cloud drafts; on demand (the draft lane pre-warms it from Phase 3) |
| `embeddings` | Embeddings, not routed |

`meeting_brief` (the pre-meeting brief, [14-calendar.md](14-calendar.md#briefs))
is deliberately NOT in `draftStageIds`: it is written FOR the owner, never in
their name, so rule 4 below sends it to `generativeSpec` whatever Cloud drafts
says (the calendar round's D9). `llm_routing_test` pins it.

`calendar_intent` (a Day command the rules could not finish,
[14-calendar.md](14-calendar.md#commands)) is generative too, and on demand:
no work kind and no lane — `CommandRouter.submit` calls it on Enter only,
at most once, and only when the best classifier's confidence (the command
head's when one ships, else the lexicon's) is under 0.8 or a slot is
unresolved with words left over. The live preview never calls it. It is
not in `draftStageIds` either: it reads the owner's own words and writes
nothing in their name, so Cloud drafts never sees it.

`ask_read` (a scheduling ask's own words read for the days, hours and
length it asks for, [14-calendar.md](14-calendar.md#reading-the-ask)) is
generative and on demand in the same way: no work kind and no lane —
`AskReader.readFor` is called when an ask opens in the Day column (the
draft lane pre-warms its cache from Phase 3). The model only copies phrases; Dart
resolves every date. It is not in `draftStageIds`: it reads somebody
else's words for the owner and writes nothing in their name, so Cloud
drafts never sees it.

There is no storyline-membership or storyline-grouping stage: whether a thread
belongs to a storyline is the decision model's `member_of`, which threads the
sweep groups is the cosine clustering (a pair grouping on the decision model's
`same_effort` was measured and removed), and whether a charter names one specific
effort is its `charter_specific`, all asked through `StorylineJudge` on the
decision client (the calls are labelled `decision:<question id>`). A decision
failure parks the storyline lane as it parks triage (see
[06-storylines.md](06-storylines.md#membership-on-the-decision-model)). The
`storyline_group` stage and its task were deleted in the decision-questions
round.

There is no reply-decision stage: whether a prefetched draft is wanted is the
decision model's `reply_expected` probability, stored at triage and read by
`DraftHandler` before it gathers anything (see
[07-replies.md](07-replies.md#reply-decision--should-we-spend-drafting-time-at-all)).

`AppPrefs.specForStage(stageId)` is the whole routing rule:

1. `embeddings` → null. The embedding client has its own request target
   (`embedRequestTarget`, below) and is never moved.
2. `decision` → `decisionSpec`.
3. `draft_reply` / `draft_improve` (`draftStageIds`, the one place the pair is
   named) → `cloudDraftsSpec` when one is set AND it is either the owner's own
   host or `cloud_drafts_consent` stands; otherwise `generativeSpec`.
4. Every other stage → `generativeSpec`.

The consent is checked HERE, where the target is resolved, and not only on the
screen that records it, so prefs restored from a backup or edited by hand
cannot route a draft off the machine on their own. `specById` answers the
fixed ids back (the composer's "Improved with <name>" reads it off a draft
row).

**Classification is the decision model's; text is one generative call
(Phases 5–6).** The triage queue runs one decision pass per kept inbound
message and makes NO language-model call: the learned gate, urgency,
category, the two booleans, the needs-you probability and the
intent/importance filed into the extraction blob come from it (see
[03-triage.md](03-triage.md) and [11-needs-you.md](11-needs-you.md)). The
message's text is ONE generative call, the `message_text` stage
(`MessageTextTask`, run by `ExtractHandler` under work kind `extract`: summary,
action items, deadline, topics, project — see
[04-extraction.md](04-extraction.md)). The retired `triage` and `extraction`
stage rows are gone from `pipelineStages`, and so is `needs_you`: no
language model is asked about needs-you at all (the owner's slider over the
decision model's probability is the one rule). A per-message pipeline costs the
decision pass and one `message_text` call (plus the draft, when one is
written). The label a call records (`LlmCallRecord.label`) is its schema:
`decision`, `message_text`, `attachment_digest`, …

**The decision model's second consumer: the Day bar's command head (the
calendar round).** The calendar command bar asks the SAME decision client
(`decisionClientProvider`, so the same target, key, identity probe and heads
file) for the raw pooled vector of a typed command
(`DecisionClient.embedRaw`, call records labelled `command_head`) and applies
a second, separately fitted linear head in Dart (`CommandHeads`,
`app/assets/calendar/command_heads.json`, tied to the question set's
`expectedQhash` AND to the installed model by name, `encoder_model` against
the installed heads' `model`). Unlike triage it never parks: no head file, a
refused one, a head fitted on another model, a decision role that is not
installed or not served (then no request is made at all), or a decision
server that is down means the lexicon reads the command alone
([14-calendar.md](14-calendar.md#the-command-head)). There is no stage row
and no routing of its own; it follows the decision role wherever that runs.

**Its third: scheduling asks.** Find a time makes NO model call: it
reads the `intent` answer triage already stored in `message_decisions` for a
thread's newest inbound message, and a `needs_reply` thread whose answer is
`scheduling` at p ≥ `DecisionPolicy.booleanYes` gets the thread header's
**Find a time** and a row in the Day column's "Scheduling asks · N"
([14-calendar.md](14-calendar.md#find-a-time)). A message the decision model
never read is simply not an ask.

**And two more readers of stored answers.** Also without a call of their
own, the calendar reads triage's `message_decisions` rows in two more places.
The Day stop's invites owed pin an invite whose mail is `urgency ∈ {high,
urgent}` or `importance = high`. The pre-meeting brief's gatherer uses the
same rule to rank the threads it keeps. It picks an attendee's open asks by
`needs_you_p ≥ DecisionPolicy.needsYouYes` or `reply_expected_p ≥
DecisionPolicy.replyYes`, with a question, request or approval `intent`
([14-calendar.md](14-calendar.md#briefs)). A message with no
stored decision is neither pinned nor an ask. A decision read that throws
costs an invite its pin, never the list.

Why one generative model: the decision model answers every classification
field in one forward pass of tens of milliseconds, so what is left for a chat
model is text a person reads, and one server for all of it is one prompt cache,
one timeout and one placement. The fast/prose split existed to put labels on
the 4B and prose on the 27B; with the labels gone the split has nothing to do.

## Where each role runs

Each role has its own placement (`ModelPlacement { box, local }`; `box` is
"Your server" in code, a historical word, and `local` is this Mac):

| Role | Placement key | Default |
|------|---------------|---------|
| Generative | `model_placement` (Round H's key, reused) | `box` in a build compiled with `BOND_BOX_URL`, `local` otherwise (`defaultModelPlacement`) |
| Decision | `decision_placement` | `local` whatever the build: it reads every message, and a local pass beats any network hop |

Each role's spec resolves in the same order, per call:

1. **Your server**, when the placement is `box` AND an address resolves AND it
   is the owner's own (not third party, not the Converse wire).
2. **The managed router**, when the app runs its own server
   (`managedServer`, true unless the build says `BOND_DEV_HAND_SERVERS`).
3. **The hand-started server** of a `BOND_DEV_HAND_SERVERS` build.

| | Generative (`generativeSpec`) | Decision (`decisionSpec`) |
|---|---|---|
| Your server: id | `box-prose` | `box-decide` |
| Your server: URL | `box_big_url`, else `$BOND_BOX_URL/prose/v1/chat/completions` | `decision_url`, else `$BOND_BOX_URL/decide/v1/embeddings` |
| Your server: model | `box_big_model` (discovered), else `qwen3.8` (`boxProseModel`) | `decision_model` (discovered), else `bond-decide-mbl-v3` (`boxDecideModel`) |
| Your server: width | drafts 4 when the URL follows the build, 1 for a stored address; message text 8 either way | 1 |
| Managed: id, URL | `local-generative`, `<router>/v1/chat/completions` | `local-decision`, `<router>/v1/embeddings` |
| Managed: model | `managedGenerativeIdFor(tier, generative_managed_model)`: `bond-prose` (27B) or `bond-bulk` (4B) | `bond-decide` |
| Hand servers | `LLAMA_URL` / `LLAMA_MODEL` (`:8080`, `qwen3.8`) | `DECIDE_URL` / `DECIDE_MODEL` (`:8083`, `bond-decide`, `make decide`) |

- **Empty means "follow the build".** `box_big_url`, `box_big_model`,
  `decision_url` and `decision_model` are stored EMPTY whenever the value
  equals what the build derives; the writers compare against
  `$BOND_BOX_URL/prose/v1/chat/completions` and `…/decide/v1/embeddings` and
  store `''` on a match. A model default is a fact about the build, and
  freezing today's value into the database would hide a changed define. The
  compiled box serves both under one origin: `/prose` is its vLLM 27B and
  `/decide` its llama.cpp decision slot (`tools/inference.sh --decide-gguf`,
  `docs/inference-endpoint.md`).
- **The width.** Two numbers on `LlmTargetSpec`: `parallel` (drafts) and
  `textParallel` (message text — extraction and the attachment digests; 1–8,
  default 3). Message text runs EIGHT wide on Your server, whether the URL
  follows the build or was typed: it is the owner's own server either way (a
  third-party host is refused for this role), and a server with fewer slots
  queues the extra requests rather than failing them. A URL that follows the
  build is four wide for drafts. The compiled box's PROSE-ONLY profile runs vLLM at
  `--max-num-seqs 16` (`tools/inference.sh`), which leaves the rest to the
  storyline lane; with a bulk slot (`--bulk-model`) the prose slot has 8
  sequences and vLLM queues the extra requests, their wait counting against
  the client's 90 s timeout (`LlmClient.proseTimeout`, every generative
  stage's). On a one-slot server the eighth text waits ~7 calls, so a server
  slower than ~11 s per text would time out; the box is ~4 s. The digests
  share extraction's eight: they
  drain after it on the same lane, one kind at a time. A stored address is
  one at a time for drafts, because drafts stream and a one-slot
  llama-server queues the rest past the generative client's ninety-second
  ceiling. Message text on a stored address was three wide until the owner's
  2026-10-01 replay, where ~730 texts at ~20 per 30 s took ~15 min. The managed generative width is `prose_parallel`
  (1–8, default 1), and message text takes it but never fewer than three.
- **The managed generative model.** `generative_managed_model` is `''` (by
  hardware tier: the 27B on the full tier, the 4B on the inbox tier),
  `bond-prose` or `bond-bulk`. The 27B on the inbox tier is refused by
  `managedGenerativeIdFor` itself and reads as the 4B, because that machine
  never downloads it. The tier is not stored: `AppPrefs.machineTier` is told by
  `setMachineTier`, from the supervisor's preset build and from
  `useGenerative`, and is `full` until told.
- **The wire** is read off the host (`wireForHost`): a Bedrock runtime host
  speaks Converse, everything else OpenAI. Nobody picks a protocol.

**Third-party hosts are refused for both roles.** Both read every message, so
neither may run at a vendor. `isThirdPartyHost` is a Bedrock runtime host
(`bedrock…amazonaws.com`) or `anthropic.com`, `openai.com`, `deepseek.com` and
their subdomains. AWS as a whole is NOT third party: the owner's GPU box is an
EC2 instance they rent and run, reached by a Route 53 name, an EC2 public name
or an `ssh` tunnel at `localhost:18100`. Loopback is not a signal either way.
The writers throw `ArgumentError` on such an address
(`AppPrefsNotifier.generativeThirdPartyRefusal`: "the generative model reads
every message; a third-party service can serve cloud drafts only";
`decisionThirdPartyRefusal`: "the decision model reads every message; it runs
on this Mac or a server of your own"), and the specs refuse it again at
resolution (`_ownServer`), so a hand-edited row falls back to this Mac rather
than routing every message to a vendor.

**Cloud drafts** (`cloudDraftsSpec`, id `cloud-drafts`) is set only when both
`cloud_drafts_url` and `cloud_drafts_model` are non-empty. It may be a third
party; `useCloudDrafts` refuses one while `cloud_drafts_consent` is false (the
consent pane records the acknowledgement first), and the owner's own host
needs no consent. `clearCloudDrafts` forgets the address, the model and the
key, and the draft stages fall back to the generative model at once. The
standing rule and the daily cap are the draft lane's, in
[07-replies.md](07-replies.md).

**The writers.** `useGenerative({placement, managedModel?, url?, model?, key?,
hardwareTier})`, `useDecision({placement, url?, model?, key?})`,
`useCloudDrafts({url, model, key?})` and `clearCloudDrafts()`. Each validates
everything before writing anything, so a refusal leaves the install as it was;
a null URL or model keeps what is stored, and a blank key keeps the stored
token. The three setters also take `clearKey`, which the forms pass when the
address moved to another HOST: a key typed with it replaces the old one as
usual, and a blank key with it FORGETS the old host's token (`clearRoleKey`)
rather than sending it to a machine it was never meant for. `useGenerative` also sets the draft policy: on this Mac with the 4B,
the tier's (`tierDraftPolicy`: on demand on the inbox tier); the 27B and any
remote keep the shipped `needsYou`. The Models page and the wizard then call
`ModelServerSupervisor.ensurePreset()`, which restarts the router only when
the preset's hash changed.

**What travels.** On Your server, message text, attachment text and drafts go
to the owner's own machine over TLS with an api-key from this Mac's keychain;
the decision model's input there is the rendered message state. The heads run
here either way, and so does the embedding model. That is why Your server is
not a third-party target and asks for no consent.

**Keys.** Every routing key is machine configuration and survives `wipeAll`:

| Key | Meaning |
|-----|---------|
| `model_placement` | generative placement |
| `box_big_url`, `box_big_model` | generative remote address and discovered model |
| `generative_managed_model` | `''`, `bond-prose` or `bond-bulk` |
| `decision_placement`, `decision_url`, `decision_model` | decision placement, remote `/v1/embeddings` URL, discovered model |
| `cloud_drafts_url`, `cloud_drafts_model`, `cloud_drafts_consent` | the cloud-drafts target and its consent |
| `prose_parallel`, `router_port`, `models_folder` | managed width, port, folder |
| `box_small_url`, `box_small_model`, `llm_targets`, `stage_targets`, `box_url`, `fast_llm_*`, `prose_llm_*` | INERT; read only by the frozen one-shots below |

The bearers live in the keychain as `llm_target_bearer:<id>` for the three
keyed ids: `box-prose` (generative remote), `box-decide` (decision remote) and
`cloud-drafts`. The Round H small-server id `box-bulk` is read only by the
role-split migration.

## Runtime overrides

Nothing about routing is fixed at build time except the defaults. What a
person changes at runtime is a role's placement and address, and a change
reaches the next request without a restart and without interrupting work in
flight.

- **Late binding.** Every stage's `LlmClient` comes from
  `stageLlmClientProvider(stageId)` (`app/lib/providers/app_providers.dart`)
  with an `LlmTarget Function()` that calls
  `AppPrefsNotifier.targetForStage(stageId)` ONCE at the top of every request,
  so the URL, the model name, the wire and the token come from one setting.
  The resolver reads the NOTIFIER, which subscribes to nothing: a settings
  change rebuilds no client and no worker, and a drain already running
  finishes on the server it started with, request by request
  (`llm_routing_test.dart` pins it). The decision client is built the same
  way (`decisionClientProvider`, resolving `targetForStage('decision')`).
- **A bearer lives in the keychain.** `targetForStage` threads the token in
  from a private cache on `AppPrefsNotifier`, filled once per launch by
  `_loadBearers` (the resolver is synchronous and the keychain is not). The
  specs carry only a presence flag (`boxBigKeyStored`, `decisionKeyStored`,
  `cloudDraftsKeyStored`), false until the prefetch answers, so a first drain
  that beats it sends no half-claimed key. The token reaches the wire as the
  `Authorization` header and nowhere else: never `app_prefs`, never an
  `LlmCallRecord`, never an exception message, never `LlmTarget.toString()`.
  A keychain that refuses costs the header on the next request (a 401 park the
  owner can see), never the launch.
- **Discovery.** `ModelServerProbe` (`model_probe.dart`) turns a completions or
  embeddings URL into its `/v1/models` listing, 5 s timeout, never throws. The
  Models page's Check and the form's Connect use it (with the stored key, via
  `bearerFor`), and the discovered name is what `box_big_model` /
  `decision_model` store. A runtime that routes on the name answers HTTP 400
  for one it lacks, and a 400 is fatal (below), which is why names are
  discovered rather than typed.
- **Embeddings are not switchable.** Stored vectors are tagged
  `Qwen3-Embedding-0.6B/clustering-v3` and `…/document` and are comparable
  only within a tag, so the embedding model never moves.
  `AppPrefs.embedRequestTarget` is what the wire carries: `bond-embed` at the
  router under managed mode, the literal `embed` at `EMBED_URL` (`:8081`)
  otherwise. `EmbeddingsClient` resolves it per request, and its
  `describeUnavailable` says `is not running — see Settings, Models` under
  managed mode and `run: make embed` otherwise.
- **The KV cache.** Every generative stage now shares one server, so each
  stage's byte-identical system prompt is its own prefix on it. A one-slot
  server evicts on every switch between stages; a GPU-served target with room
  for all of them is where Your server is aimed. Moving a role to another
  server costs one cold call per prompt, then back to normal.

Every call records which model answered it: `LlmCallRecord` carries `model`
and `baseUrl`, and the activity log folds the model into the row as
`llm_model`. A streamed call also reports `firstTokenMs`, written into
`detail_json` as `first_token_ms` only when there was one (only the draft
streams). A constrained call whose content is not the JSON object it asked for
is recorded as `format`, never `ok`. The decision client reports ONE record per
decision or batch, labelled `decision`, however many HTTP requests it took;
`embedRaw` reports one labelled `command_head` on Enter and none for the live
preview's keystrokes, which are no unit of work.

**Two wires, one client.** `LlmClient` speaks the OpenAI wire and Bedrock's
Converse (`LlmWire.bedrockConverse`). On Converse a JSON answer is a forced
tool call rather than a `response_format`, `temperature` is not sent, and the
response carries no server timings. The wire and the bearer arrive on the
RESOLVED TARGET in `lib/` (`LlmTarget.wire`, `.bearer`; null means "follow the
client's own") and on the constructor in the benches
(`app/test/fixtures/bench_target.dart`). Only cloud drafts can resolve to
Converse now, since both roles refuse it.

**One streamed call.** `LlmClient.completeJsonStreamed` is the same request
with `"stream": true` and `"stream_options": {"include_usage": true}`, read as
server-sent events. It exists for the draft ([07-replies.md](07-replies.md))
and shares everything but the delivery with the plain path: the same status
mapping, the same timeout over the whole read, the same decode at the end, one
record. Streaming is OpenAI-wire only; on Converse the call degrades to one
plain POST.

## The decision client

`DecisionClient` (`app/lib/services/decision/decision_client.dart`) renders a
message's state (`decision_state.dart`, a byte-exact port of the training
renderer) and has the decision server answer over it. The server is one of
two KINDS (`DecisionServerKind`), and every caller uses the same API
(`decide`, `decideBatch`, `decideStates`, `ask`, `askPairs`) whichever it is:

- **encoder-heads** (`encoderHeads`): a stock llama-server serving the
  ModernBERT encoder as a mean-pooled embedding model — the managed router's
  `bond-decide`, `make decide` on `:8083`, or a box's `/decide/` slot. The
  client embeds the state and applies this Mac's heads
  (`decision_heads.dart`). Everything from **The identity probe** to **The
  heads file** below is this kind.
- **systemone** (`systemOne`): Kev 4B behind jev-prototype's wrapper
  (`distill/serve_bond_kev.py`, contract §3.4 of
  `PLAN-storyline-questions-training.md`) on the owner's server. It is asked
  the questions' plain text and answers calibrated probabilities, so nothing
  is applied in Dart and no file on this Mac is read.

**How the kind is found.** A managed or hand-started target is always
encoder-heads, with no extra request (the provider's `isYourServer` answers
yes only for the decision spec's `box-decide` target at that address). A
target on Your server is asked `GET <base>/v1/models` once, with the same
key, where `<base>` is the configured URL up to its last `/v1/` segment
(`systemOneUrlFor`, beside `tokenizeUrlFor`). A listed model carrying a
`qhash` is a systemone server, and it is refused as `decision_misconfigured`
unless the `qhash` is `decisionQhash` (`f495a7dc48aa34d5`) and the `renderer`
is `bond-state/2`, each with a sentence naming the cause. Everything else is
encoder-heads, and the identity probe then runs as before (and parks as
before when `/tokenize` is missing too): a listing with no `qhash` entry, an
empty `models: []` included, and any answer that is not a listing at all — a
4xx other than 401/403/429, or a 200 that is not a JSON object. Only the
server's condition keeps its mapping: transport, 5xx and 429 park as
unavailable and 401/403 as the key. The kind is cached per client under the
same normalised `baseUrl|model` key as the probe's pass, only on a success,
and both are dropped whenever the server stops answering, refuses the key or
answers as the wrong thing (`decision_misconfigured`, which is a kind of
unavailable), so a restart or a re-pointed route that puts Kev where
ModernBERT was, or a Kev still warming up, is asked afresh on the next call.
**Connect** (`checkServer`) asks the kind first and the identity probe only
for encoder-heads. When Settings opens with the decision role on Your server
and the kind is not known yet, the host asks `detectKind` (one listing GET
that fills the same cache) and redraws when it answers; `kindOf` answers the
Models page's kind line from the cache. The unavailable sentences for Your
server (either kind) name no `make decide`, which starts a server on this Mac;
only the managed and hand-started targets keep that advice.

**The systemone wire.** `POST <base>/v1/systemone` with `{"state": <rendered
state>, "questions": {<id>: {"type": "choice", "instructions": <plain text>,
"criteria": {<option>: null, …}}}}`: the texts are
`systemOneMessageQuestions` and `StorylineQuestion.instructions`
(`decision_questions.dart`), copied from the v5 handoff file and pinned by
`decision_questions_test` against
`test/fixtures/decision/systemone_questions_v5.json`, the criteria null in
canonical option order. The FULL rendered state is sent, uncut: the wrapper
owns Kev's context limit, and a state it refuses (a 413 or 422) is that one
message's `LlmFormatException`. A message state carries all nine
message questions in one request; a storyline state (pair, membership or
charter) carries its one question, and `askPairs` asks both orders and
averages as for the encoder. The answer is `{"answers": {<id>: {"type",
"choice", "confidence", "probabilities": {<option>: p}}}}`; the probabilities
are already calibrated, and the choice is re-derived here as their argmax in
option order (`DecisionAnswers.fromProbabilities`). An answer missing an asked
id, with option keys other than the question's, a value outside [0, 1] or a
set that does not sum to 1 within 1e-3 is a `DecisionMisconfiguredException`
(`decision_misconfigured`): a wrapper that answers one state that way answers
them all that way, so the role parks. So does a 404/405 on `/v1/systemone`.
Requests run at most 8 at once per call (`systemOneInFlight`), 15 s each, and one call is still
one `onCall` record (`decision`, `decision:<id>`). A result's `model` is the
name the wrapper listed; `truncated` is always false.

- **The identity probe.** Before the first embedding a target gets, the
  client `POST`s `<prefix>/tokenize {"model", "content": "a", "add_special":
  true}` with the same key, and anything but a non-empty list starting with
  `[CLS]` 50281 and ending with `[SEP]` 50282 is a server of the wrong kind
  (`The server at <origin> is not the decision model: its tokenizer is not
  ModernBERT's.`). The vector checks below cannot tell: the embedding model
  also answers 1024 raw numbers, and llama-server echoes the request's
  `model` back. A 404 or 405 from `/tokenize`, here or on the token path, is
  the same park (`… does not offer /tokenize, which the decision model
  needs`). Only a pass is cached, per client and per `baseUrl|model`, so a
  failed probe is asked again on the next call; `decide`, `decideBatch` and
  `decideStates` probe once each. A decision **Connect** in Settings or the
  wizard asks the same probe (`DecisionClient.checkServer`, through
  `refuseWrongDecisionServer`) before it writes, and draws the sentence under
  the form instead of connecting; the form also takes the decision model's
  own name from a router's `/v1/models` (`bond-decide`, the box's served
  name, this build's, or the stored one) before the first id.
- **The heads pairing.** After the probe, once per target and heads model,
  the name of the GGUF the server serves must CONTAIN the heads file's
  `model` (`bond-decide-mbl-v3` in `bond-decide-mbl-v3-f16.gguf`); the probe
  cannot see this, since every ModernBERT tokenizes alike. For the managed
  router the file is the manifest's decide entry (the provider's
  `servedFile` hook: the router lists only preset ids); for Your server it
  is read off the `/v1/models` listing the kind check already fetched; for a
  hand-started server it is one `GET <base>/v1/models`. llama-server lists
  its model path under `model`/`id`/`name` unless an alias replaced it, and
  only a name ending `.gguf` counts (reduced to its last path segment). A
  listing that names none, or no listing, SKIPS the check and is kept like a
  pass; a mismatch is `DecisionModelMismatchException` (a
  `DecisionMisconfiguredException`, park `decision_misconfigured`): "The
  decision model file (<file>) does not match its heads file (<model>).
  Install them together." It is forgotten with the probe's pass.
- **The request.** `POST <url> {"model", "input", "embd_normalize": -1}` with
  `Authorization: Bearer` when the target has a key. `input` is a string for
  one state, an array for a batch, or a flat int array for a token path. A
  404 or 405 here is the server, not the message (`… does not offer
  /v1/embeddings, which the decision model needs`): it parks
  `decision_misconfigured` and drops the probe's and the kind's cache, as
  `/tokenize` and `/v1/systemone` do.
- **Raw vectors.** llama-server L2-normalises by default, and the heads were
  trained on the RAW pooled vector (a linear layer with a bias is not
  scale-invariant), so every request sends `embd_normalize: -1`. A vector
  whose norm is within 1e-3 of 1.0 is refused as a format error: the belt
  against a server that ignored the field. A vector whose length is not the
  heads' `hidden` (1024) is refused the same way.
- **Truncation.** llama-server refuses an input longer than its context (HTTP
  500, `input (N tokens) is too large to process`) rather than cutting it, and
  the model was trained on states truncated at 2048 tokens. That 500 is a
  SIGNAL, not a failure: the client then `POST`s `<prefix>/tokenize
  {"content", "add_special": false, "model"}` (the `model` field is required
  by the router, which routes `/tokenize` on it), keeps the first
  `maxTokens - 2` = 2046 ids and sends `[CLS] 50281 + ids + [SEP] 50282` as an
  int array, which gives the vector HF truncation gave. A state longer than
  6000 UTF-16 code units skips the text request and goes straight to the token
  path. `tokenizeUrlFor` keeps any path prefix, so a box tokenizes under
  `/decide/tokenize`. The refused text call is never retried as text, never
  parks and never counts as an attempt.
- **Batches.** `decideBatch` sends the short states in array requests of up to
  16 (`batchChunk`); a chunk the server refuses as too large is re-sent one
  state at a time so only the long one pays for the token path.
- **Timeout.** 15 s per HTTP request, not per decision, so the token path can
  take up to three requests.
- **The heads file.** `decide-heads.json` in
  `<models folder>/local_bond-decide/`, installed by `make decide-install`
  beside the GGUF. `decisionHeadsProvider` loads it through
  `DecisionHeadsFile`, cached and re-read when its mtime changes. **It is
  needed even when an encoder-heads server is remote**, because the heads
  run here; a systemone server never reads it. Missing, it throws
  `DecisionNotInstalledException` with "The decision model is not installed.
  Run: make decide-install" (never cached, so an install is seen at the next
  claim). On Your server the kind is asked BEFORE the heads are read, so a
  heads-less Mac whose ModernBERT server is down parks
  `decision_unavailable` (the listing failed) rather than
  `decision_not_installed`; the heads-file park follows once the server
  answers. A file this build refuses (not
  JSON, another schema, question set or renderer set) throws
  `DecisionMisconfiguredException`. A schema-1 file (the first decision
  model) throws its subclass `DecisionOlderModelException`, which parks
  under its own `decision_older_model` with `DecisionHeads.olderModelText`
  (`decisionOlderModelText` in `llm_client.dart`): "The installed decision
  model is an older version that this app no longer reads. Install the
  current decision model to resume sorting new mail." Plain words and no
  command, because the owner reading it may not be a developer. That
  failure IS cached on the file's
  mtime, so a bad file is parsed once rather than once per claim. Settings'
  **Check** does not drop the cache: rebuilding it would rebuild the decision
  client and the triage queue under it mid-drain.

What goes wrong, and what the owner sees:

| Failure | Exception | Park reason | Rail |
|---------|-----------|-------------|------|
| Connection refused, TLS failure, timeout, 5xx, 429 | `DecisionUnavailableException` | `decision_unavailable` | `Decision model unreachable · N waiting · retrying each minute` |
| Heads file refused (not JSON, schema, question set); a systemone server lists another `qhash` or renderer, answers `/v1/systemone` with 404/405, or answers outside the contract; the identity probe finds another tokenizer, or `/tokenize` or the encoder's `/v1/embeddings` answers 404 or 405; the served GGUF's name does not contain the heads file's `model` (`DecisionModelMismatchException`: "The decision model file (<file>) does not match its heads file (<model>). Install them together."); the server answers a normalised or wrong-width vector, the wrong vector count or index, no token list, non-JSON, or refuses even the truncated ids; the address is not an embeddings URL | `DecisionMisconfiguredException` (a `DecisionUnavailableException`; its sentence names the cause and carries no key) | `decision_misconfigured` | `The decision server is not the decision model, or its heads file does not match · N waiting · check its address in Settings, or run make decide-install` |
| Heads file is the older model's (schema 1) | `DecisionOlderModelException` (a `DecisionMisconfiguredException`) | `decision_older_model` | `The installed decision model is an older version that this app no longer reads · N waiting · install the current decision model to resume sorting new mail` |
| Heads file missing, or the managed decision model the router does not serve (`LlmTarget.unavailable`), refused before any request | `DecisionNotInstalledException` (a `DecisionUnavailableException`) | `decision_not_installed` | `The decision model is not installed · N waiting · run make decide-install, then Check in Settings` |
| 401 / 403, or a key no header can carry (refused before sending) | `DecisionUnauthorizedException` (an `LlmUnauthorizedException`) | `decision_unauthorized` | `The decision server refused the access key · N waiting` |
| Any other 4xx (a systemone 413/422 included) | `LlmFormatException` | none: counted against the item | none |

Every fault that would fail every message alike parks: counting it per
message would error the backlog and let each row flow on to its text with no
decision. The one per-message fault is a 4xx the server gives this request.
The activity log's words for the reasons are in `activity_log_panel.dart`
(`decision model unreachable`, `decision model not installed`, `decision
model is an older version`, `decision server misconfigured`, `the decision
server refused the access key`), and the
Models page
carries the same park as one status line (`docs/settings.md`). The
unreachable sentences name `make decide`, the hand-server fix; the URL in any
of them is taken out by `redactEndpoints` wherever it is written.

## The one-shot migrations

`AppPrefsNotifier.read` runs four one-shots, in this order and no other. All
are plain prefs, deliberately NOT in `MessageStore.derivedOneShotPrefs` (that
list is what a wipe re-runs, and none of these guards a corpus).

1. `box_targets_derived` lifts a Round G install's two `llm_targets` box rows
   into the `box_url` origin.
2. `box_servers_derived` splits `box_url` into `box_big_url` and
   `box_small_url`.
3. `stage_targets_cleared` empties the per-stage picks.
4. `model_roles_derived` splits Round H's big/small pair into the roles.

**`model_roles_derived`.** The keys were REUSED (`model_placement`,
`box_big_url`, `box_big_model` and the `box-prose` keychain entry already mean
the generative remote), so it is a no-op for every install but one shape: a
THIRD-PARTY `box_big_url` (a vendor host or the Converse wire), which Round H
used as its cloud-drafts mechanism and which the generative role may no longer
use. `planModelRoles` decides, as a pure function:

- **Adoption.** The vendor address becomes the cloud-drafts target
  (`cloud_drafts_url`/`_model`) ONLY when the owner was actually using and had
  agreed to it: the effective generative placement was `box`, consent stood,
  and a model name had been discovered. Anything else is an address the owner
  walked away from, and it is dropped with its key.
- **The generative role then** goes to the owner's own stored small server
  (its URL and model into `box_big_*`, except that a box's `/bulk` slot, the
  4B, becomes its `/prose` sibling with `box_big_model` emptied so the build's
  name is asked for); else follows the build when the small server did
  (`box_big_*` emptied, placement kept); else comes home
  (`model_placement = local`).
- **The keychain moves**, in order: the `box-prose` key moves to
  `cloud-drafts` (adopted) or is deleted (dropped); then, unless the role came
  home, the `box-bulk` key moves to `box-prose`.

The flag has three values: absent (not run), `1` (done), or
`pending:<moves>`. The pending value is written BEFORE the preference moves,
so a crash between them re-runs only the keychain half. `finishModelRoles`
runs the moves, advancing the flag past each only after a read-back confirms
it; it never throws and never logs. `main()`'s preload has no token store, so
there the flag is left pending and the notifier finishes the moves before it
loads the bearers. While any move is owed, the notifier attaches NO `box-prose`
token (it might still be the vendor's): a 401 park the owner can fix rather
than a vendor key sent to their own server. A key typed for the generative
remote over a pending flag settles it, but only after a read-back shows the
keychain really holds the typed key.

## Managed mode: one router

With `managedServer` true (every build but a `BOND_DEV_HAND_SERVERS` one) the
app starts ONE llama-server in router mode serving every model this Mac's
roles want.

- **The supervisor.** `ModelServerSupervisor`
  (`app/lib/services/server/model_server_supervisor.dart`), behind
  `modelServerSupervisorProvider`. It writes a preset, spawns the binary
  `LlamaBinary.resolve()` found, watches for the listening line, polls
  `/models` and `/health` until every model the preset declares is resident,
  and reports a `ServerState`. `ServerBootstrap` calls `ensureRunning()` once
  at launch.
- **The preset follows the placements at runtime.** Its `buildPreset` reads
  `managedManifestProvider` (below), tells the prefs the machine tier, and
  serves only the entries whose files are on disk (`withPresentFiles`).
  `ensurePreset()` is what the placement writers' callers use: it starts a server that is down, leaves one whose preset hash
  still matches alone, and restarts anything else. So moving the generative
  role to Your server drops the chat model out of memory, and running
  `make decide-install` while the app runs is picked up by the next
  `ensurePreset` (a new hash) rather than by a relaunch.
- **Four ids, one origin.** `bond-embed`, `bond-decide`, `bond-bulk` (the 4B),
  `bond-prose` (the 27B), named for the role and not the checkpoint, because
  the router routes on the model name alone: swapping which GGUF fills a role
  is a preset change and nothing else. The generative role asks for
  `bond-prose` or `bond-bulk` at `<router>/v1/chat/completions`; the decision
  role for `bond-decide` at `<router>/v1/embeddings` (and `/tokenize`, with
  the same `model`).
- **The restart budget is per failing launch.** A crash is retried on a
  1 / 4 / 16 s backoff and then reported `failed` with the log tail; reaching
  ready resets the count. A `couldn't bind` is retried once on a fresh port
  and is otherwise `ServerPortInUse`.
- **`LLAMA_CACHE`** points at an empty directory (`servers/empty-cache`), so
  the router's listing is exactly the preset and a developer's Hugging Face
  cache cannot keep the readiness check waiting.
- **The pid file and the quit hooks.** `servers/router.json` holds the pid, the
  port, the preset hash and the binary path. `ServerBootstrap`'s
  `onExitRequested` stops the server with a 4 s grace; the Runner's
  `applicationWillTerminate` reaper is the second line, and it compares the
  recorded binary path against the process's own executable so a pid reused by
  a hand-started server is never signalled.
- **Adoption takes four agreements**: the pid is alive, the recorded preset
  hash is this build's, the recorded binary is the one this build would spawn
  (symlinks resolved), and the recorded port is `router_port`. Anything else
  falls through to reap-then-start, which kills only a process whose command
  line carries both `llama-server` and this app's preset file.
- **On unless the BUILD says otherwise.** `managedServerDefault` is
  `!handServersBuild`; `BOND_DEV_HAND_SERVERS` is read as a value (`0`,
  `false`, `no` mean off). With it the roles resolve to the hand-started
  servers: `make model` (`:8080`), `make decide` (`:8083`), `make embed`
  (`:8081`). A busy `router_port` is not a question for the user: the
  supervisor takes a free port and `onPortMoved` records it before the child
  is spawned.

### The manifest

`app/assets/models/manifest.json` (`version: 2`) is the ONLY place the
checkpoints are named, and `RouterPreset` knows how to write an INI and nothing
about which models belong in one. One entry per model, in file order, which is
the INI's section order and the router's load order: smallest first, so the
embedding model is resident while the 27B is still mapping.

| Field | What it is |
|-------|------------|
| `id` | The router id: `bond-embed`, `bond-decide`, `bond-bulk`, `bond-prose`. |
| `role` | `embed`, `decide`, `bulk` or `prose` (`ModelRole`). One model per role; the generative ROLE can be filled by either `bulk` or `prose`. |
| `source` | Absent for a Hugging Face download; `local` for a model installed by hand (the decision model). A local entry has no `revision`, is never downloaded, and is served only once its files are present. |
| `repo`, `file` | The Hugging Face repo and file (`local/bond-decide` for the local entry). On disk: `<repo with '/' → '_'>/<file>`. |
| `revision` | A 40-character commit sha, never `main`, for every downloaded entry. |
| `sizeBytes`, `sha256` | Measured size and LFS oid, checked against the hub's headers on the redirect. For the local entry, the installed file's. |
| `heads` | The decide entry only: `file`, `sha256`, `sizeBytes` of `decide-heads.json`. `RouterPreset` ignores it; it is what the app reads. |
| `minRamBytes` | What the machine must have; informational (the tier decides). |
| `license`, `licenseUrl`, `notice` | What the first-run screen shows. |
| `sidecar` | Optional second file an entry cannot be served without: the 27B's MTP head. |
| `serverArgs` | llama-server long flags without dashes, as the INI wants them. |
| `tiers` | The memory ladder: `id`, `minRamBytes`, `models`, optional per-id `serverArgs` overrides. |

**The tiers.** Two rungs from `hw.memsize`, stored nowhere
(`machineTierFor`; unknown memory is `full`, the never-refuse rule):

| tier | starts at | models it can hold |
|---|---|---|
| `full` | 40 GiB | embeddings, decision, the 4B, the 27B |
| `inbox` | 0 | embeddings, decision, the 4B (at `c = 16384` over `parallel = 2`) |

The tier constrains the MANAGED generative choice (the 27B only on `full`); it
no longer says where anything runs. There is no `remote` tier: Round H's
"everything on the box" tier is now simply "neither role is managed".

**What this Mac serves** is `ModelManifest.forRoles(hardwareTier,
decisionManaged, generativeManagedId)`: the tier's view, keeping the embedding
model always, the decision model when the decision spec is local, and the one
managed generative model when the generative spec is local. It is
`managedManifestProvider` in `app_providers.dart`, watched through `select`s on
exactly those facts. Its `.downloadable` view (every entry but `source:
local`) is what the wizard downloads and what `SetupGate` checks the ledger
against, so a full-tier Mac on Managed downloads the embedding model and the
27B, and the 4B only if chosen. The supervisor serves
`forRoles(…).withPresentFiles(folder)`: any entry whose files (weights,
sidecar, heads, whichever it has) are not all in the folder is left out of the
preset, except the embedding model, which every stage needs and whose absence
should fail the start with the preflight's own sentence. The server refuses to
start with a file the preset names missing, and one missing model must not
take the others down with it: a decision model not yet installed by
`make decide-install`, or a chosen generative model not yet downloaded, leaves
the preset and that role parks on its own reason while the rest run. The park
is the CLIENT's, not the router's: `buildPreset` tells the prefs which managed
ids it served (`setServedManagedIds`), and a managed target whose model is not
among them resolves with an `LlmTarget.unavailable` sentence ("The Qwen3 4B is
not downloaded on this Mac. Set up again to download it.", "The decision model
is not installed. Run: make decide-install"), so `LlmClient` and
`DecisionClient` throw their unavailable exception before any HTTP call. Asking
the router for a model it does not serve would answer 400, and a 400 is fatal
in both drains, so every message would end in error instead of waiting. The
next `ensurePreset` after the file lands sees a new hash and restarts.

The flags that are not preferences, recorded here because JSON has no
comments:

- **`bond-decide`: `embedding`, `pooling = mean`, `c = ub = b = 2048`,
  `parallel = 1`.** The measured parity command (`make decide` runs the same
  set). The micro-batch must hold a whole 2048-token state, because
  llama-server refuses rather than truncates, and the client's truncation cuts
  to exactly that. `app/test/manifest_makefile_parity_test.dart` keeps it and
  the Makefile's `DECIDE_*` in step.
- **`bond-embed`: `pooling = last`.** The one flag llama.cpp does not read off
  this model's GGUF; `mean` would answer plausible vectors in a different
  space from the stored ones (see [05-embeddings.md](05-embeddings.md)).
- **`bond-bulk`: `parallel = 4`**, `c = 16384` (4K a slot); on the inbox tier
  `parallel = 2`, so its KV cache stays under 3 GB on a 16 GB Mac.
- **`bond-prose`: `parallel = 1`, `c = 16384`**, the memory ceiling on this
  machine.
- **`spec-type = draft-mtp` and its sidecar.** The 27B's entry carries the MTP
  head as a `sidecar` (`mtp-Qwen3.8-27B-Q4_0.gguf`, 1.6 GB, same commit) and
  `RouterPreset.toIni` writes it as `model-draft = <path>` straight after
  `model`, unquoted. The two travel together: `draft-mtp` with no head to load
  is a server that does not start. **`model-draft` as a per-model INI key is
  the expected spelling of `--model-draft` and is UNVERIFIED** against a
  running router; a wrong key fails loudly at startup. Nested rather than a
  fourth entry because each entry is a role, and the head is one more file on
  a role that already has one.

### The downloader

`ModelDownloader` (`app/lib/services/models/model_downloader.dart`) fills the
models folder with the `.downloadable` set.

- **One stream at a time, smallest first**; the wizard's Continue and the
  server both wait for every file the set names.
- **A failure moves on**: one file's failure is an event, the run continues.
- **`.part` beside the destination, HTTP Range resume**, the part's own length
  being the offset; a 200 to a ranged request truncates the part.
- **Re-resolve on expiry**: a 403 mid-transfer is an aged-out CDN signature,
  and the hub is asked again at once. No URL is ever stored.
- **sha256 on the platform side** (`SystemInfo.sha256`, CryptoKit); one
  mismatch is retried from zero, a second is the wrong file.
- **The ledger** is `setup_state['download']`: status, bytes and the manifest
  sha each part belongs to; no URL, no host.
- **A disk preflight with 10 GiB of headroom**; free space that cannot be
  asked is not a refusal.
- **The failure words**: `disk_full`, `checksum`, `network`, `gated`,
  `manifest_mismatch`, `missing_folder`, `http_<code>`.

The decision model is not downloaded this round: `make decide-install` copies
the GGUF and the heads file from the training export, sha256-pinned, into
`local_bond-decide/`. Distributing it is an open packaging question. It copies the v3
export (schema 2, sha256-pinned in the manifest); an older schema-1 install
is refused (`olderModelText`, park `decision_older_model`;
[03-triage.md](03-triage.md)).

### First run

Three gates, outermost first: `ServerBootstrap` → `SetupGate` → `AuthGate`
(`app/lib/main.dart`). `setup_state['setup']` holds a `SetupStep.name`, and
`'done'` is the only value that lets the app through; an unknown word or a
failed read is `welcome`. The steps, the Where step's role cards and their
strings are in `docs/settings.md` (**First run**). Finish writes what the
Where step chose through the role writers above, then records `'done'`, and
only a finish that saved asks for the server, fire-and-forget: `restart()`
when the folder moved or weights landed during the run, `ensurePreset()`
otherwise. `BOND_DEV_SKIP_SETUP=1` skips the wizard. "Set up again" (Settings
→ Models) clears `setup_state` except the migration record and the download
ledger.

## Failure policy: park, never fall back

- **No fallback between servers.** A down server throws
  `LlmUnavailableException` (or a subclass); `AiWorker` parks only that kind
  of work, and the triage drain (whose one model is the decision model)
  parks whole. Work resumes when the server
  comes back. There is no LLM fallback for the decision model and no second
  server for the generative one.
- **Status mapping** (`LlmClient`, and the decision client's own):
  connection failure, 5xx and 429 → unavailable, park; 401 and 403 →
  `LlmUnauthorizedException`, park; timeout → counted against the item on the
  chat client, park on the decision client; HTTP 400 → fatal, never retried,
  which is what a model name the server lacks looks like.
- **A refused key parks rather than spending the backlog.** A wrong key
  answers every item identically, so counting it per item would burn the
  queue's attempts in seconds. `LlmUnauthorizedException` is a subclass of
  `LlmUnavailableException`, so every existing `on LlmUnavailableException`
  arm catches it; the subclass buys the reason. Its sentence ("The model
  server at <url> refused the access key. Check it in Settings, Models.") has
  its URL removed by `redactEndpoints` wherever it is written.
- **Which server died is in the type.** `EmbedUnavailableException` and
  `DecisionUnavailableException` are subclasses too, because the three
  servers are placed apart and "model server unreachable" would send a person
  to a server that is answering fine. `parkReasonFor` maps the closed set to
  one word each, subclasses first. `ModelNotInstalledException` (thrown by
  `LlmClient` for a managed generative target carrying
  `LlmTarget.unavailable`) is `not_installed`; the decision client's own
  `DecisionNotInstalledException` is `decision_not_installed`, because its fix
  is a command rather than a download; `DecisionOlderModelException` (the
  heads schema-1 refusal) is `decision_older_model`, ahead of its parent,
  because its fix is an install rather than an address;
  `DecisionMisconfiguredException` is
  `decision_misconfigured`, because waiting fixes neither of its causes (the
  address or the heads file), so its sentence claims no retry;
  `DecisionUnauthorizedException` is
  `decision_unauthorized`, named for the decision server rather than worded by
  the generative placement. A failed TLS handshake (`TlsException`, e.g. an
  expired certificate) parks on both clients like a refused connection, at
  the handshake or mid-stream.
- **A key no header can carry is refused, never sent.** The writers
  (`useGenerative`/`useDecision`/`useCloudDrafts`) throw an `ArgumentError`
  and the form says so under the field for a key outside printable ASCII
  (`isUsableAccessKey`); a stored one that slips through is refused by both
  clients before the request (and a `FormatException`/`ArgumentError` raised
  while sending maps the same way) as an unauthorized park whose sentence
  never includes the key. Error-body snippets blank the key in both clients.
- **Parking is VISIBLE, and nothing polls for it.** Both drains carry the
  reason on their progress streams (`TriageProgress.parkedReason`,
  `WorkProgress.parkedReason`, merged by `parkedProvider`); triage keeps one
  slot and the worker lanes one per kind, so an empty emit from one lane
  cannot erase another's park. The inbox rail renders one sentence
  (`railProgressLine`):

  | reason | generative placement | sentence |
  |---|---|---|
  | `model_unavailable` | Your server | `Your server is not answering · N waiting · retrying each minute` |
  | `model_unavailable` | this Mac | `Model server unreachable · N waiting · retrying each minute` |
  | `unauthorized` | Your server | `Your server refused the access key · N waiting` |
  | `unauthorized` | this Mac | `Model server refused the access key · N waiting` |
  | `embed_unavailable` | either | `Embedding server unreachable · N waiting · retrying each minute` |
  | `decision_unavailable` | either | `Decision model unreachable · N waiting · retrying each minute` |
  | `not_installed` | either | `A model this Mac runs is not downloaded · N waiting · set up again in Settings` |
  | `decision_not_installed` | either | `The decision model is not installed · N waiting · run make decide-install, then Check in Settings` |
  | `decision_older_model` | either | `The installed decision model is an older version that this app no longer reads · N waiting · install the current decision model to resume sorting new mail` |
  | `decision_misconfigured` | either | `The decision server is not the decision model, or its heads file does not match · N waiting · check its address in Settings, or run make decide-install` |
  | `decision_unauthorized` | either | `The decision server refused the access key · N waiting` |
  | `session` | either | `Triaging N remaining…` |

  Processing being off wins over all of them. The Models page carries the
  same fact as its status line (`docs/settings.md`). **What clears it is the
  next pump**: the reason is dropped at the top of `pump()` and on the first
  item that gets through. Pumps come from the inbox's sixty-second poll and
  from `ModelServerSupervisor.onReady`, the only cadence the sentence claims.
  A refused key claims no retry, nor does a misconfigured decision server,
  though the next pump still asks again, so a fixed address recovers without
  a Check. `N` is the whole pipeline's backlog.

## Three drains

Three `AiWorker` instances and three gates, so a person's draft never waits
behind a recap and a new message never waits behind either:

| Lane | Kinds, in drain order | Server(s) | Gate | Provider |
|---|---|---|---|---|
| Fast | `needs_you`, `extract`, `embed_message`, `attachment_text`, `attachment_digest`, `context_reconcile`, `context_digest`, `context_brief` | decision (`needs_you` re-decides), generative + embeddings | `fastDrainGateProvider`, shared with `TriageQueue` | `aiWorkerProvider` |
| Storyline | `storyline`, `storyline_sweep`, `storyline_refresh`, `storyline_audit`, `storyline_recruit`, `storyline_recap` | generative + decision (`member_of`, `charter_specific`; a decision failure parks the lane) | `storylineDrainGateProvider` | `storylineWorkerProvider` |
| Draft | `draft`, `meeting_brief` | generative, or cloud drafts (`draft` only) | `draftDrainGateProvider` | `draftWorkerProvider` |

The lanes were cut when the fast lane had a 4B of its own. With one generative
server they are still the right cut for ORDER (the storyline six mutate shared
membership in an order that is an argument, see
[06-storylines.md](06-storylines.md); the draft is the one kind a person
waits for), but they now contend at one server, which queues them. The
meeting brief rides the draft lane AFTER `draft`: it is the other piece of
prose a person reads rather than a stage another stage reads, so behind the
storyline passes it would wait on a sweep, and ahead of the draft it would
hold up a reply somebody is waiting on for a meeting hours away. It runs one
at a time, whatever the draft width. Order alone is not enough once the walk
is inside a backlog of briefs, so a person's Draft reply is also named as a
priority ref (`pump(first:)`), served at the next claim boundary — after at
most the one brief already at the model. On a
managed full-tier Mac that server is the 27B with one slot, so today every
lane's calls take turns there; that is the cost the decision pass (Phase 5)
began to remove and the one-call-per-message task (Phase 6) finishes.

**Triage still holds the fast gate (Phase 6).** Triage no longer calls the
generative server, but it shares `fastDrainGateProvider` with the fast worker
for ORDERING — the yield ticket and `onDrained` below — so a triage pump can
wait behind a message-text call already in flight. A separate triage gate is
a follow-up round candidate.

**The newest message goes first.** A triage pump that finds work asks the fast
gate for a yield. The fast worker reads the flag only where it is about to
claim its next item, so the item at the server is never abandoned; triage
runs, and the messages it just decided on ride `onDrained` into a PRIORITY
pass that claims each through every fast handler before the walk resumes.
The ask is a ticket, cleared by the drain queued at or after it, so neither
side can starve the other; at most eight messages ride one pass. Measured on
Round G's two-slot routing (2026-09-21, `make bench-pipeline`), a message
arriving mid-backlog was extracted 7.2 s after it landed on the box, against
32 s before; the lanes' behaviour is unchanged, the servers behind them are
not, and the number has not been re-taken on one generative model.

**…and one switch.** Model work runs only while **AI processing** is on
(`processingProvider`, remembered in `processing_on`, default on). It reaches
each drain as one `enabled` closure read on every launch decision; an off
`pump()` returns at once but still EMITS the waiting count for the rail's
`Processing is off · N waiting`. Off stops the queue and the three lanes; on
runs `pumpTriageThenWorkersQuietly` once. Sync, read-acks, the Models page's
Check and Connect, and the Find field's query embedding keep running. The
composer's **Draft reply** is disabled with `Processing is off`.

**Order across lanes is enqueue-and-pump.** A fast handler writes the
`storyline*` or `draft` row and wakes the owning lane: `AiWorker.onDrained`
after every drain (fast wakes the other two; storyline wakes draft), and
`ExtractHandler.onDraftQueued` and `onStorylineQueued` per row — the second
pumps the storyline lane as each thread's assign is queued, so assigns run
while the extraction backlog is still walking rather than after it. The fast
lane re-arms the storyline sweep through `MessageStore.requeueSweep()` only
after a drain that did work.
`AiWorkers.pumpAll()` is fast, then the other two together.

**How wide the draft lane runs is a property of the draft TARGET.**
`DraftHandler.concurrency` reads `AppPrefs.specForStage('draft_reply')
?.parallel` on every launch decision: `prose_parallel` on this Mac, 4 on Your
server following the build, 1 on a stored address or cloud drafts. A second
closure, `streams`, lets a target that cannot stream (Converse) make the plain
call. Recaps and refreshes stay at one because each writes the storyline it is
about. The fast lane's message text runs at the target's `textParallel`
the same way (`ExtractHandler(textParallel:)` and
`AttachmentDigestHandler(textParallel:)`, each a closure over
`specForStage('message_text')` read on every claim).

**Two writers ride the storyline gate**: `GateRepairService.afterGate`'s three
storyline writes (evict, clear the conversation embedding, delete the pending
`storyline` row) and `ContextBriefHandler.onBriefChanged`'s charter offer, both
unawaited, so the fast lane never waits on a sweep. The one-shot
`GateRepairService.repairAll` stays inline.

## Every prompt is fenced

Every task's system prompt is `rules + untrustedDataClause`
(`app/lib/services/llm/prompt_guard.dart`), and all sender-supplied text is
wrapped by `wrapUntrusted` with `&`-first escaping so a message body cannot
forge a closing tag. A new task must compose its prompt the same way — no raw
interpolation of message content into a prompt, ever. The decision model's
input is not a prompt: it is the rendered state the classifier was trained on
(`decision_state.dart`), and it carries no instructions to fence.

## Task plumbing

Every chat task implements `JsonTask` (`app/lib/services/llm/json_task.dart`):
a schema-constrained call, temperature 0.2 / maxTokens 512 by default,
overridden per call site. Decoding is grammar-constrained; `make bench-verify`
asserts a server honours the schema before any bench trusts it.
`runTask(onText:)` picks the streamed method, and `DraftHandler` is its only
caller in `lib/`.

**Timeouts.** Every generative stage's client gets `LlmClient.proseTimeout`,
90 s, since the decision-model round: one generative model does the short
calls and the drafts alike, and on the 27B a short call behind a draft in the
same slot can wait that long. The number is sized to the longest legitimate
draft: about 14K characters of prompt at every input's cap (26 s of prefill
plus 43 s for 768 tokens with speculative decoding, 69 s), or about 20K when a
section is expanded (roughly 80 s), with ten seconds of headroom. The generic
120 s (`_defaultTimeout`) is what a client built without one gets, including
every bench client (`app/test/fixtures/bench_target.dart`), so a candidate
runtime slower than the app's ceiling shows as a p50 above 90 s rather than as
a failed run. The decision client's is 15 s per HTTP request.
