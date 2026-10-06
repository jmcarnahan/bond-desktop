# app/ — executor gotchas (loaded when work touches app/)

Stable rules learned across rounds. A round's plan links here and lists only
its own gotchas; nothing below is copied into plans. Hooks in `.claude/hooks/`
enforce the ones that are commands.

## Schema changes (Drift, STRICT tables, schema version in `lib/data/database.dart`)

1. New columns go AFTER the existing ones in `lib/data/schema.drift` (ALTER
   TABLE append order); indexes as `customStatement('CREATE INDEX IF NOT
   EXISTS …')`, never `m.createIndex`; never a vec0 or FTS virtual table in a
   migration or `beforeOpen` (drift's `SchemaVerifier` diffs all of
   `sqlite_master`) — create them lazily at first use, the
   `MessageVectorIndex.ensureReady` pattern.
2. Bump `schemaVersion`; add a guarded `fromXToY` step (`_columnExists`
   pattern); never widen a frozen step. Quote a column named `"key"` in the
   DDL: drift silently DROPS an unquoted `key` column from the schema it
   generates (`app_prefs` and `setup_state` both carry the quotes).
3. From the repo root: `make app-migrations` (BOTH drift_dev commands — the
   second restores the no-data-class snapshots; the raw
   `drift_dev make-migrations` leaves ~30k lines that do not compile), then
   `make app-gen`.
4. Commit the generated output with the change: `drift_schemas/bond/
   drift_schema_vN.json`, `test/drift/bond/generated/schema_vN.dart`,
   `lib/data/database.g.dart`, `lib/data/database.steps.dart`.
   `test/drift/bond/migration_test.dart` covers every version pair.
5. `make app-migrations` refuses when the current version's JSON already
   exists and differs, or when any JSON has a higher version than
   `schemaVersion`. Bump the version and add the step FIRST, with no JSON for
   the new version present, then run it.
6. Drift's `migrateAndValidate` flags a leftover COLUMN but not a leftover
   TABLE (`validateDropped` defaults false). A migration test that drops a
   table asserts its absence through `sqlite_master`.
7. `db_adoption_test` replays every step from v1 over one file, so each step
   must be a no-op on a re-run: `DROP … IF EXISTS`, and guard `dropColumn` /
   `addColumn` with the `_columnExists` helper.

## Tests

- Flat files: `test/<subject>_test.dart`; in-memory Drift via `testDb()` →
  `BondDatabase.memory()`; ALWAYS `await db.close()` in tearDown.
- Screen tests NEVER `pumpAndSettle` on `InboxScreen` (a 60 s periodic timer
  and no-looping-animation rule): three bare `tester.pump()` calls is the
  idiom; `pump(Duration(milliseconds: 400))` for scoring passes.
- Read pills and rows BY LABEL, never by count.
- The `@Skip`'d live harnesses (`test/*_live_test.dart`,
  `llm_target_verify_test.dart`, `golden_storyline_test.dart`,
  `golden_sweep_test.dart`) sit in every run as skipped; they never get
  accuracy thresholds (`docs/model-bakeoff.md`).
- Never run `flutter test` or `flutter analyze` while a live `make` bench is
  running: any load moves the timings the bench exists to measure, and the
  run is spent.
- `make app-run` and `make app-build` carry the box key and the registry
  token from `local.mk` in the `flutter` command line (and its
  `frontend_server` child's) for as long as they run, so never list a running
  flutter process WITH its arguments either. The two recipes drop both from
  the environment (`APP_NO_SECRET_ENV`), so the app and its llama-server do
  not inherit them, and so does every recipe that uses neither (the
  hand-started servers, `app-test`, the `dist-*` scripts): the Makefile's
  `export` is global because GNU Make 3.81 has no target-specific `export
  VAR`, and only `decide-fetch`, `app-doctor`, `app-run`, `app-build` and the
  `BENCH_DEFINES` benches read them.
- The Makefile resolves `BENCH_BEARER` into the `flutter test` command line,
  so never list a running bench's process WITH its arguments — `pgrep -f …
  >/dev/null` answers "is it running" without printing the key.
- Narrow scope while iterating (`flutter test test/<file>`); the full gate
  (`.claude/hooks/gate.sh <label>`) before review and commit.
- Never await a real filesystem or socket future inside a `testWidgets`
  BODY: the fake-async zone hangs the whole run silently and `--timeout`
  never fires. Create temp dirs, servers and supervisors in `setUp`.
- Fixture timestamps that a sync window or an age rule will judge are
  derived from `DateTime.now()` (`delta_paging_test.dart`'s `ago()` shape),
  never written as absolute dates: the one-day `syncFloorDays` window walks
  past a literal at midnight UTC and the test rots with no code change
  (it happened twice on 2026-09-12). One day is a SHORT window — a fixture
  two days old is outside it, and a fixture written as `Duration(days: 1)`
  straddles the midnight-truncated floor; use hours for anything meant to be
  inside.
- Model work runs only while the session's processing switch is on
  (`processingProvider`), which is SEEDED from the remembered `processing_on`
  preference and defaults OFF since the default-setup round (only `'true'`
  reads as on). `AiWorker` and `TriageQueue` each take an `enabled` closure
  and read it on every launch decision, so a test that builds either one
  WITHOUT that argument is unaffected; an inbox-level test that needs a drain
  to run seeds `processing_on = 'true'` in its store before
  `AppPrefsNotifier.read` (or overrides `processingProvider`). Turning it off also calls
  `stop()` on all four drains; `_setProcessing` on the inbox writes the
  preference LAST, after the drains are told, so a throwing write cannot leave
  lanes running under a switch that reads off. An inbox-level test that drives
  Clear AI results or Forget and re-sync seeds `processing_on = false` in its
  store, because `_resetPipeline` throws `StateError('Turn processing off
  first')` while the switch is on.
- `--plain-name` on a live `make` target is a SUBSTRING filter, so a new live
  test's name must not contain another target's word (`storyline`, `triage`,
  `reply`, `gates`, `sweep`) or it runs under that target too. The
  decision-model legs are named `golden decision pass` and `db agreement` for
  that reason; a new leg says `decision` or `text`.
- A live bench prints counts, ms, ratios and enum words only, never a subject,
  title, charter, slug, participant or thread key. That is
  `SweepTally.table()`'s rule, and it holds because the golden storylines are
  named out of real mail.
- `make golden-vector` is the sweep test under `SWEEP_STAGE=vector`: the same
  body and the same seeding as `golden-sweep`, stopped after the embedding,
  one embed server and no model call. A new live STAGE goes inside the
  existing test body under a define, never as a second test name.
  `SWEEP_STAGE=declared` and `make golden-declared` are the same shape again,
  and so are `SWEEP_STAGE=pairs` and `make golden-pairs`.
- Read only SCALAR fields off a sweep timing JSON. `extra.sweep.coverage`
  carries a `by_slug` map keyed by the registry's slugs, which name real
  efforts, so print `coverage.mean` and nothing under it. The same rule holds
  for every other `by_slug` map a tally writes.
- The FORMABLE line says how far a row sits from what the bench could reach.
  The sweep never proposes a group under three threads, so an item whose gold
  effort has fewer threads than that is unreachable by construction;
  `formable: P of F correct · ceiling C of N` counts the reachable ones from
  the fixture's own THREAD counts, which is why this set reads 35 formable and
  a ceiling of 74 of 100 where an estimate by items said 40 and 77 of 98. A
  row is read against the ceiling, never against 98.
- A bench runs from a CLEAN COPY of a commit whenever the main checkout is
  being edited. `git worktree` is hook-blocked for agents, so the copy is
  `git archive <commit> | tar -x -C <scratch>/<name>`, then `cp local.mk .env`
  into it (the gitignored machine files), `flutter pub get` in its `app/`, then
  `make -C <scratch>/<name> …` with `GOLDEN`, `GOLDEN_REGISTRY`, `GOLDEN_RUN`
  and `BENCH_OUT` pointed back at the main checkout. It compiles the committed
  tree, its build directory is its own so narrow tests cannot race it over the
  native assets, and its results still land in the main `tmp/bench`. A wall
  taken this way while the main checkout is busy is under load, and the row
  says so. A test-only comparison against HEAD is the same with `git archive
  HEAD app`.
- The shell is zsh, which does NOT word-split an unquoted `$v`: a bench loop
  that keeps `make` arguments in a variable hands make ONE argument with the
  spaces inside it. Write each argument out, or use an array.
- The golden judge flow (`make golden-judge-pack` → one Opus agent per packet
  → `make golden-judge-tally`) reads one file per item whose envelope is
  `{"id": <item id>, "judged": <the verdict object>, "_meta": {"model":
  "<judge tag>"}}` (`golden/tools/judge_pack.py`). The packet prompt describes
  only the inner object, so a judge prompt states the envelope and the ONE tag
  both sides of a comparison are judged under.
- The gate runs ALONE. A concurrent `flutter test`, typically an agent
  re-checking its own files, rebuilds
  `build/native_assets/macos/libsqlite3.dylib` while the gate's isolates are
  loading it, and a store test fails with `sqlite3_initialize`. A red gate
  carrying only that error is re-run once `ps -axo pid,etime,comm | command
  grep flutter_tester` shows nothing.
- The keychain under `flutter test` throws `MissingPluginException` and
  `SecureTokenStore` does not catch it: tests hand `AppPrefsNotifier` a
  `MemoryTokenStore` or a `RefusingTokenStore` from
  `test/fixtures/memory_token_store.dart`.
- A `DropdownButton` whose value is not among its items asserts. A picker's
  value falls back to the stored id, then the default, then null with a hint.
- `SingleActivator` defaults `includeRepeats: true`. A destructive key sets
  `includeRepeats: false`, and its test holds the key (a repeat event) and
  expects one act.
- `LinkedText` returns a Column with a hover caption when `onOpenLink` is
  set, so a widget test that finds `RichText` in a body takes `.first`.

## Working rules

- Tool calls leave the shell inside `app/`: use absolute paths or `make
  app-analyze` / `make app-test` from the repo root.
- Never `dart format` a tracked file (it once rewrote `inbox_screen.dart`);
  gates are analyze + test only.
- `unnecessary_import` fires when one file imports both a re-exporting library
  and the library it re-exports. The fix is `show` on the wider import, naming
  what that file actually uses, never dropping the narrower one.
- This SDK still needs `import 'dart:async'` for `FutureOr`: without it the
  analyzer reports `Undefined class 'FutureOr'`, so an "unused import" nit on
  it is wrong.
- `services/` never imports `providers/`; no dialogs or popups
  (`test/no_dialogs_test.dart`) — every surface is a screen or pane with a
  back button.
- Mail and chat HTML keep their links the same way: `holdAnchorRuns` before
  the converter's own tag strip + entity decode, then `releaseHeldMarks` /
  `stripHeldMarks` (`html_text.dart`; both `_mailText` and `stripChatHtml`).
  `canonicalLinkRun` stores the URL as Dart READ it (`webTargetOf(...)`:
  `%3a` → `%3A`, host lower-cased, `:443` dropped) — tests assert that form.
  Old chat bodies are never re-pulled to repair links (the Teams rule: every
  Teams call traces to a user action); a widened lookback or Forget does.
- One shared prompt per LLM task across sources, pinned by parity tests;
  examples ride in the user message, never the system prompt.
- Prefer narrow SQL statements over widening a `copyWith`. Request parameters
  may ride a work row's `payload_json` — `DraftRequest` is the one encoder and
  decoder for the draft row's pinned ids, context files and `asked` — and
  provenance never does.
- Three AI drains, not one: the FAST lane (needs-you, extract, embed,
  attachments, context — on `fastDrainGateProvider`, shared with
  `TriageQueue`), the STORYLINE lane (the six passes in ONE worker, which is
  what keeps `docs/pipeline/06-storylines.md`'s ordering true), the DRAFT lane
  (`draft` at `AppPrefs.proseParallel` wide, then `meeting_brief` one at a
  time; an asked draft is also pumped with `first:` so it waits behind at
  most one brief). Since the decision-model
  round every lane's chat calls go to the ONE generative model (drafts may go
  to Cloud drafts), so the lanes are an ORDER cut, not a server cut: a new
  handler goes on the lane whose ordering it needs, and order ACROSS lanes is
  enqueue-and-pump, not list position. Extraction decides by the clustering
  card's hash whether a thread's assign is owed, queues it and pumps the
  storyline lane per row (`onStorylineQueued`, `onDraftQueued`'s shape), so
  an assign never waits for the whole extraction backlog; it never embeds
  the card (`vectorFor` does, in the assign pass). The fast lane's message
  text is `LlmTargetSpec.textParallel` wide (8 on Your server, else at
  least 3). Triage makes no chat call but still
  shares `fastDrainGateProvider` for the yield ticket, so a triage pump can wait
  behind a message-text call already in flight. A handler that must wake the drain it runs INSIDE is handed
  the worker through a `late final` local in the lane's body, never
  `ref.read` of that lane's own provider: Riverpod asserts self-dependency on
  a `read` as much as on a `watch`, so a debug build throws `A provider cannot
  depend on itself` out of the handler mid-drain.
- `requeueWork(refreshCreatedAt: true)` only where a person asked for the work
  NOW (Regenerate, Draft reply, the two Retries, Restore, a storyline action):
  the drain claims `created_at DESC`, so a bulk revive keeps its stamps rather
  than jumping the whole batch in front of new mail. The one exception is
  `BriefPlanner`, which queues up to six briefs in reverse with the flag so the
  soonest meeting drains first. That is safe because a lane claims one kind at
  a time, so the stamps order briefs only among themselves.
- `ScriptedLlm` (`test/fixtures/scripted_llm.dart`) is the ONE `LlmClient`
  double: a per-schema script whose steps are a map, a string, a hold, a
  computed closure or a throw, with `calls` and the derived recorders
  (`schemas`, `userMessages`, `systems`, `temperatures`, `budgets`,
  `callsFor`, `maxInFlight`, `streamedCalls`) that the thirty-six hand-written
  doubles it replaced, across twenty-nine files, each kept their own copy of.
  A test needing a shape it cannot express hands it a computed step, never a
  new subclass.
  `completeJsonStreamed` stays a SEPARATE method from `completeJson`, and
  never add a named parameter to either: `ScriptedLlm` overrides both exact
  signatures, and a Dart override must accept every named parameter of the
  method it overrides, so the two signatures are frozen together.
  `runTask(onText:)` picks the path, only the draft call streams, and a
  streamed and a plain call of the same prompt must decode to the same object.
- Settings section titles and summary strings are pinned by
  `settings_screen_test.dart` and by the table in `docs/settings.md` — move
  all three together; a new segmented control is `SettingsSegments<T>`.
- The settings SURFACE is `SettingsHost` (`screens/settings_host.dart`), not
  the inbox: it owns the probe and every writer only settings calls
  (the two resets and `_resetPipeline`,
  `_reloadAfterBackendChange`, `_connectionStatus`, `_connectMicrosoft`), and
  the inbox binds it once for both rungs in
  `_settingsHost`. A new settings-only mutator goes on the host. Two methods
  stay on the inbox as injected seams and only these two: `_setProcessing`,
  because the sidebar's own switch calls it, and `_waitForPullsToSettle` with
  its `_quietTimeout`, because it reads the `_mailPulling`/`_teamsPulling`
  flags the inbox's syncs write.
- The clustering card is ONE recipe behind ONE entry: `clusteringCardFor(store,
  source, key, row, {variant})` in `storyline_cards.dart`, which every place
  that embeds a THREAD goes through (the assign pass's `_keptVectorFor`, the
  only writer of a conversation vector, whose test face is `vectorFor`, and
  the golden seed). `text` is the thread
  text the decision model reads (`storylineThreadTextFor`) and cannot be built
  by `buildClusteringCard` (it throws); every other variant is
  `clusteringCardForConversationRow` in `clustering_card.dart`, whose
  `ClusteringCardVariant` holds the nine cards and `shippedClusteringCard`
  names the one that ships, `topics`; `thread` and `topicsUntitled` are
  bench-only variants from the decision-model round (58/98 against the
  shipped card's 59/98), and `text` and `excerpt`, the cards buildable before
  extraction, read 45/98 and 47/98 against `topics`' 60/98 on 2026-09-30 and
  do not ship (nor does the namer on the message excerpt, 55/98). The
  assign pass hash-checks the card, so a bench under another `SWEEP_CARD`
  passes `StorylineService(clusteringCard:)` or every thread re-embeds under
  the shipped card; extraction queues the assign only once the thread's
  newest kept message has its text, and the pass re-checks the card when it
  ends (`assignRecheckLaps`). Behind `EmbeddingsClient.modelTag`; a tag
  bump orphans every stored conversation vector by construction, so it ships
  with a one-shot re-embed in `sync_service.dart` (Round A's pref idiom).
- `_accepts` in `storyline_service.dart` is the one membership rule at all
  five confirm sites (assign, recruit, sweep member, probe, audit): the
  decision model's `member_of` p against `StorylinePolicy`
  (`storyline_judge.dart`) — `acceptSuggested` for a `suggested` storyline,
  `acceptActive` for a kept one. `_confirm` asks `StorylineJudge.memberOf`,
  ONE batch per storyline per lap, and a decision exception propagates and
  parks the lane; no language model is asked about membership (the
  `storyline_membership` stage is gone). Both stayed in the service through
  the split, because one rule at five sites is not a seam. `acceptActive`
  0.50, `acceptSuggested` 0.74 and `charterSpecificTau` 0.50 (validated at 0.50 only) are FITTED on
  the v3 student (2026-09-30) and move only with a `make golden-storyline`,
  `golden-declared` or `golden-sweep` row on each side; a test's `member_of`
  yes must clear 0.74 for a suggested storyline. Storyline tests script `member_of`
  through `scriptedJudge(store, llm)` (`fake_decision_client.dart`): a
  `{'p': …}` step under the `member_of` schema name, one call per thread.
- The sweep groups by COSINE (`StorylineGrouper.candidates`, the one reader
  of `clusterLinkThreshold`, `clusterCoherenceFloor` and the split ladder):
  cosine PROPOSES the clusters and the decision model JUDGES them — the namer
  (`NameStorylineTask`) only WRITES (no `coherent`/`outliers`),
  `StorylineTuning.charterCheck` (`CharterCheck.model`: `charter_specific` at
  `charterSpecificTau`; `CharterCheck.lint`: the regex, `SWEEP_CHARTER=lint`)
  files a refused cluster `possible`, and each member is confirmed on
  `member_of`. `maxQuestionsPerPass` counts NAMING calls only, and
  `ensureReady` runs before the first naming call. A pair grouping on
  `same_effort` (cosine proposed pairs, average linkage over the judged pairs,
  a `pair_decisions` cache) was measured on the v3 golden sweep (57/98 at
  best against cosine's 60/98, because `same_effort`'s p on the golden pool
  is compressed near zero) and REMOVED on 2026-09-30, with its v23 table:
  unused code does not stay as a dark arm. The `same_effort` head stays in
  the contract (`StorylineQuestion.sameEffort`, `DecisionClient.askPairs`,
  `StorylineJudge.sameEffortOfTexts`), and `make golden-pairs` is how a
  future `same_effort` model is measured before a grouping on it is built
  again. `GroupThreadsTask`, the `storyline_group` stage and the
  `model`/`pool` modes are gone too. Storyline service tests answer
  `charter_specific` through `sweepJudge` (`storyline_service_test.dart`: a
  yes unless the test scripts it) with `{'p': …}` like `member_of`.
- The storyline service is four files now and one public face: the user
  actions in `storyline_edits.dart` (`StorylineEdits`), the clustering in
  `storyline_grouper.dart` (`StorylineGrouper`), the shared card statics in
  `storyline_cards.dart`, and `storyline_service.dart` keeping one-line
  delegates so its twenty importers, six in `lib` and fourteen in `test`, did
  not change. A new pass goes in the file whose job it is, and the service gets
  a delegate only if callers outside already reach for it.
- A cluster the models DECLINE is a `possible` storyline WITH its members, in
  the rail under **Possible · N** with Keep and Dismiss, never a member-less
  tombstone. `_filePossible` in `storyline_service.dart` is the one insert site
  for both reasons (the charter check, too few confirm survivors);
  `dismissedHashExistsAny` and `expireStaleSuggestions` read `possible` as well
  as their old status, and every pool, assign, recruit, refresh, recap and
  home-feed query names `('suggested','active')` and so leaves a possible
  storyline's threads unassigned and costs it no model call — on purpose, until
  somebody keeps it. `loadStorylines(withMembersOnly: true)` is what the
  Dismissed fold reads, so the member-less tombstones older builds wrote stop
  appearing there while still answering the hash check.
- ONE THREAD, ONE LIVE STORYLINE. `recruit`'s candidate walk excludes the
  sweep's `assignedOrBlockedKeys` set, read once per lap, so a declared
  storyline cannot take a thread another storyline already holds. Measured:
  before the rule, 41 of 57 recruited threads on the declared bench had landed
  in more than one storyline. The cost is that a contested thread goes to the
  first storyline to ask rather than the best match. A `possible` storyline is
  the one row whose members sit outside that set, so Keep is the one press that
  could break the rule: `StorylineEdits.keepSuggestion` drops every member a
  live storyline took meanwhile, re-hashes the survivors and dismisses the row
  instead of activating it when fewer than `minClusterSize` are left, in one
  transaction. A `suggested` row skips all of it.
- The fast gate carries a YIELD TICKET beside its queue. A triage pump that
  finds work asks for the yield and enqueues its own drain in the same step;
  the worker reads the flag only where it would claim its next item, so the
  item at the server is never abandoned; the drain queued at or after the ask
  clears it as its body starts, so the flag cannot outlive one handoff.
- The refs triage just wrote are served INSIDE a running pass, at every handler
  boundary and before every claim, not at the next pass top. Serving them at
  the top was measured on the box and was not enough: the late message's
  extraction still waited behind every needs-you in the backlog. The serve is
  guarded by a synchronous `isNotEmpty` check, because three bare awaits on the
  empty path let a drain outlive a test's database and three provider tests
  went red with "Can't re-open a database after closing it"; a test that builds
  a worker `addTearDown(worker.dispose)`.
- The sweep is re-armed by the fast lane only after a drain that processed
  something (`AiWorker.lastDrainCount`), and it defers above three floors
  read from ONE `pipelinePulse`: `sweepExtractFloor` (10), `sweepTriageFloor`
  (20) and `sweepAssignFloor` (10, the `storyline` KIND via
  `PipelinePulse.kindCount`, not the stage, which also counts the asking
  sweep row); no `embed_message` floor, since search vectors never fed the
  pool. Unsettled, it sweeps anyway once its pool (unassigned, embedded, not
  done) has grown by `sweepProgressStep` (40) since the size in the
  `storyline_sweep_pool_at` pref (a derived pref, reset by Clear AI results
  and Forget everything; the gate reads the size from
  `storylinePoolCount`, a COUNT that mirrors the pool loop clause for clause,
  so keep the two in step). The sync-time
  `requeueSweep()` is the durable trigger. The same floors (one reader,
  `StorylineService._pulse`) make `refresh` and `recap` return, quietly
  noted `unsettled: 1` (`ActivityLog` keeps that marker's row out of the
  panel), before any call or write, so a cold start's single
  storyline lane spends itself on assign and the sweep; the sweep's
  stale-refresh/recap heal runs only on a settled pass, or every wake would
  queue work that defers at once. Audit and recruit never defer.
- A `StorylineTuning` number moves only with a `make golden-sweep` row on each
  side, and a diagnostic flip of one is a single shell command that puts the
  constant back before it exits.
- Every `CREATE TABLE` in `schema.drift` sits in exactly one of
  `MessageStore.derivedTables`, `syncedTables` or `keptTables`, and
  `clear_derived_test` pins the classification. A new table is classified or
  Clear AI results forgets it; `wipeAll` derives its own list from the same
  three. The four vec0 tables are NOT in the lists: each index class resets
  its own in `clearDerived`'s rebuild tail, and a fifth index must be added
  there by hand.
- `clearDerived` queues extraction, needs-you and the per-message embedding
  for every kept message ITSELF, for every source and unbounded by the
  lookback, because the sync's backlog calls pass the lookback floor as their
  `sinceIso` and a reset is the one path that re-pends messages outside it.
  Leaving it to the sync is what left a narrowed window's older mail triaged
  and then never extracted, judged or embedded. A new per-message stage is
  added to that loop or it is skipped after every clear.
- Stages resolve their client through `stageLlmClientProvider(stageId)`, whose
  resolver reads `ref.read(appPrefsProvider.notifier).targetForStage(stageId)`
  at request time, and `decisionClientProvider` binds the same way through
  `targetForStage('decision')`. Nothing in `lib/` watches `appPrefsProvider`
  for a target, so a prefs write rebuilds no worker, and `llm_routing_test`
  pins the same client instances across a `useGenerative`. A null `LlmTarget.wire` means
  the client's own wire; `toTarget` stamps only Converse.
- `box` in code means YOUR SERVER, historically the GPU box: the enum value
  `ModelPlacement.box` is the Your server placement of EITHER role, the prefs
  `model_placement`, `box_big_url` and `box_big_model` ARE the generative
  role's placement, remote address and discovered model (keys reused so no
  keychain re-key was needed), and the keychain ids are `box-prose`
  (generative remote), `box-decide` (decision remote) and `cloud-drafts`. Only
  the words on screen say `Your server` and `This Mac`. `box-bulk` is
  `legacyBoxBulkId`, read only by the frozen one-shot migrations.
- Three ROLES, not slots: **Decision**, **Generative**, **Embeddings**.
  `ModelSlot {generative, decide, embed}` and `StageRole {decision,
  generative, embed}` in `model_slots.dart`; every chat stage in
  `pipelineStages` is `generative`, `decision` is the one `decide` row, and
  `embeddings` is not routed. The router ids stay `bond-prose` (27B),
  `bond-bulk` (4B), `bond-embed`, plus `bond-decide`: they are the `model`
  field on every managed request, the `ServerLoading` keys and the preset
  hash, so a role rename never touches them.
- Routing is a RULE in `AppPrefs.specForStage`, with no stored rows:
  `decision` → `decisionSpec`; the two `draftStageIds` → `cloudDraftsSpec`
  when one is set AND it is the owner's own host or `cloudDraftsConsent`
  stands; every other stage → `generativeSpec`. Each role spec is Your server
  (placement `box`, a non-empty effective URL, and `_ownServer`, the
  resolution-time belt that refuses a vendor host or the Converse wire), else
  the managed router (`/v1/chat/completions` with `managedGenerativeId`, or
  `/v1/embeddings` with `bond-decide`), else the `BOND_DEV_HAND_SERVERS`
  defines (`LLAMA_URL`, `DECIDE_URL`). A stored URL of `''` means follow the
  build (`$BOND_BOX_URL/prose/v1/chat/completions`,
  `$BOND_BOX_URL/decide/v1/embeddings`, where `$BOND_BOX_URL` is `local.mk`'s,
  passed by `APP_LLM_DEFINES`, with a `$(MS_ENV)` grep as the fallback); the
  generative remote is four wide only while it follows the build, one for a
  stored address. The generative placement defaults to `box` WHATEVER the
  build, and Your server with no address is the `box-prose` spec with an
  empty URL, unavailable with `generativeNoAddressText` (park `no_address`),
  never this Mac. A test asserting where a stage resolves says which
  placement it means (`modelPlacement: ModelPlacement.local` for this Mac),
  since `boxUrlDefault` is empty under `flutter test`. The writers are
  `useGenerative({placement, managedModel, url, model, key, clearKey,
  hardwareTier})`, `useDecision({placement, url, model, key, clearKey})`,
  `useCloudDrafts` / `clearCloudDrafts` and `clearRoleKey(id)`: each validates
  BEFORE it writes, moves the keychain BEFORE the URL, and `clearKey: true` (a
  host change) forgets the old host's token rather than sending it on. Both
  role URLs refuse a third-party host with their own sentence, because both
  models read every message; only Cloud drafts may be third party, behind
  consent. FOUR one-shots run in `AppPrefsNotifier.read`, in this order:
  `box_targets_derived`, `box_servers_derived`, `stage_targets_cleared`,
  `model_roles_derived` (a vendor big URL becomes Cloud drafts; its PENDING
  value carries keychain moves that `finishModelRoles` completes once a token
  store is there, and no `box-prose` token is attached while one is owed).
  `box_small_*`, `llm_targets`, `stage_targets`, `fast_llm_*` and
  `prose_llm_*` are inert.
- Every compiled default (`boxUrlDefault`, `boxKeyDefault`,
  `registryUrlDefault`, `registryTokenDefault`) is `''` under `flutter test`.
  Nothing past `AppPrefsNotifier`'s constructor reads them: a test hands the
  build's values to `AppPrefsNotifier(store, compiledBoxUrl:, compiledBoxKey:,
  compiledRegistryUrl:, compiledRegistryToken:)`, which stamps the two
  addresses and two PRESENCE flags (`boxKeyCompiled`,
  `registryTokenCompiled`) on `AppPrefs` and keeps the two secrets to itself.
- The build's key is used ONLY on the build's origin: `bearerFor(id)` is the
  keychain's entry, else the compiled box key (`box-prose`, `box-decide`) or
  registry token (`model-registry`) while the role's effective address has
  the compiled address's origin (`sameOrigin`: scheme, host, port), never a
  typed address on another host. `generativeKeyFromBuild` /
  `decisionKeyFromBuild` / `registryTokenFromBuild` say so; `hasBearer` is
  stored OR from the build; `boxBigKeyStored` and friends still mean "in the
  keychain" (they drive `Stored. Type to replace` and Remove key, and Remove
  key falls back to the build's). The form's `keyFromBuild` hints `Using the
  key from this build. Type to replace`. The Makefile passes the secrets as
  `"$$BOND_BOX_KEY"` shell references so `make -n app-run` never prints one.
- What the managed router serves is `managedManifestProvider`
  (`ModelManifest.forRoles`): embed, plus `bond-decide` while the decision
  role is on this Mac, plus the chosen generative model while that role is
  (`managedGenerativeIdFor`: full tier → 27B, inbox → 4B, a stored 27B on the
  inbox tier falls back to the 4B). The supervisor's `buildPreset` serves only
  `withPresentFiles(folder, ledger)`, because the server refuses a preset with a
  missing file and one absent model must not cost the others, and records the
  served ids with `setServedManagedIds`; `AppPrefs.unavailableFor(spec)` then
  puts a sentence on `LlmTarget.unavailable` for a managed target the router
  does not serve, and `LlmClient` and `DecisionClient` throw on it before any
  HTTP, so only that role parks (`not_installed`). `machineTierProvider` still
  answers what this Mac could hold. The decide entry is a REGISTRY entry
  (`source: artifactory`, repo `artifactory/bond-decide-mbl-v3swap`, bundle
  `bond-decide-mbl-v3swap`): downloaded with its heads file, ledgered as
  `bond-decide` and `bond-decide.heads`, and USABLE only when both rows are
  current and both files are in the folder: `DownloadLedger.servable` is the
  ONE rule the preset, the heads reader (`decisionHeadsProvider`, through
  `SetupStore.knownLedger`, read synchronously per call) and the Models
  page's `On disk` / `headsOnDisk` share, so a pair half replaced is never
  served; a Hugging Face entry is served on its files, a local one on its
  files. A Download again takes the entry's rows out of `done` as it starts
  (`ModelDownloader._unsettle`), and files placed by `make decide-fetch`
  join once a pass has hashed them in: the next launch or a Download press,
  with a registry address set or not (`_withoutRegistry` hashes a present
  file whose row is not `done` before it fails the leg). A fixture that puts
  registry files on disk and expects them served writes
  `currentLedgerFor([...])` (`test/fixtures/current_ledger.dart`) through
  the container's own `setupStoreProvider`. A `source: local` entry (repo
  `local/<name>`, no download, no ledger row, installed when its files are
  present) is still parsed and handled everywhere, and its cases are tested
  with `testLocalDecideFile()`.
- Whether the app runs its own llama-server is `managedServerDefault`, a
  CONSTANT read off `--dart-define=BOND_DEV_HAND_SERVERS` the way
  `SetupGate.skipDefine` reads its own, not a preference: `AppPrefs
  .managedServer` keeps its field so a test can say `AppPrefs(managedServer:
  false)` and assert the compiled URLs, and a bare `AppPrefs()` is on the
  router. A busy port is not a question either — the supervisor takes a free
  one and AWAITS `onPortMoved` (wired to `setRouterPort`) before it spawns, so
  the preference, the pid record and the clients agree.
- The Models page (`SettingsModelsPage`, `widgets/settings_models_page.dart`)
  is THREE role blocks, top to bottom, and prop-only. **Decision model** and
  **Generative model** are each a `SettingsSegments` of **This Mac** | **Your
  server** (`settings-decision-mode`, `settings-generative-mode`);
  **Embeddings** is a status line (`settings-embed-status`). This Mac is a
  status block: `settings-decision-status` with **Check**
  (`settings-role-check-decision`: `ensurePreset()`, `ensure()` on the model
  ensurer, and refresh the status, which is how a file that landed while the
  app runs is picked up; the heads are re-read by the client when the file's
  mtime moves) and, while the downloaded decision model is not on disk and
  no download runs, **Download** (`settings-decision-download`, calling
  `onDownloadModels` = `ensure()`); the status reads `On disk · loaded` /
  `On disk · not loaded`, `Downloading NN%` (`EnsureState`), the failure's
  `describeDownloadError` sentence (`EnsureState.errorFor(id)`, each entry's
  own), or `Not downloaded yet.`; a `source: local` entry keeps `Installed ·
  …` / `Not installed. Copy the model files into the models folder.` and no
  button. `settings-generative-status` with the 27B | 4B pick
  `settings-generative-managed` (the 27B disabled on the inbox tier) gets the
  same download words and its own **Download**
  (`settings-generative-download`). **Model registry**
  (`ModelRegistryForm`, `widgets/model_registry_form.dart`) sits after
  Embeddings, keyed `settings-registry-{url,token,save,remove-token,check,
  refusal,status}`: the token field obscured, EMPTY after a Save, hints
  `Stored. Type to replace` / `Using the token from this build. Type to
  replace` / `A new address needs its own token`, another origin with a
  blank token sends `clearToken`, Check is `registryProbeProvider` on the
  heads file with `Range: bytes=0-0`. Also `settings-models-status`,
  `settings-models-progress`, `settings-show-log`, `settings-set-up-again`
  and `settings-idle-models`. Your server renders
  `ModelServersForm` (`widgets/model_servers_form.dart`), ONE one-address form
  per target, `ServerFormRole {decision, generative, cloudDrafts}`, keyed
  `servers-<decision|generative>-{url,key,model,model-text,refusal,error,connect,remove-key}`
  and, in the Cloud drafts section, `cloud-drafts-*` plus
  `cloud-drafts-target`. The form OWNS the address rules (`isBoxOrigin`, a
  path containing `/v1/` unless `wireForHost` answers Converse, the
  third-party refusal) and refuses under the field rather than letting a host
  throw past a fire-and-forget press; the model name is DISCOVERED from
  `/v1/models`, and an origin change sends `clearKey`. A decision on Your
  server that is ModernBERT still reads this Mac's heads file, so its status
  needs that file too; a Kev server does not, a kind not yet known names no
  install, and the kind line `settings-decision-kind` says which (the host
  asks `detectKind` once per address when it opens).
  `SettingsHost` wires `onUseDecision`, `onUseGenerative`, `onCheckDecision`,
  `onRemoveKey`, `onSaveRegistry` (`useRegistry`, an `ArgumentError` becomes
  the refusal sentence, never the token), `onRemoveRegistryToken`,
  `onCheckRegistry` and `onDownloadModels` (null takes a control off), and
  every role or registry write is followed by `supervisor.ensurePreset()`
  (role writes; it restarts the router only when the preset hash changed) and
  `ensure()`. The Advanced fold, the stage picker, the targets
  list, the Local server card (Round H) and `useBox` / `usePlacement` /
  `RoleLine` (the decision-model round) are gone.
- The wizard's Where step (`screens/setup/setup_where_body.dart`,
  `SetupWhereBody`) asks the Models page's two questions: decision cards
  `setup-where-decision-managed` | `setup-where-decision-custom`, generative
  cards `setup-where-managed` | `setup-where-custom`, and under This Mac the
  27B | 4B pick `setup-where-generative-model`. Your server renders the same
  `ModelServersForm` per role with `onThirdParty: null`, so a vendor address
  is refused with its sentence and cloud services stay a Settings decision.
  The decision form says **Connect** and writes at once
  (`SetupController.connectDecision` → `useDecision`), staying on the step
  (`setup-where-decision-connected`). The generative form's press says
  **Continue** and IS the way forward: `SetupFlow` returns
  `continueFromWhere(generative:)` from `onConnect`, and a throw comes back to
  the form, which is the thing that can draw it. Under This Mac the step's
  own Continue calls `continueFromWhere()`, which writes `useGenerative(local,
  managedModel:, hardwareTier:)` with the HARDWARE tier and `useDecision(local)`
  when the decision is on this Mac. A decision sent to Your server and not
  yet connected refuses the Continue with `decisionFirstText` before anything
  is written. `SetupState` carries `placement`, `decisionPlacement` and
  `generativeManaged` and nothing of any address or key; the Models step
  lists the decision model under `setup-models-decision`.
- Under `flutter test` `hardwareInfoProvider` answers `HardwareInfo.unknown` at
  its two-second timeout, so the tier is `AsyncLoading` for the first two
  seconds. A test that needs a readable machine overrides
  `hardwareInfoProvider` with one and pumps past two seconds in bounded steps.
- Never run `make model` or `make fast` beside the app's managed server on one
  Mac. Two 27Bs and two 4Bs wired with `mmap+mlock` is about 50 GB, and it
  panicked a 64 GB Mac on 2026-09-21. Stop the make servers first
  (`make stop fast-stop embed-stop`).
- A probe of a target with a stored bearer PASSES it:
  `ModelServerProbe.probe(url, bearer:)`, resolved through
  `AppPrefsNotifier.bearerFor(id)` at the moment of the press. The widgets take
  a `storedBearer` LOOKUP, never the value, and the token never enters widget
  state, a `ProbeStatus`, a log line, a test name or a test expectation. Assert
  that a field obscures it and that no rendered `Text` carries it, never that
  the string is absent from the tree: `find.text` reads an `EditableText`'s
  controller rather than the bullets it draws.
- A bearer is a SECRET. It belongs in the keychain under
  `llm_target_bearer:<id>`, in the notifier's cache, on the resolved
  `LlmTarget.bearer` and in the `Authorization` header, and nowhere else:
  never `app_prefs`, a `toString`, an `LlmCallRecord`, an exception message, a
  log line, an activity row or a draft row.
- Consent for a third-party Cloud drafts target on `draft_reply` or
  `draft_improve` is enforced in `AppPrefs.specForStage` and in
  `useCloudDrafts`, never on the screen alone. Consent is machine-wide: a
  second vendor connects without a new pane once one was consented.
- THIRD PARTY means Bedrock and the three model vendors, not AWS.
  `isThirdPartyHost` lives in `app/lib/services/llm/model_slots.dart`, beside
  `LlmTargetSpec`, and is true for a host under `anthropic.com`, `openai.com`
  or `deepseek.com`, and for a Bedrock runtime host, meaning one starting
  `bedrock` and ending `.amazonaws.com`. The owner's own inference box under a
  Route 53 name or an EC2 public name is the owner's machine and needs no
  drafts consent; `LlmTargetSpec.isThirdParty` still ORs the Converse wire, so
  a Converse target is third party wherever it lives. It is a DENYLIST: any
  other vendor's host counts as the owner's own server for both roles.
- Cloud drafts: every door reads `CloudDraftLedger.refusal()`, meaning
  Improve, the standing rule, a prefetched draft on a third-party target and
  an asked-for one before its row is touched. The handler notes `cloud: N` on
  its own activity row BEFORE the call, and `cloudDraftsSince` sums it since
  local midnight at the store's six-digit stamp precision. An error line names
  the target and a category, never the endpoint, because
  `LlmUnavailableException.message` spells the URL; activity notes carry
  target ids, never a URL. `redactEndpoints` (`llm_client.dart`) is the one
  choke point between an exception's sentence and a stored row: every
  `LlmCallRecord.error` and both of the worker's failure writes pass through
  it, so `llm_error` and a work row's `error` read `<endpoint>` where the
  sentence had a URL. The exception itself keeps the full sentence for the
  screen. `llm_error_redaction_test` pins the existing sites; a new place that
  writes an exception's text into a row must go through it as well.
- `draft_improve` is a generative stage like the rest, routed by the role
  rule exactly as `draft_reply` is (Cloud drafts when set and consented), and
  it is the one row with NO SCHEMA of its own: it runs
  `DraftTask` and its call record is labelled `draft_reply`, which is the
  exemption `model_slots_test` pins literally. It was the one
  `PipelineStageInfo.optional` row until Round H, when the stage picker that
  was the only way to turn it on was deleted; the field survives with no member
  and nothing branches on it any more.
- The machine tier is `MachineTier` in `model_slots.dart`, chosen from
  `hw.memsize` by `machineTierFor` and never persisted, so a models folder
  carried to another Mac is re-read on the Mac it is on. `AppPrefs.machineTier`
  is set by the supervisor's `buildPreset` (before any managed request) and by
  every `useGenerative(hardwareTier:)`, the wizard's included; it decides the
  managed generative model. Unknown memory resolves to `full` because unknown
  never refuses.
- The manifest and the Makefile are two worlds joined by
  `manifest_makefile_parity_test.dart`, so a change to any of them edits both
  or fails the test: the four entries, three by `-hf` repo (`MODEL_HF`,
  `FAST_HF`, `EMBED_HF`, the quant either from a `:quant` suffix or from the
  repo name having to carry the manifest file's own quant token) and the
  registry decide entry by folder, file, heads, bundle, remote names and
  digests (`DECIDE_DIR`, `DECIDE_FILE`, `DECIDE_QUANT` f16, `DECIDE_HEADS`,
  `DECIDE_BUNDLE`, `DECIDE_REMOTE_GGUF`, `DECIDE_REMOTE_HEADS`,
  `DECIDE_GGUF_SHA`, `DECIDE_HEADS_SHA`) and by its server args
  (`DECIDE_ARGS`: pooling, `-c`, `-ub`, `-b`, `-np` against the preset);
  `CTX_SIZE`, `MODEL_CTX`, `SLOTS`, `FAST_SLOTS`, the embed `--pooling` word
  and the prose spec type. One blind spot remains: the recipes launch the
  servers from `MODEL_FLAGS` and `FAST_FLAGS`, so a literal written into those
  in place of `$(CTX_SIZE)` drifts past every assertion the test makes.
- `ModelEnsurer` (`services/models/model_ensurer.dart`, `modelEnsurerProvider`)
  downloads what the placements need and the disk lacks, outside the wizard:
  the set is `modelEnsureSetProvider` (`managedManifestProvider` plus the
  decide entry when absent, i.e. under Your server, D10, `.downloadable`;
  no embed entry under `BOND_DEV_HAND_SERVERS`, where `make embed` serves it).
  ONE ownership rule for the ONE downloader: nothing starts while
  `setupShowingProvider` is up (the gate writes it from its decision's
  callback, never in a build); another owner's run is WAITED for
  (`EnsureState.waiting`, then `ModelDownloader.idle`, then the scan), never
  dropped; `standDown()` (the gate, as it shows the wizard) cancels the
  ensurer's OWN run keeping its parts; the wizard's `startDownload` waits for
  `idle` too (`SetupState.downloadWaiting`). A PAUSED run
  (`ModelDownloader.paused`) is never waited for: the wizard cancels its own
  as it leaves the download step (any `_goTo` off it, Finish, Back to the
  inbox), and both waiting loops cancel one they find, parts kept. It is
  SINGLE-FLIGHT coalescing FORWARD (a call before the pass's scan joins it; a
  call after gets ONE shared further pass, skipped on blocked, dispose or
  `standDown`), AWAITS
  `prefs.ready` before a run (a stored registry token is a synchronous cache
  lookup), and calls `afterRun(landedIds)` after EVERY pass: the provider
  restarts the router when a landed id is one it serves, else asks
  `ensurePreset()` (which is what picks up a file the wizard's run landed
  after Finish). `ensure(reverify: {id})` re-HASHES that entry's files
  (`ModelDownloader.run(files, rehash)`), Settings' **Download again**. The
  downloader is a LOOKUP (`downloader: () => …`), so reading the ensurer's
  state builds no manifest. The gate kicks it when it shows the APP;
  Settings on Check, Download, registry Save / Remove token and every
  placement write. `modelEnsureStateProvider` exposes its `EnsureState`
  (per-entry `fractionFor`, `landedIds`, `errorFor`), and
  `managedModelsStatusProvider` re-reads when its phase moves or an entry
  lands. Widget tests override `modelEnsurerProvider` with
  `RecordingEnsurer` (`test/fixtures/recording_ensurer.dart`; it counts
  `ensure`, `reverify` sets and `standDown`). A widget test that needs REAL
  loopback HTTP (the in-process `FakeHubServer`) builds its client with
  `HttpOverrides.global` briefly null: the test binding answers every
  `HttpClient` with a 400, and the real ensurer path under the gate is
  driven that way with `tester.runAsync` (`setup_gate_test.dart`). The wizard's Continue
  waits on `downloadsComplete` (the GATING entries only, D7); a registry row
  that failed shows `registryLaterText` and never holds it, and
  `allDownloaded` decides whether arriving at the step starts a run.
- Registry downloads (`ModelDownloader` with `registryBase` and
  `registryToken`, both LOOKUPS read per registry entry: the provider's
  `AppPrefs.effectiveRegistryUrl` and `registryToken(base)`, which answers
  `bearerFor(registryId)` only when `base` has the current address's origin,
  so the address and the token come from one snapshot). A registry
  leg's URL is `ModelFile.registryUri(base)` / `headsRegistryUri(base)`
  (`<base>/bundles/<bundle>/<remoteFile>`, the base through
  `normalizeBoxBaseUrl`); `resolveUri` and `sidecarResolveUri` throw for a
  registry entry, they are Hugging Face's. A leg carries `Authorization` to
  its OWN origin only (`sameOrigin`): every registry leg follows redirects by
  hand, so object storage never gets the token and each answer is judged by
  the hop that gave it (a storage 403 re-resolves). `isRegistry` is the ONE
  rule for owning a heads leg (`isCurrent`, `_specsFor`, `downloadBytes`,
  the preflight, `_allFilesPresent`), and the parser refuses `heads` on a
  Hugging Face entry. 401/403 from that origin is
  `DownloadError.unauthorized` (no retry), a 404 from it is
  `registry_not_found` (no retry), and a FIRST answer of 200/206 with a
  `text/html` content type is `registry_not_a_model` at once (never a
  Hugging Face leg); no base is `registry_not_configured` before any request.
  `FakeHubServer.registryWebPage` serves the login page. The heads file is the
  entry's LAST leg, ledger id `DownloadLedger.headsId(id)` = `<id>.heads`,
  counted in `downloadBytes`, required by `isCurrent`, `verify`,
  `_allFilesPresent` and the disk preflight. `ModelManifest.gating` (the
  Hugging Face entries, `gatesSetup`) is what the wizard gate and the
  resume's ledger check read (D7); `downloadable` (everything not local) is
  what the wizard downloads. Tests serve a registry from
  `FakeHubServer.registryContents` (`registryBase`, `registryBearer`,
  `registryRedirect` + `startStorage()` for a second origin; `registryAuth`
  / `storageAuth` record the header against the FAKE token only).
- The MTP head is a nested `sidecar` record on the manifest's prose entry, not
  a fourth model: it carries its own revision, sha256 and size, lands in the
  parent's repo folder, and `downloadBytes` counts it so the wizard's total is
  the weights plus the head. `RouterPreset` writes it as a `model-draft` line
  straight after `model` and unquoted, and the entry's `spec-type = draft-mtp`
  only because the head is now on disk. `model-draft` as a preset key is
  UNVERIFIED: no managed server has been started with the head present, so the
  first live start is what confirms llama-server reads it. The parity test's
  Makefile parser is the other half of this: it splits on `[ \t]*\?=` and never
  `\s*`, because `\s` matches a newline and an empty default such as
  `DRAFT_HF ?=` swallowed the line under it, which is how `SPEC_TYPE` stayed
  invisible to the test until Round G asked the manifest to agree with it.
- A Converse namer can stop on `max_tokens` and lose a whole sweep pass after
  the seeding, so a cloud namer row is read on two COMPLETED passes and a lost
  pass is re-run, never patched.
- A one-shot pref over a derived corpus belongs in
  `MessageStore.derivedOneShotPrefs`, or Clear AI results leaves the pref set
  over a table it just emptied. A walk closes its pref either by returning a
  slice under `clusteringCardReembedCap` or by `uncapped: true`; a corpus that
  can exceed the cap and is re-nulled unconditionally needs the flag.
- `first_token_ms` is written into `detail_json` only when a call streamed, so
  triage rows carry no key at all and the expanded detail prints no dash.
- Every live test writes its result through `LiveBench.writeRun`, and the five
  load-bearing words in the test names stay put: `triage`, `reply`,
  `storyline`, `sweep`, `gates`. A name that loses its word runs nothing and
  the target still goes green.
- `PIPE_POLICY` defaults to `all` on `make bench-pipeline`, because every
  historical pipeline row was taken at `all`. A `needsYou` row is read as the
  difference from an `all` row taken the same day.
- Re-measuring reads against the row of record within a day and a tree. Under
  four points on a triage enum, under three drafts on the rubric, anything but
  an identical count on the storyline benches, and a timing outside the
  idle-machine band are all NOT findings.
- `DecisionClient` THROWS, unlike `EmbeddingsClient` (which returns an
  `EmbedResult` and never throws), so the triage queue PARKS and never falls
  back to a language model: transport, timeout, 5xx and 429 →
  `DecisionUnavailableException` (an `LlmUnavailableException`, park reason
  `decision_unavailable`, its own rail sentence); 401/403 →
  `LlmUnauthorizedException`; bad JSON, a width other than 1024, a
  NORMALIZED vector (norm within 1e-3 of 1.0: the server ignored
  `embd_normalize: -1`, and the heads read the raw mean), a refused heads
  file, and a server whose `/tokenize` does not answer ModernBERT's `[50281 …
  50282]` for `"a"` with the specials (the identity probe, once per client
  and target, passes cached, which is what tells the embedding model's 1024
  raw numbers apart) or has no `/tokenize` at all →
  `DecisionMisconfiguredException`, park reason `decision_misconfigured`;
  any other 4xx → `LlmFormatException`. A test that points a real
  `DecisionClient` at a `MockClient` answers `/tokenize` too. The one 500 it
  does NOT treat as unavailable is llama-server's `too large to process`: that is the signal to `/tokenize`
  (the router routes it by the body's `model` and requires it), keep the first
  2046 ids and send `[50281] + ids + [50282]`; it costs no attempt and never
  parks.
- The decision state is rendered in Dart (`services/decision/decision_state.dart`,
  a port of jev-prototype's `distill/state.py` + `build_states.py`) and pinned
  BYTE FOR BYTE by `test/fixtures/decision/render_cases.json`: fictional cases
  regenerated by jev-prototype `distill/export/render_fixtures.py` after any
  renderer change there, and never edited by hand. Its marker strip is
  `stripDecisionMarkers`, NOT the app's `stripAttachmentMarkers` (which also
  strips `[[img:…]]` and trims with Dart's rules), whitespace collapses ONLY
  when a marker was present, and `message_block.dart` is never reused for the
  state. The date line is the Mac's LOCAL zone, as in training: render on the
  Mac, never on a server. The golden leg composes through the same
  `renderDecisionStateFromParts`, so the two cannot drift.
  `decisionRendererVersion` (`'bond-state/2'`) beside it names the WHOLE
  renderer set, the heads file carries it and `DecisionHeads.fromJson`
  refuses another; it is bumped only with a change to the bytes of any
  renderer in the set, fixtures and all. The storyline texts (thread, pair,
  membership, charter) are `services/decision/storyline_state.dart`, a port of
  jev-prototype `distill/eval_questions/renderers.py`, pinned by
  `test/fixtures/decision/render_cases_v2.json` (jev
  `distill/export/render_fixtures_v2.py`, never edited by hand). The Python
  pitfalls: caps count code points (`runes`); whitespace is the fixture's
  `str.isspace()` set, never `trim()` or `\s` (U+FEFF, U+180E and U+200B are
  not whitespace); collapsing comes before the Re/Fw strip; and the people
  de-dup is `pyLower` (Python `str.lower()`: `İ` → `i̇`, final sigma), never
  `toLowerCase`.
- The decision role has TWO server kinds (`DecisionServerKind`) behind one
  `DecisionClient` API: `encoderHeads` (ModernBERT on llama-server, heads in
  Dart) and `systemOne` (Kev 4B behind jev's wrapper, `POST
  <base>/v1/systemone` with the plain question texts from
  `decision_questions.dart`, answers calibrated THERE, nothing applied in
  Dart). A managed or hand-started target is always encoder-heads and costs no
  request; only a target the provider's `isYourServer` names is asked `GET
  <base>/v1/models` once (a `qhash` entry → systemone, refused unless it is
  `decisionQhash` over `bond-state/2`; anything else → encoder plus the
  identity probe; a listing that is not a 2xx JSON object is "no listing"),
  cached under the probe's key and dropped with it on any unavailable,
  unauthorized or misconfigured throw. The systemone path never calls
  `heads()`; a malformed answer or a 404 on `/v1/systemone` parks
  `decision_misconfigured`. Your server's sentences never say `make decide`.
  A test that points a real client at a `MockClient` with `isYourServer`
  answering yes answers `GET …/v1/models` too; without it (every older test)
  no listing is asked. The provider's HTTP client is
  `decisionHttpClientProvider`, the seam a wiring test overrides.
- The heads file (`decide-heads.json`, downloaded beside the GGUF under
  `<models>/artifactory_bond-decide-mbl-v3swap/` from the registry's
  `heads.json`; `make decide-fetch` fills the same folder) is needed on THIS
  Mac for the encoder-heads kind even when its server is remote: the heads, temperatures and
  softmax run in Dart. It arrives as the decide entry's last download leg
  (the wizard's run or the model ensurer's), sha-checked and ledgered as
  `bond-decide.heads`, and the ensurer fetches it under Your server too
  (D10). It is SCHEMA 2 with 12 `questions`: the nine message
  fields (renderer `message`, `decisionFields` order), then `same_effort`
  (`pair`), `member_of` (`membership`) and `charter_specific` (`charter`),
  each `yes`/`no`. `apply` answers the nine; `pYes(question, vector)` answers
  one storyline question. `decisionHeadsProvider` re-reads it when its mtime
  moves and refuses a file whose `qhash` is not `decisionQhash`
  (`'f495a7dc48aa34d5'`, `decision_questions.dart`, the one place it is
  named). A schema-1 file (the older model) throws
  `DecisionOlderModelException` (in `llm_client.dart`, so `parkReasonFor`
  can name it), park `decision_older_model`, with `DecisionHeads.olderModelText`
  in plain words and no command; Settings adds a quieter `Press Download again to
  replace it.` line. A missing file parks the decision pass
  (`decision_not_installed`, "The decision model is not downloaded yet. Open
  Settings, Models."), and so does a registry entry's file whose download
  rows are not current (`DownloadLedger.servable`). A hand-installed entry's
  refusals (the heads reader's `mismatchLocalText`, the rail's
  `decisionLocal`, Settings' local sentences) say
  `DecisionHeadsFile.copyFilesText` instead of Download again; a Kev server's
  `decision_misconfigured` still reads the default rail sentence, because the
  park carries no kind (the client drops its kind cache on that throw). Tests
  build heads from `test/fixtures/decision_heads_fixture.dart`
  (`syntheticHeadsJson`, schema 2, one axis per option, `yesAxisOf`).
  `MessageStore.decisionFor` answers null for a row stored under another
  qhash, and every `writeDecision` passes `decisionQhash`.
- The `DecisionPolicy` constants (`services/decision/decision_policy.dart`:
  `gateDrop`, `booleanYes`, `replyYes`) were fitted on the golden set and move
  only with a golden row on each side (`make golden-decision`, plus `make
  golden-prose` for `replyYes`), the `StorylineTuning` rule.
- Needs You is ONE predicate: `needsYouAt(p, threshold)` / `needsYouAtSql` /
  `MessageStore.threadNeedsYouPSql`; the slider (`needs_you_threshold`,
  default 0.35) is the only CUT; every reader goes through it; no
  language model is asked about needs-you, and the attention score only
  orders. The owner's Remove/Add presses are NOT a second rule: they are
  labels that `applyDecision` applies before it stores a decision
  (`NeedsYouExemplars`: the message's own label, else the nearest label vector
  at cosine ≥ 0.97 under the same `vector_model`), so `needs_you_p` already
  carries the owner's answer as 1.0/0.0 and no predicate, SQL spelling or
  reader reads a label. A new decision path goes through `applyDecision` with
  the provider's `needsYouExemplarsProvider` or it ignores the owner. A
  THREAD's p is the MAX over its kept inbound messages after its last
  outbound (all kept inbound when it has none), not the newest one's, so
  a bystander's reply-all cannot hide an older unanswered ask; that is
  deliberate, do not "fix" it to the newest. `needs_you_verdict`,
  `attention_threshold` and `needs_you_rules` are inert.
- The storyline questions' thread text (`storylineThreadTextFor`,
  `services/decision/storyline_thread_input.dart`) mirrors jev-prototype
  `distill/storyline_data/corpus.py`, the code the training threads were
  built with, not the plan's prose: subject and participants as the
  `conversations` row derives them (re-derived from the thread's own messages
  oldest first), shown = outbound plus kept inbound, `who` = `You` / name /
  address, an empty body takes the decision state's attachment stand-in. Where
  the rows cannot match it (unfetched bodies render Graph's preview, so
  `StorylineJudge` fetches `previewIds` first; recipient names; a renamed
  Teams chat) the file's header lists it. Re-read corpus.py before changing
  anything here; a change to the bytes is a change to what the model was
  trained on.
- `decision_labels` (v22) is KEPT: the owner's storyline presses logged as
  labels for the storyline questions (`member_of`, `charter_specific`), with
  the storyline's title and charter at the press. Written ONLY at an owner
  press, never by an automatic pass: storyline rows by `StorylineEdits` (Keep
  and Dismiss of a suggestion or possible row, add, remove, a charter written
  — Allow again writes none, lifting a veto is not a yes) through
  `writeDecisionLabels`, `question = 'scheduling_ask'` rows (answer `no`,
  origin `invite`/`dismiss`, through `writeSchedulingAskLabel`, undo:
  `deleteSchedulingAskLabel` by id and stamp; answer `yes`, origin `owner`,
  through `reopenSchedulingAsk`) by the inbox, and
  `question = 'needs_you'` rows by `NeedsYouEdits`
  ("Remove from Needs You" / "Add to Needs You") through `writeNeedsYouLabel`,
  read back by `needsYouLabels()` as `NeedsYouLabel`. The one UPDATE the log
  takes is `updateNeedsYouLabelVector`, the vector refresh `applyDecision`
  makes when a labelled message is decided under another model, and the
  DELETEs short of a wipe are `deleteNeedsYouLabels`, the undo of a press
  (`NeedsYouEdits.retract`: delete first, then write again the messages
  citing the ids it returns), and `deleteAllNeedsYouLabels`, Settings'
  Forget (`retractAll`, which then writes again every message with an owner
  answer, `messagesWithOwnerAnswer`). Both restore from the stored
  decision's own model number and need no model. Undo is never the opposite
  press.
  `NeedsYouExemplars` checks a count/max-id signature on every load, so a
  wipe is seen without an invalidate. Clear AI results keeps it and
  `wipeAll` deletes it. The storyline `DecisionLabel` is a RECORD typedef
  with no optional fields; do not widen it, add a writer.
- The owner's Needs You buttons are on `ThreadActionBar`, exactly one drawn
  by `inNeedsYou` (`isNeedsYou` at the slider, passed by
  `ThreadDetailPanel._actionBar()`): `thread-action-needs-you-remove` /
  `thread-action-needs-you-add` (`needsYouRemoveKey` / `needsYouAddKey`), and
  Add never on a Done or Later thread. A press returns a `NeedsYouPress`
  (`needs_you_edits.dart`: the label `ids` and the ONE `createdAt` stamp they
  share; empty ids when the window was) through
  `ConversationsNotifier.removeFromNeedsYou` / `addToNeedsYou` (null on a
  decision error, which the inbox words as the house failure toast), and the
  toast's Undo hands it to `undoNeedsYouPress` → `NeedsYouEdits.retract`,
  which deletes by id AND stamp (`id` is reused after a delete), then
  restores the citing messages from their stored decisions, no model call.
  The press's SWEEP runs inside it, awaited, both ways (a removal over the
  threads in Needs You, an addition over those out of it and neither done
  nor in Later): a SCAN of stored decision vectors
  (`needsYouCandidateVectors`, cosine ≥ 0.97 to any of the press's label
  vectors), never model calls, so `NeedsYouPress.changed` is final when the
  toast reads `Removed from Needs You — and N like it.` (no tail when N is 0,
  always on Kev). A press and its sweep write from the STORED decision
  (`StoredDecision.modelAnswers` + `vector`) whenever it has a vector under
  `DecisionClient.resolvedModelTag` (which learns Your server's kind first;
  the sync `modelTag` answers null until then), and ask the model only for a
  message without one; the needs-you pass reads the same. Undo and Forget
  restore from the stored row under its own model, never asking. An addition's sweep scans most of a mailbox, so candidates come
  back as BLOBs and are compared off the bytes, never decoded in bulk.
  `FakeDecisionClient.tag` is what a test sets to make its stored decisions
  count (both getters answer it), and `calls` proves no call was made. Add
  has its own in-flight guard on the inbox (`_adding`).
  Add is not drawn when `Conversation.needsYouP` is null
  (`ThreadActionBar.needsYouDecided`). The notifier takes the service
  as a getter (`needsYouEdits: () => …`), so a test builds it over `testDb()`
  without a decision client. A press decides before it writes, so a failure
  changes nothing; a press, Undo and Forget refuse with processing off
  (`StateError`).
  An inbox test that presses overrides
  `authSessionProvider` (the press reads the owner's account, which the
  default session never answers under `flutter test`). The owner's four
  reason sentences are spelled once, `ownerNeedsYouReason`
  (`decision_policy.dart`); a surface holding only a stored reason tells them
  apart by `ownerNeedsYouReasons`, never by its own string match.
- `messages.needs_you_p` has ONE writer, `MessageStore.writeNeedsYouP`, with
  two callers: `applyDecision` and `NeedsYouHandler`'s copy step, which
  copies the `message_decisions.needs_you_p` COLUMN (never a recomputation
  from `answers_json`). The owner's answer lives in that column, so a third
  writer, or a copy that recomputes, silently undoes every press.
- `needsYouFromEarlierModel` reads an exact 0.0/1.0 with no current decision
  as an earlier model's verdict; the owner's override is written under
  `decisionQhash`, so it is decided-now, and every surface (Why panel,
  history, chip, Why line) words the owner's answer BEFORE it reads a
  percentage, so a press never shows as `0%`/`100%`.
- There is no DB stream: the rail and the pile follow
  `ConversationsNotifier.load()` (a press reloads once, after its sweep;
  progress reloads on `_scheduleReload`), and Home follows
  `ProgressTick`s. A new writer that changes what the list shows reloads it.
- Schema v23 appends `decision_labels.source_message_id`, `vector` (BLOB,
  float32 LE via `encodeEmbedding`) and `vector_model` for the needs-you
  labels; NULL on every storyline row. A label's vector is the decision
  model's RAW pooled vector (`DecisionResult.vector`, null on Kev), compared
  only under the same `vector_model` tag.
- Schema v24 appends `message_decisions.vector` (BLOB, float32 LE): every
  `writeDecision` stores `DecisionResult.vector` under the row's `model`
  tag, NULL on Kev, and `decisionFor` decodes it into `StoredDecision.vector`.
  When `applyDecision` overrides, `answers_json` also keeps the model's own
  p(yes) as `model_needs_you_p` (`decisionModelNeedsYouKey`), so a stored
  decision can be written again with the labels gone and the model's number
  comes back with no call. The needs-you pass decides a stored decision
  again when it has no vector under `DecisionClient.modelTag` (and the owner
  is known; a null tag owes nothing), and the sync one-shot
  `decision_vectors_backfill` (in `derivedOneShotPrefs`) requeues the pass
  for every kept inbound vectorless decision once, newest first, cap 2,000.
- The install-time re-decide (`TriageQueue.redecideStale`) runs the DECISION
  pass again for the last 30 days of kept inbound messages decided under
  another qhash (at most 2,000, newest first), writing only the decision row,
  the four triage fields, `needs_you_p`, the extraction's intent and
  importance, the thread's CTA fold and the chip, through `applyDecision`
  (`triage_queue.dart`), the ONE writer the claim, the re-decide and the
  needs-you pass's re-decide share. The mail sync starts it unawaited on the
  pref `decision_redecide_qhash`, whose value IS the qhash it finished for; a
  run is complete when it did not park. A 4xx message is SETTLED
  (`settleFailedDecision`: the current qhash plus a `redecide_failed` mark in
  `answers_json`, which `decisionFor` reads as no decision), so it leaves the
  stale list; a park or the processing switch leaves it owed. It asks nothing while triage is parked on the decision
  model, and logs a park once per qhash and reason per app run. Not in
  `derivedOneShotPrefs`: a clear re-triages everything.
- `message_decisions` is DERIVED (Clear AI results empties it; the triage
  pass writes it again), keyed by `(source, source_message_id)`. The four
  `*_p` columns are the probabilities read by hand; `answers_json` is every
  option's calibrated probability plus `owner_known` (and the owner's
  answer's scalar keys with `model_needs_you_p` on an override); `vector`
  (v24) is the decision model's vector of the message. A row decided WITHOUT an
  owner line (the keychain had not answered yet) has an untrusted
  `needs_you_p`: triage still writes it to `messages.needs_you_p` and it is
  SHOWN, every mail sync (and Retry owed stages) requeues the needs-you pass
  for it (`requeueOwnerlessNeedsYou`), and the pass decides the message again
  once the owner is known, keeping the p as it is while the owner is still
  unknown. A learned drop can
  carry an ingest word (`outbound`, a chat's `auto_generated`), so Clear AI
  results tells it from an ingest verdict by the `message_decisions` row
  (`clearDerived`'s `keptGate`, read before that table is emptied).
- An inbox-level widget test that builds a triage queue overrides
  `decisionClientProvider` with `keepingDecisionClient()`
  (`test/fixtures/fake_decision_client.dart`: keep, needs-you 0.5, over the
  slider's 0.35 default so a kept message reads as needing the owner). Without
  it the real client finds no heads
  file under `flutter test` and parks every message, which shows up as rows
  stuck at "triaging" or as RenderFlex overflows, not as a clear failure.
  `FakeDecisionClient`'s storyline `ask` answers `defaultYes` for any state no
  `yes(question, contains, p)` script matches, and `defaultYes` is 0.0, so an
  unscripted `member_of` files NOTHING: a storyline
  test that expects a filing scripts its yes (or builds
  `FakeDecisionClient.storyline(defaultYes: …)`).
- Generated drift schema files (`drift_schemas/bond/drift_schema_vN.json`,
  `test/drift/bond/generated/`) are never deleted or rewritten by hand from a
  session; the hook blocks it. Design around a schema bump you do not need:
  a new flag on an existing row can ride a JSON column (`owner_known` in
  `answers_json` is the example).

## Calendar (the calendar round, 2026-09)

`docs/pipeline/14-calendar.md` describes the whole feature. These are the rules
that bite.

- **The bond-mcps contract** (the handoff's §3–§5 win over any other doc):
  - `options` is a JSON object ENCODED AS A STRING. An empty string means
    absent. `manage_event` refuses unknown keys, and
    `create_calendar_event` silently ignores them, so spell `dry_run`
    exactly.
  - Key on `error`, never on `reason`. `not_connected` →
    `ReconsentRequired`. Unmapped Graph faults (429, 5xx) arrive as tool
    errors and mean retry later.
  - Event rows: timed events use `start_utc` / `end_utc`, all-day events use
    `start_date` / `end_date` (end exclusive). Never read the legacy
    `start` / `end` / `timezone`: they are naive, and on create they echo
    the request's zone.
  - `sync_calendar`:
    - the first call fixes the window and echoes it only then, so persist it
      yourself (the `calendar_run` pref);
    - loop while `complete == false`;
    - `cursor_expired` means a fresh run over the same window, then
      mark-and-sweep the whole table once `complete`;
    - sweep ONLY on an explicit `complete: true`
      (`CalendarSyncPage.explicitlyComplete`); a missing flag ends the loop
      but proves nothing;
    - ignore `removed` ids you never stored.
  - `manage_event.update` requires `if_match` (the stored `change_key`).
    Store the NEW key from the answer. `event_changed` means re-read.
  - On a write, `calendar_scope_missing` also answers a read-only calendar.
    The app writes only to the primary calendar, so treat it as a missing
    permission.
  - `body_preview` and OOO text are untrusted. Render them as text, never
    markup — the event panel's "From the invite" goes through `LinkedText`
    (http(s)/mailto only, the host's guarded launcher) so a Teams invite's
    "Join:" line is clickable; everything else plain `Text` — and pass them
    through `wrapUntrusted` before any model reads them.
- **Time (D13):**
  - Instants are stored as `isoStamp` UTC (`calendarStamp`, same width), so
    SQL string order is chronological. An all-day event is `yyyy-mm-dd` with
    an EXCLUSIVE end and is never converted through a zone.
  - The display zone is the OS zone (`flutter_timezone`, imported only by
    `calendar_zone.dart`, which `calendar_zone_import_test` pins), then the
    mailbox's `time_zone_iana`, then UTC.
  - Build dates from components (`CalendarZone.localDateTime`), never by
    adding a `Duration` across midnight.
  - `CalendarZone.utc().iana == 'Etc/UTC'`, so never compare against
    `'UTC'`.
  - `TZDateTime ==` compares the LOCATION too. Compare instants with
    `isAtSameMomentAs`, and hand plain UTC `DateTime`s across seams.
- **The store:**
  - `CalendarStore` (`data/calendar_store.dart`) is a separate class from
    `MessageStore`.
  - `calendar_events` is SYNCED (Clear AI results keeps it); `event_briefs`
    is DERIVED.
  - A mirror reader gates on `calendarShowsMirror(availability)`. The mirror
    is not cleared on a switch to SDK mode, so an ungated reader shows stale
    rows.
  - Calendar providers never read the clock. Their family arguments are
    dates or instants the HOST computes from `DateTime.now()` on each
    build, so nothing goes stale at midnight.
  - Graph's delta sends a plain occurrence as a stub (id, type, master id,
    times); `CalendarStore.fillFromMasters` runs on every sync page over the
    whole table and copies the stored master's details onto it. An
    occurrence's details are the master's by construction, so a new detail
    column on `CalendarEvent` must be added to the fill's hand-written column
    list or occurrences never carry it. `response_status` / `show_as` are
    the master's too (a series re-answered in Outlook follows on every
    occurrence), except for the page's `keepAnswerFor` ids, which the fill
    skips entirely so a fresh answer on one meeting survives until Graph
    sends it back as an exception.
  - A row written outside `CalendarSync` must carry the CURRENT run, or the
    next sweep deletes it. That is what `CalendarSync.storeWritten`
    (noteWrite + upsert tagged with the run, the write guard) is for.
  - A tick publishes itself: `CalendarSync.onOutcome`, wired in
    `calendarSyncProvider` as `calendarOutcomePublisher`, writes
    `calendarAvailabilityProvider` and bumps `calendarRevisionProvider`, so
    the forced sync after a write reaches the screen. The inbox only plans
    briefs off it. A test that overrides the sync with a recording subclass
    builds it in `overrideWith` and publishes through the same function
    (`calendar_poll_test`).
  - A forced `syncNow` during a tick queues ONE more forced tick behind it
    (`_forcedNext`); never let it join the running tick, whose pages may
    predate the write.
  - A notifier a closure bumps later is read ONCE at build and captured
    (`final revision = ref.read(….notifier)`), never read inside the closure,
    where a debug outdated-ref assert would drop the bump.
- **The write policy (D5 as built):**
  - Every write is a dry run first.
  - It waits on a confirm when the dry run emails anyone, and always for
    every RSVP, cancel and delete, and for any create with attendees.
  - Undo is offered only when a preview was shown, it emailed nobody, and
    the write is not itself an undo. The Undo is the app's one 5 s toast
    plus `z`, honoured by the host for twice that (`calendarUndoWindow`).
  - An Undo dry-runs first and is refused, with nothing sent, when that dry
    run lists anyone or the event's change key moved since the write it
    undoes (`_refuseUndo`).
  - A move's retry and a move's undo pin the `if_match` they were built
    against, so anything since becomes `event_changed`.
  - Once the server has accepted a write, every local step is best-effort,
    and the outcome never says "Nothing was changed". A real write's
    transient error retries only Create (its `transactionId`) and Move (its
    `if_match`).
  - `eventRoleOf` decides the role, and whose event it is comes first.
  - For a series master, RSVP, cancel and delete act on the whole series;
    move and propose act on the shown occurrence. A master is never moved.
    An Invites row answers the master only when it `answersSeries` (several
    plain occurrences owed); the command bar acts on the matched occurrence
    and says "· one meeting of a series".
  - A write that confirms by its kind but whose dry run named nobody says
    "This may email: …" from `mayEmailFor`; the toast says "Emails go to …"
    (a preview, never "Emailed").
- **Invitations (the clean-up round, 2026-10):**
  - A meeting message's time is never a deadline. ONE SQL reader,
    `MessageStore._meetingMessageSql(alias)` (a `json_valid`-guarded CASE,
    lower-cased `$.meeting` NOT IN ('', 'none') — Graph's enum has `none`),
    feeds the conversations query's `latest_deadline` and
    `latestInboundMeta`'s `deadline`; ONE Dart reader,
    `Message._meetingTypeOf`, feeds `meetingMessageType` and both factories,
    which read `deadline` as null for a meeting message. The extraction
    computes the deadline once for `writeMessageText`, `foldCtaUp` and the
    activity row. An invitation is never a Due row nor a deadline reminder.
  - A declined meeting is NOT drawn (agenda, grid, Today); a cancelled one is,
    struck through. `_applyLocally` marks the mirror declined at once, so a
    Dismiss or No leaves the agenda before the write returns.
  - Dismiss is `RespondToEvent(sendResponse: false)` (`quiet`): a bare
    decline — never a comment or a proposal (asserted in `_send`), emails
    nobody (`mayEmailFor` adds none), still waits on the strip (label
    'Dismiss'), activity `quiet: true`. `EventActions.dismissKey` shows only
    while `needsResponse`, in compact and full mode. No path rebuilds a
    `RespondToEvent` (retry reuses the object; `_undoFor` is null for an
    answer).
  - An unanswered meeting's agenda row carries the compact Yes / Maybe / No /
    Dismiss (`DayPane.meetingActions`, host-built like `inviteActions`) while
    the meeting has not ended; otherwise the 'RSVP owed' chip. After Yes the
    row stays and the buttons go; after Dismiss the row leaves. An attended
    meeting in a clash keeps its buttons only for a HARD clash or a soft one
    whose other side answered Maybe — never for an unanswered pencilled
    invite beside it (that invite is the side to settle, and has its own).
    The '⚠ overlaps' heading is `error` for a hard clash, `inkMuted` for a
    soft-only one (the grid's rule).
  - The answer belt: `CalendarSync.answerHold` (2 min). `guarded`,
    `keepAnswerFor` and `held` are read INSIDE the page transaction after
    `_checkRun`; `upsertEvents(keepAnswerFor:)` keeps the mirror's own
    ANSWER against any differing value the page carries (Accepted → Maybe is
    a main flow since the clash buttons; a page that still says `accepted`
    must not put it back), and a page that agrees is applied; `_applyLocally`
    notes the write BEFORE `setResponseStatus`. A test of a lagging page goes through
    `syncNow(force:)`, never `upsertEvents` alone.
- **Standing (the clean-up round, 2026-10):**
  - `standingOf(e)` (`services/calendar/event_standing.dart`, re-exported by
    `event_view.dart`) is the ONE reader of `responseStatus`, and of
    `showAs` for the tentative hold, for every face and for the overlap
    maths — never compare the strings elsewhere (the one other `showAs`
    read, `overlaps.dart` dropping `free`/`workingElsewhere` time, is about
    blocking, not standing). Order: cancelled → organizer (`isOwnersEvent`,
    which lives there now) → the ANSWER (`answerOf`: accepted / tentative /
    declined — **the answer wins over `showAs`**: Outlook pencils every new
    invite in as `showAs: tentative` and a fresh Yes only moves `show_as`
    on a later delta, so "accepted + shown tentative" is ACCEPTED, never a
    Maybe; the second live pass found every face calling a just-accepted
    meeting a Maybe for minutes) → unanswered (`needsResponse`) →
    `showAs: tentative` → noAnswerNeeded. **Unanswered wins over "shown
    tentative"** for the same reason. `setResponseStatus` also moves
    `show_as` the way Outlook records an answer (tentative → busy on Yes,
    → tentative on Maybe) and `keepAnswerFor` keeps the stored `show_as`
    with the kept answer. `isTentativeHold(e)` (a
    Maybe standing OR `showAs` tentative) is the soft-overlap predicate and
    `tentativeBlocks`' rule; a Maybe ANSWER is a soft overlap now.
  - The chosen (disabled) answer button follows the ANSWER (`answerOf`),
    not the standing. `responseLine` reads the standing; its seven strings
    are unchanged.
  - The palette is `widgets/event_standing_style.dart` (`toneOfStanding`,
    `standingBarColor`, `standingFillColor`): organizer/accepted/
    noAnswerNeeded → primary, Maybe → attention, unanswered/declined/
    cancelled → neutral (bar `inkMuted`). A hard clash turns a tile's bar the ERROR colour (not
    attention — that is Maybe's) and prefixes '⚠'; a soft one only the '⚠'.
    `theme/` never imports `services/`; the style file is in widgets for
    that reason.
  - Grid tiles overlap side by side through
    `MultiDayBodyConfiguration(eventLayoutStrategy:
    EventLayoutStrategy.sideBySide())` — the view factories do not take it.
  - The word is overlap or clash, never "conflict" (`CalendarEventChanged`,
    an etag rejection, owns that word).
- **The UI write path:**
  - `CalendarWriteFlow` is the ONE write state machine. The panel, cards,
    grid, command card and Find a time all go through it (or through
    `preview` / `commit` plus `WriteConfirmStrip`).
  - There are no date or time pickers. Typed times go through `resolveWhen`
    / `resolveNewTime`, and a grid drop through `checkDrop`.
  - Screen tests override `calendarWritesProvider` with a recording
    `CalendarWriter`.
  - A commit that fails after its flow unmounted goes to
    `CalendarWriteFlow.onFailed` (the host toasts it); a success still goes
    to `onDone`. The command card's `onDone` clears only its own command
    (the serial it was built with).
- **The grid (`kalender`):**
  - `kalender` is pinned EXACTLY at 0.32.0, because it is pre-1.0 and its
    minors rename API.
  - A drop is a PROPOSAL. Never call `updateEvent` in `onEventChanged`: the
    tile snaps back, and the store moves it after the write.
  - Tests unmount the view (`pumpWidget(SizedBox())`) BEFORE disposing the
    controllers.
  - Drag tests run under `TargetPlatformVariant` for both platforms:
    `flutter_test` is Android (a long-press drag), macOS a plain drag.
  - A create is a PROPOSAL too: kalender never adds a created event (that is
    the host's `onEventCreated` job, and this host never does), so
    `onCreateRequested` hands the span up and the host decides whether it is
    an ask's invite or a blank event. A bare tap comes through
    `onTappedWithDetail`, since neither create gesture is a tap.
  - kalender draws NO drag feedback unless `feedbackTileBuilder` /
    `dropTargetTile` are given; the resize detectors are bands at the
    tile's ends whose length is `ResizeHandleStyle.length` (shown only to a
    hovering mouse or a selected tile, so a resize test hovers first); a
    resize follows the pointer's column, so the grid refuses one that
    leaves the day (`DayGrid.staysOnOneDay`, `onRefused`). The landing day
    is read from the feedback's left edge.
  - The proposal tile is a kalender event of its own kind (named,
    adjustable, a tap flashes the card); a change on it re-proposes through
    the host (`onProposalChanged` → `_reproposeFromGrid`, through the drop's
    refusals), and nothing is stored — and never while the card writes
    (`onWritingChanged` → `_writingSerial`; `_cardWriting` is true only
    while the card that reported the write still stands, so a new card's
    grid is live), when a tap on it is ignored too (`onProposalTapped:
    null`).
  - ONE past rule: `_refusePast` ("That time has passed.", `pastRefusal`)
    is the first check of `_createFromGrid`, `_pickAskSlot` and
    `_reproposeFromGrid`, and every inbox `propose(...)` passes `now:` so
    the planner refuses it again as the belt. A grid test taps TOMORROW
    (or next week), never today: today's visible hours may already be past
    when the suite runs.
- **Work rows:**
  - `AiWorker.sources` (`email`, `teams`, `local`, `calendar`) is a CLAIM
    filter. A new kind queued under a new source is silently never claimed,
    and a "parks pending" test passes for the wrong reason. A handler test
    must PROVE the claim (the LLM double was called);
    `meeting_brief_handler_test` is the model.
- **Briefs:**
  - Two paths (`briefPathOf`, `brief_path.dart`, pure): `people` for ≤ 5
    others (`briefPeopleMax`) with no list address (`briefLooksLikeList`), or
    a topicless meeting (`briefIsTopicless`) of ≤ 15; else `related`. BOTH
    paths read mail AND Teams and search by meaning; the people path adds
    the senders and the date as a constraint (below). The
    four heuristics (list, `briefAgendaOf`'s boilerplate strip — a bare
    `Join: <link>` included — topicless, `briefIsLogisticsSubject`) are
    unmeasured and English only. Topicless sets aside PERSONS' name words
    only: a `type: resource` room or a list-address attendee is named after
    the subject ("Conf Room Falcon" keeps `Falcon weekly` topical); `status`,
    `update(s)`, `discussion`, `session`, `meet`, `follow(up)` are generic.
    The topicless test, `briefQueryText` and `briefIsLogisticsSubject` strip
    Re:/Fw: with the message card's own `stripReFw`
    (`conversation_state.dart`), never a regex of their own.
  - Threads: the event's own invite threads first (`messagesForEvent` for the
    occurrence, then its series master; ≤ 3, `BriefThread.invite`), then on
    the people path what its people WROTE (`_fromPeopleOf`, ONE
    `MessageStore.conversationsFromSenders`: kept inbound messages of the
    last 21 days, a mail by `from_address`, a Teams message by `from_name`
    = the invite's name, ASCII-case-insensitive — the name is the only link
    to a chat's `teams:<id>` people; ≤ 4 kept of ≤ 12 conversations, no
    floor), ordered BY MEANING when there is a query (`BriefInput.search`
    `ok`: `vec_distance_cosine` in SQL over just their messages' stored
    vectors, since vec0 cannot filter and theirs may sit outside the nearest
    400), else BY TIME, their newest message standing for the conversation
    (`recent` for a topicless meeting — no embed call at all — `off`,
    `unavailable`); then the 30-day address match (the mail they are only
    ON: the owner's unanswered thread to them), never bringing back what
    the first read found or dropped. Ordered by meaning the found threads
    lead and the address-matched only fill the room left (unread when there
    is none); ordered by time both sort together, pressing first then
    newest (an excerpt by its newest SHOWN message). `noMail` means no
    invite thread, nothing they wrote AND no address match, so a meeting
    whose only contact is a Teams chat is briefed. Found threads go through
    the same `_threadsOf` as the related path's (logistics and other
    invites dropped, a chat an EXCERPT, a mail the match + newest two). On
    the related path ≤ 4 (`maxRelated`) from ONE
    `MessageStore.relatedConversations` (a lean read of its own over ALL 400
    KNN neighbours at/above 0.60 `relatedFloor`, never `semanticSearch`'s
    nearest 100, so one busy chat cannot crowd the rest out; best message
    per conversation with its `messageId` and `receivedAt`, cosine = `1 −
    distance`, 21 days `briefRelatedWindow`, no attendee filter), invite
    keys and logistics (subject, or another event's `meetingEventId`)
    dropped, in score order; the related path never answers `noMail`. A
    related Teams chat is an EXCERPT (`BriefThread.excerpt`; a chat is one
    conversation whatever passes through it): `messagesBetween` ±24 h
    (`excerptSpan`) of the matched message, never `loadThread` — the match,
    then what followed (≤ 24 h), then to fill three (`relatedShown`) what
    came before (≤ 3 h, `excerptLead`); a bot post (`teamsBotGate`) is never
    quoted and takes no slot unless it IS the match;
    `lastAt`/`messageCount` are what is SHOWN, so later chatter moves no
    hash; never an open ask or waiting; a gone match skips the chat. A
    related mail thread quotes the match + its newest two (≤ 3, oldest
    first); three quoted cap at 400 (`relatedSnippetCap`), else 600 as
    invite and people-path threads. The query (`briefQueryText`) is
    embedded under `searchQueryPrefix`, cached per text in the gatherer, and
    a failed embed is not retried for 2 min (`embedRetryAfter`). Its hash
    adds `path|related` + `related|<ok|off|no_query|unavailable>` after the
    owner line; the people path adds no line (a search that comes back
    reorders its threads, and their lines are the hash). Tests script the
    searches by overriding `relatedConversations` and
    `conversationsFromSenders` (`_RelatedStore`). Materials (`BriefMaterial`) are the
    files on THIS MEETING'S OWN invite threads only (the occurrence's, then
    its series master's) — inbound and outbound, non-inline `file|reference`
    attachments that are not images (the owner's own: sender `you`). Files on
    the other chosen threads (address-matched or related) are
    `BriefInput.otherFiles`: names only
    (≤ 4, 80 chars as fenced), written under "Files on the other threads
    (NOT sent for this meeting)", and the prompt forbids reading
    the meeting's purpose from them (live lesson 2026-10-04: a test meeting
    with no attachment was briefed as a candidate review because the same
    person's earlier invites carried a resume). Materials are
    newest first, the newest copy per lowercased name, ≤ 6, each with its
    digest, its TEXT (`attachmentTextOf` for a `done` file, cut at a word
    to `materialTextCap` 6000, raw — the task fences it; `textCut` says it
    was cut) and ≤ 2 passages
    from ONE scoped `chunkKnn` (attachment ids, then the exact
    `(messageId, attachmentId)` pair). The planner gathers with
    `passages: false`, the LIGHT gather: no text, no people, no passage
    embedding (none of them hashed, so the hash is the same); only the
    handler reads them and embeds the meeting, once, lazily. The thread
    search (either path) runs in both gathers (it is hashed): one cached
    query embed per meeting text per run. The hash carries
    `material|msg|att|textStatus|digestStatus`, so a deck whose text or
    digest lands later re-briefs on the next pass.
  - People (`BriefPerson`, handler's gather only): the organiser first,
    then the attendees' order (a deliberate departure from D14), the cap
    ≤ `maxPeople` 8 after; on the RELATED path ONLY the others who WROTE a
    message in a kept thread (`_wrote`: a mail by address, a Teams message
    by the invite's name, case-insensitive — a roster alone is not
    writing), so nobody is listed to be told "nothing from them"; nobody
    wrote → no block. `peopleMore` = others − listed on both paths. The
    PEOPLE path lists everyone, and what a person wrote in a chat excerpt
    is theirs by the same name match; the With: line on the related
    path is organiser first too (`briefOthers` puts an attendee copy's
    organiser LAST), `briefOrgOf` (the label before
    the public suffix; the tenant for `*.onmicrosoft.com`, past a
    routing `mail` label; '' for a
    consumer domain or an IP), the answer only on the
    owner's own organiser copy ("response not known" elsewhere), their own
    last met, threads they are in, their newest inbound's `askOwnWords` cut
    at 240 and fenced `last_words`, their open ask. NOT hashed (`lastMet`
    moving alone never re-briefs). The typedef `briefOthers` returns is
    `BriefOther`. The meeting's own `lastMet` reads every other person on
    the people path and only the listed people on the related path (a
    500-person room must not bind an address each in `lastMetWith`).
  - Waiting for the files: `BriefInput.materialsPending` — a material
    `text_status == 'pending'` AND its `attachment_text` work row
    (`workRowOf`, entity `attachmentEntityId(msg, att)`) `pending` or
    `processing` AND being read for less than `BriefGatherer.pendingMaxAge`
    (2 h, from the later of the mail's `received_at` and the work row's
    `created_at`, so an old invite's freshly fetched file is waited for).
    There is NO `error` `text_status`: a text work row that gave up
    leaves the attachment row `pending` forever, so the work row is the
    rule. A `pending` file with no work row (`ensureBodiesFor` queues none)
    is `BriefEligible.unqueued`; the handler `queueText`s it once (INSERT OR
    IGNORE, `queued_text: n`) and waits on it (its reading starts now). The
    handler decides on the LIGHT gather (`passages: false`) and runs the full one
    only before a call. Pending AND no ready brief AND the start more than
    `MeetingBriefHandler.pendingGrace` (20 min) away AND nobody asked for
    it (`BriefRequest(asked: true)`, Regenerate, never waits): skipped
    `ineligible:materials_pending` through `_skip`, NO call; a ready brief
    is rewritten anyway, inside the grace it briefs with what is read. The
    planner queues that row when the hash moves, when the light gather
    says nothing is pending any more (once per stored row, `_endedFor`),
    and once more on the same hash inside the grace.
  - A chosen thread's mail with `has_attachments` and no `attachments` row
    (the owner's sent invite: its detail runs only on a thread open) is
    `BriefEligible.unlisted` (≤ 4). The handler's `fetchDetails` (the
    sync's `ensureMessageBody`, which lists the files AND queues their text;
    `ensureBodiesFor` queues none) runs ONCE through
    `MeetingBriefHandler.fetchEach` (one failed id costs only itself; the
    closure returns the count and never throws), then it gathers again
    whenever any fetch completed (`fetched: n`, the real count); a fetch
    that fetched nothing keeps the first gather. Never a loop.
  - The task is v3, evidence first, dense, second person ("you", never
    "the owner"): `evidence, headline (≤ 320), briefing[] (≤ 6 × 320),
    people[{name, line}] (≤ 8, line 220), materials[{file, points[]}] (≤ 4
    × ≤ 5 × 220), questions (≤ 5 × 220), open_asks, points (≤ 5 × 200),
    prep (≤ 3 × 120)`; `maxItems` only on `briefing`/`questions`/`prep`;
    headline and briefing cut at a word (`capAtWord`); 2700 tokens (the
    caps' sum / 4 within 1.2 × that, pinned); the first entry per file
    index wins. A
    material index outside the list is dropped, never -1. `brief_json`
    also carries `path` (`MeetingBrief.pathPeople`/`pathRelated`, pinned to
    `BriefPath.wire` by `brief_path_test`; missing or any other value reads
    `people`) and per-thread `invite` (written only when true); no schema
    change. The ok note adds `path`, `search` (the search's state word),
    `related` and `related_best` (cosine × 100, only when a search by
    meaning kept a thread, either path); the activity sentence appends ", found by
    subject" on the related path. `MeetingBrief`
    writes v3; v1 rows and v2 rows (a `takeaway` → one point) still decode,
    and `BriefMaterialOut.takeaway` (the points joined) is kept for old
    readers; the faces draw the points. There is NO people cap (no
    `too_many`; a big meeting takes the related path), so the `With:` fence
    lists at most `MeetingBriefTask.withCap` 15 names, then `+N more` outside
    it. The user message has a People
    block after `With:` (the fenced `name · org`, the org being a domain
    owner's words; "open ask: yes (see Open asks)", never the ask again;
    headed `People, numbered, the organiser first:` / tail `+N more` on the
    people path, `People who wrote in the threads below (mail or Teams
    chat), numbered:` / `+N more in the meeting who wrote nothing in these
    threads` on the related path); the thread list is headed `Threads with
    these people (mail and Teams chats), numbered:` or `Threads related to
    this meeting, numbered (found by their text, not by their people):`,
    and the prompt has a rule keyed on each heading; the prompt's opening
    says "recent mail and Teams chats", and a person the threads show
    nothing from gets "nothing from them in these threads" — never "no
    recent mail" (the `no_mail` skip's sentence is "no recent mail or Teams
    chats with these people", a different thing);
    every label (file names, thread and last subjects, the meeting's
    subject, storyline titles, attendee and people names) is capped at 120
    AS ESCAPED (`labelCap`, `_label`: the fence writes `&` as five). A
    chat excerpt's thread line is `[n] part of a Teams chat · the latest
    message shown is from <ago>` (no state, no urgent marker; there is no
    ` · Teams chat` marker), on either path; the excerpt sentence and "Trust
    the inputs in this order: …" are a rule of their own, after the two
    heading rules. The
    materials' digest + `material_text` + passages share `materialsBudget`
    10000, a block costing its length PLUS its digit count, in two rounds
    (`_spend`): digest then text (whole, else a word-cut head while > 1000
    is left), then passages only for a material whose text was not written
    whole and uncut (`!textCut`, never a length guess).
    `materialTextCharsWritten` runs the same spend for the activity row's
    `text_chars`. The size guard in `meeting_brief_task_test` holds a
    maximal prompt (every label 300 characters of `&<>`, four other files
    fenced at `otherFileNameCap` 80, the related header and rule, three
    invite threads of two 600s, three related threads of three 400s, 300
    attendees, the related people header and its three-digit tail) at ≤
    39760 characters (39363 measured, plus ~1%; 39120/39510 before the
    people block listed only who wrote, 38742/39120 before the chat excerpt, 38732 before the With: cap, 38133/38500 before
    the related path, 37012/37800 before the other-files
    block; the ceiling is (16384 − 2700) × 3.0 ≈ 41052). What the model
    is shown for a large meeting is readable in one file,
    `test/fixtures/briefs/large_meeting_prompt.txt`, pinned whole by
    `brief_prompt_fixture_test` (fixed `now`, every stamp derived from it);
    a deliberate prompt change regenerates it by hand from the text the
    failing test prints between its BEGIN/END lines. A material line
    puts `read|unread|not shown` OUTSIDE the fence (`read` only when a
    block was really written).
  - `BriefPlanner` runs after each `synced` tick the inbox ran (never the
    forced sync after a write); `_planBriefs` prints a pass of ≥ 100 ms as
    counts only. A READY brief (either path) younger than `rewriteAfter` (30
    min) is not rewritten when its hash moves; within `rewriteNear` (1 h) of
    the meeting the wait is `rewriteNearAfter` (5 min): the threads follow
    vectors landing behind the AI backlog, and a chat with an attendee
    moves with every line. Only delays; no brief, failed and skipped rows
    are untouched. A planner test of it
    stores a ready brief under an OLD hash with no pending work row, or a 0
    proves nothing. It skips an event only when its brief is
    fresh (< 2 h) AND the inputs hash is unchanged; `_queuedFor` (event id →
    last queued hash) stops a retry storm; it rechecks a `failed` row at
    most every 15 minutes in memory (a back-off). `ready` rows, rows with no
    brief (after Clear AI results) and `skipped` rows (any `ineligible:*`)
    are gathered on EVERY pass: a Gmail invite's event syncs seconds before
    its mail, and a deck's text landing should reach the brief at once.
    It writes skipped rows itself only for `recorded` = `no_mail`,
    `no_others`; a stale `ineligible:too_many` row is simply gathered and
    queued (its hash differs).
  - A failed or skipped run over a ready brief calls `touchBrief` (it moves
    only `generated_at`) — except a skip for `gone`, `declined` or
    `cancelled`, which replaces the brief with a skipped row.
  - Briefs are keyed by OCCURRENCE, never by master.
  - The box is today and tomorrow in the DISPLAY zone, one function:
    `briefHorizonEnd(nowUtc, zone)` (the local midnight that ends tomorrow;
    `too_far` is `!start.isBefore(end)`), read by the planner's window, the
    quick check and the panel. The host skips `_planBriefs` while no zone
    has resolved — never UTC's tomorrow. A brief lives until its meeting
    ENDS (`deleteBriefsOfEndedEvents`), not until it leaves the window, so a
    hand-asked brief for next week survives every pass. `asked`
    (`BriefRequest`, Regenerate and **Write a brief** `brief-write`) lifts
    the files wait, the unchanged hash, `too_far` and `no_mail` (the brief
    is then written from the invite and its people, "Threads: none.") —
    never `past`, `cancelled`, `declined` or `no_others`; the
    panel offers the button only where the quick check with `asked: true`
    is clear.
  - The agenda: `dayBriefsProvider(day)` watches the day's events and
    `briefRevisionProvider` (NOT `briefWorkTickProvider`) and holds READY
    briefs only; `dayBriefsWaitingProvider(day)` shares its one read and
    holds the `materials_pending` event ids (none while processing is off);
    `DayPane` draws the glance (`day-brief-teaser-$id`, three lines, not
    focusable) and the chevron (`day-brief-toggle-$id`, the one keyboard
    toggle), else a note in the glance slot (`day-brief-note-$id`, one
    line, no chevron, never once the meeting has started); the panel's
    pending sentence gives way to `eligible == false`'s reason; `BriefSection(compact:)` draws a READY brief's body,
    else only the `materials_pending` sentence (`statusKey`), else nothing;
    both faces draw ONE body in the catch-up order — Briefing
    (`brief-briefing`, one `SelectableText`), From the materials (chip
    `brief-material-$i`, points `brief-material-point-$i-$j` inside
    `brief-material-text-$i`), People (`brief-person-$i`, one `Text.rich`),
    Questions, Prep, Open asks, then the points under References (compact:
    at most `compactPointsCap` = 3), then the source caption
    (`brief-source`, `BriefSection.sourceText`: invite alone when every
    thread is the invite's own, on either path, else related / people) —
    the panel's above "Generated", the agenda's above Regenerate;
    the widget never reads
    `BriefMaterialOut.takeaway`; `_setSelectedDay` is the one writer of
    `_selectedDay` and clears `_expandedBriefs` only when the day changes;
    `_openMaterial` rebuilds the `AttachmentRef` from `attachmentRow` and
    toasts 'That file is no longer here.' on a missing row.
- **The Day command bar:**
  - The order is: Dart resolution, then the decision head, then the
    lexicon, then the generative model on Enter only (under the 0.8 bar, or
    a required slot unresolved with leftover words).
  - The model COPIES phrases and never computes a date. Every phrase must
    appear in the request on word boundaries (the literal guard) or it is
    dropped.
  - Never invent a time. A part of a day or a missing time is a choice of
    real slots, and a bare hour after "to" asks for am or pm.
  - `looksLikeCalendarCommand` gates the ⌘K Ask Day row, which is a dynamic
    row, never a `findCommands` entry.
- **The command head:**
  - `CommandHeads` is tied by `encoder_qhash` (the QUESTION set's hash) AND
    by `encoder_model` (the installed heads file's `model`). A mismatch is no
    head, never a wrong answer.
  - The asset `assets/calendar/command_heads.json` is ABSENT until the owner
    runs `make calendar-heads` and then, on `adoption: go`,
    `make calendar-heads-adopt`. The adoption line is printed, never
    asserted.
  - Fixture addresses use only the hygiene hook's fictional domains
    (contoso, fabrikam, northwind, `example.*`, `acme.example`). Other
    fictional companies are names only.
  - Screen tests override `commandHeadsProvider` with `noCommandHeads()`
    beside `keepingDecisionClient()` (`test/fixtures/fake_decision_client.dart`).
- **Find a time:**
  - `MessageStore.schedulingAskConversations` is the ONE scheduling-ask
    rule. Read it through `schedulingAskMessageIds` (what
    `schedulingAsksProvider` holds), never re-derive it.
  - `findMeetingTimes` REFUSES empty attendees (the server does too). A
    search for the owner alone uses `freeSlotsInRange`.
  - Windows are built from components (`findTimeWindowUtc`).
  - "Put in reply" writes through `_stage`, the composer's explicit seam.
  - The asks list is the Day column's `SCHEDULING ASKS · N` section
    (`SchedulingAskTile`, prop-driven; the inbox owns the searches in
    `_askSearches`); the agenda carries no asks group. A slot pick is the
    command proposal path (`_showProposal` → `_commandOutcome`), never a
    second confirm. `_proposal` (ONE `_Proposal?` record: the ask, its
    message id, whether it invites, blank, the typed name and chips) is the
    slot-pick / grid → card hand-off; `_forgetCommand` and a typed Enter
    null it in one place, and the card's onDone marks the ask before its
    serial guard. Three ways to a card: `_submitCommand` (typed text),
    `_reproposeCommand` (a slot pressed on the card, a ghost dragged — the
    card stays up through the dry run) and `_showProposal` (a column slot
    or a grid press; `keep: true` for an ask's ghost dragged, so its card,
    ghost and "Proposed:" line stay up too). Do not add a fourth body.
  - The `scheduling_ask` label is the owner's word on an ask, pinned to the
    newest inbound message id (source + id), so a later inbound message is
    judged afresh: `no` (an invite sent from it, or the ×) closes it; `yes`
    (the thread bar's Find a time, `reopenSchedulingAsk`, which deletes a
    `no` on that message first) lists it with or without a decision row.
    `schedulingAskConversations` is still the one rule; it reads both.
    `writeSchedulingAskLabel` stamps with the store's own `isoStamp` and
    returns `(id, createdAt)` for the undo. An invite labels the message
    read at the slot pick (`_Proposal.messageId`), never the newest at Send.
  - The thread bar's Find a time is on ANY thread with somebody to answer
    (newest message inbound, `_otherPeople` non-empty) while the calendar
    can be searched (`calendarShowsMirror` and the zone resolved, the
    column's own condition); a press goes to the
    Day stop with the ask open (`_toggleAsk`). The main-pane
    `FindTimePane` is gone; the column's row is the only Find a time
    surface.
  - Hints (`readAskHints`) are read from the ask's NEWEST inbound message,
    once per newest message (`_readAskHints`, one read in flight that every
    caller awaits; never started in a build); `theirs` is a window (the
    named day alone), and the words are read again on a new day too
    (`hintsDay`). `activity_domain` (Graph's `personal` is working hours
    plus the weekend): `unrestricted` when the hinted hours leave the
    working window; `personal` ONLY when the window IS the one hinted day
    (read from the window's days, never the pill) and it is non-working;
    `work` else — a window of several days stays `work` (a Sun–Thu
    mailbox's plain "This week" must not go `personal`). Decided once per
    search. With hours Graph is asked ONE CALL PER DAY of the window
    (`_hintedDays`; a single day is one call), each over that day's hours
    from the later of the window's start and the hours' opening, 5
    candidates, at most 7 days, a day with no room skipped — never one
    call over the window starting now; without hours, one call for 5.
    Counted in the `find_time` row's `graph_calls`
    (`FindTimeResult.graphCalls`). The `_insideHours` drop is a belt only.
  - Hints are read by the RULES at once (`readAskHints`) and by the model
    (`ask_read`, `AskReader.readFor`) when it answers. The model copies
    phrases that must appear in the subject and own words on word
    boundaries (`findPhrase`, `phrase_guard.dart`, shared with the command
    router) and a meal only when that meal's regex matches; Dart resolves
    each phrase on its own through ONE core (`_hintsFrom`), so the 34 rules
    tests in `ask_hints_test.dart` are the spec for both readers. Readings
    are stored as PHRASES (`ask_readings`, derived) and re-resolved against
    today. Several days (`AskHints.days`, `day` is the first) only widen the
    `theirs` window: one Graph call per day named, none between; the week
    pills keep the first day.
  - The inbox waits `InboxScreen.askReadWait` (4 s) for the model INSIDE
    the one read in flight, so every caller waits the same once; past it
    the first search runs on the rules and the reading refines later
    (`_AskSearch.refining`, nulled by `forgetReading`). A differing reading
    sets `hintsSource = 'model'`, re-seeds through `_seedFromHints` (the
    first search's own rule) and searches AT MOST once more per reading; a
    folded ask drops its answer instead. **The owner's pills win**: a pill
    press sets `pickedMinutes` / `pickedWindow` (kept by `forgetReading`,
    never set by seeding — `_changeAsk` no longer sets `searched`), and
    `_seedFromHints` leaves a picked field alone. **The model's "none"
    never erases the rules' day**: a reading with nothing in it against a
    rules reading that found something is kept as the rules', recorded
    `agree: false, applied: false`. `chooseAskHints(rules:, model:)` in
    `ask_hints.dart` IS that rule — the draft's slot step calls it, and the
    inbox's `kept` expression is the same rule (keep them equivalent). The
    `ask_read` verdict row is booleans only. Screen tests override `askReaderProvider` (the helper defaults to
    a disabled reader) and shorten the wait with
    `InboxScreen.askReadWaitOverride` (and the stale path with
    `askResultLifetimeOverride`), both cleared in `tearDown`; a held read
    left pending at the end fails the test on the timeout's timer.
  - The ask fixture (`test/fixtures/ask_reads/asks.jsonl`, 40 rows) is
    scored offline by `ask_read_fixture_test.dart`, which PRINTS the rules'
    score and asserts shape only; `expect` is a perfect reading, never the
    rules' output. `make ask-read-eval` is live (`@Skip`'d, `--run-skipped`)
    and never in the gate.
  - With a weekday read, a week pill means THAT weekday of the week
    (`weekdayWithin`, pills "This Fri" / "Next Fri", or the date they mean
    once this week's has gone), falling back to the
    rest of that week at the same hours under a note when the day offers
    nothing (never after `FindTimeResult.failed`).
  - The pane follows the search window: `_followAsk` moves the Day pane to
    the window's `firstDay` before every ask search, so a grid press lands
    on the day being searched. It sets `_selectedDay` ONLY (never
    `_selectDay`, which closes compose, Settings, the log, Invites and the
    selection), and only for an ask still open.
  - Stale rows: a row drops slots that have ended (`_liveResult`); ONE
    staleness on reopen (`_AskSearch.forgetReading`: a new day OR an answer
    older than `askResultLifetime` re-reads the words and searches again,
    the pills standing; `askWindowFor` turns a their-day with no day left
    into this week); a newer message is a NEW `_AskSearch` in `_askRow`
    (pills at defaults — never reset fields by hand); `_askRows` prunes
    searches whose ask left.
  - The `find_time` activity row carries `graph_calls`
    (`FindTimeResult.graphCalls`); the `scheduling_ask` row is labelled
    **Scheduling ask** in the log.
  - An empty Graph answer falls back to the owner's free times unless
    `empty_reason` is `attendeesunavailable`; `findTimeEmptyFallback` is the
    one rule.
  - A draft's times (`draft_slots.dart`) are appended by Dart after the
    model call — the model never sees the calendar, so the v4 prompt stands
    and a cloud target sees no slot. It reuses the column's helpers, never
    copies: `askWindowFor` (`find_time.dart`) and `otherAddresses` /
    `otherPeople` / `ownerAddressesOf` (`scheduling_ask.dart`, the inbox
    delegates). Only `suggested`, never-improved drafts are redrafted when
    their times go stale (`DraftSlotRefresher`, beside `_planBriefs`;
    `slotGone` is the one rule, also applied before a draft offers a slot);
    the delete is `deleteSuggestedDraft` (status checked in the DELETE) and
    the re-queue passes the old `workPayload` back — `requeueWork` with no
    payload over a done row clears it. The search never throws; an auth
    failure reaches the lane through `FindTimeResult.error`. The reading's
    call and the `find_time` row run in their own `inSpan`, or they would
    drain the draft row's tally.
- **Inbox widget tests** reach the real `McpCalendarBackend` through
  `calendarSyncProvider`, which fails fast and silently. To observe the sync,
  build a recording `CalendarSync` subclass INSIDE the test body
  (`calendar_poll_test.dart`): a Completer made in `setUp` never delivers
  under `tester.pump`.
- **Process in a worktree:**
  - The senior-review marker cannot be written from a worktree session, so
    record the verdict in the commit body.
  - Git nested in a compound command is refused; run each `git -C …` on its
    own.
  - The public-hygiene hook inspects STAGED content and blocks a whole
    compound command, so stage and commit as separate commands.
  - The commit hook only WARNS when the gate stamp is older than the staged
    files. Re-run the gate.

## Reminders (the calendar-automation round, 2026-10)

`docs/pipeline/15-reminders.md` describes the feature. The rules that bite:

- **The carrier is To Do, and it is dark until consent.** Every To Do call
  answers `tasks_scope_missing` (`TasksScopeMissing`) until the owner's
  consent round: that is UNAVAILABLE, never retried and never an error row.
  Every door reads `tasksAvailabilityProvider` first and, when it is not
  `available`, shows `tasksUnavailableSentence` and offers nothing to pick
  (while it is still loading the pills draw; a pick then meets the
  service's own precheck).
  Widget tests that make it available override BOTH `tasksBackendProvider`
  (a recording fake declared in the test, every method implemented) AND
  `tasksAvailabilityProvider` (`overrideWith((ref) async =>
  TasksAvailability.available)`); the default under `flutter test` is
  unavailable (`inbox_reminders_test.dart`).
- **The host computes every instant.** `ThreadActionBar` never reads the
  clock or the zone: the inbox builds its `ReminderPill`s
  (`remindChoices`, `services/reminders/remind_choices.dart`) and reads a
  typed time through `resolveRemindText` (the bar's callback returns a
  `ReminderPill?`, previewed by its label). The strip is Mark done's inline
  choices pattern (its own focus node taken as it opens, Escape, the
  `_choicesCap` height, one strip at a time); Remind me has NO key (`r` is
  Reply).
- **Bumps are the caller's.** The service bumps nothing (services never
  import providers): the inbox bumps `reminderRevisionProvider` after every
  `create` and `cancel`, and after a tend whose `reconcile()` or `plan()`
  returned > 0, reading the notifier ONCE before the awaits.
- **The poll's tend is single-flight** (`_tending`): `reconcile()` then
  `plan()` in one try off `_refresh`'s `finally`, everything caught and
  traced by type, skipped until the zone resolves. Reminders have no work
  kinds, so there is nothing to `requeueWork`.
- **Follow-up at send**: `DraftNotifier.lastEchoId` is the local echo id of
  the last mail reply sent (null otherwise); `_send` reads the choice before
  the await and creates the reminder RIGHT after `send` returns `sent`
  (anchor and Graph id = the echo id; the re-anchor is a 15-minute time
  match). A reminder toast passes `cleared: 0` so the pile's progress line
  is untouched; with reply-marks-done on, the follow-up is a line on the
  done toast and its Undo stays the done's.
