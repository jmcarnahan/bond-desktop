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
  preference and defaults ON. `AiWorker` and `TriageQueue` each take an
  `enabled` closure and read it on every launch decision, so a test that builds
  either one WITHOUT that argument is unaffected. Turning it off also calls
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
  (`draft` alone, at `AppPrefs.proseParallel` wide). Since the decision-model
  round every lane's chat calls go to the ONE generative model (drafts may go
  to Cloud drafts), so the lanes are an ORDER cut, not a server cut: a new
  handler goes on the lane whose ordering it needs, and order ACROSS lanes is
  enqueue-and-pump, not list position. Triage makes no chat call but still
  shares `fastDrainGateProvider` for the yield ticket, so a triage pump can wait
  behind a message-text call already in flight. A handler that must wake the drain it runs INSIDE is handed
  the worker through a `late final` local in the lane's body, never
  `ref.read` of that lane's own provider: Riverpod asserts self-dependency on
  a `read` as much as on a `watch`, so a debug build throws `A provider cannot
  depend on itself` out of the handler mid-drain.
- `requeueWork(refreshCreatedAt: true)` only where a person asked for the work
  NOW (Regenerate, Draft reply, the two Retries, Restore, a storyline action):
  the drain claims `created_at DESC`, so a bulk revive keeps its stamps rather
  than jumping the whole batch in front of new mail.
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
- The clustering card is ONE recipe (`clusteringCardForConversationRow` in
  `clustering_card.dart`, whose `ClusteringCardVariant` holds the seven cards
  and `shippedClusteringCard` names the one that ships, `topics`; `thread` and
  `topicsUntitled` are bench-only variants from the decision-model round,
  measured 58/98 against the shipped card's 59/98) behind
  `EmbeddingsClient.modelTag`; a tag bump orphans every stored
  conversation vector by construction, so it ships with a one-shot re-embed
  in `sync_service.dart` (Round A's pref idiom).
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
- The sweep groups by COSINE: `StorylineTuning.groupingMode =
  GroupingMode.cosine` ships (with the model charter check and `member_of`
  confirms), and it is the one reader of `clusterLinkThreshold`,
  `clusterCoherenceFloor` and the split ladder. `GroupingMode.decision` is the
  BENCH ARM (`SWEEP_GROUPING=decision`; the Makefile and
  `GoldenDefines.sweepGroupingRaw` both default to cosine): it did not beat
  cosine on the v3 golden sweep (57/98 at best against 60/98), because
  `same_effort`'s p on the golden pool is compressed near zero, so its
  `linkTau` (0.008) and `pairBudgetPerPass` (400) stay PROVISIONAL. A test
  about it passes `groupingMode: GroupingMode.decision` and writes any p that
  a MEAN is compared on through `onLinkScale` (`fake_decision_client.dart`,
  the 0.5-centred scale moved onto `linkTau`'s); a plain no is 0.0, never
  0.05, which clears a 0.008 bar. Under it cosine only proposes candidate pairs
  (each pool thread's top `StorylinePolicy.pairNeighbours` at
  `pairRetrievalFloor`, plus every pair sharing a series key), the decision
  model's `same_effort` judges them, and `clusterByAverageLinkage` forms the
  clusters at `linkTau` — an optimistic round over the answered pairs, then
  each cluster COMPLETED (its unasked internal pairs asked) and judged again
  on the full matrix, or deferred when the budget cannot complete it — and
  drops outliers before naming. The golden sweep's keep-all loop runs on
  while a quiet pass deferred clusters (`sweepLoopContinues`, up to
  `sweepDeferredPassCap` 8), because the golden pool's ~570 candidate pairs
  overrun one pass's budget. The answers are cached in `pair_decisions` (v23, DERIVED) under both
  thread texts' `cardHash` and, in the `qhash` column, `decidedBy` =
  `'<qhash>|<model identity>'`
  (`DecisionClient.modelIdentity`, so a swapped or re-installed model re-asks;
  a test's fake answers `fake-model`), pruned at each decision pass by AGE
  only (30 days; reads filter on `decidedBy`, so both backends' caches
  survive a role switch), at most `pairBudgetPerPass` new pairs a
  pass, written per batch only after the batch returns. The namer
  (`NameStorylineTask`) only WRITES — no `coherent`/`outliers` — and
  `StorylineTuning.charterCheck` (`CharterCheck.model`: `charter_specific` at
  `charterSpecificTau`; `CharterCheck.lint`: the regex, `SWEEP_CHARTER=lint`)
  files a refused cluster `possible`. `maxQuestionsPerPass` counts NAMING calls
  only. `GroupThreadsTask`, the `storyline_group` stage and the `model`/`pool`
  modes are gone. `ensureReady` runs before the first pair, and
  `StorylineJudge.beginPass()` at the sweep's top makes each thread's body
  fetch at most once a pass (it forgets successes only; the five-minute
  failure memo survives passes). Storyline service tests answer `same_effort`
  (under the decision arm) through `sweepJudge` (`storyline_service_test.dart`: from the seeded vectors
  at the file's own `sweepJudgeLinkCosine`, unless the test scripts it) or
  `sameEffortAmong`/`sameEffortBy` (`fake_decision_client.dart`), and
  `charter_specific` with `{'p': …}` like `member_of`.
- The storyline service is four files now and one public face: the user
  actions in `storyline_edits.dart` (`StorylineEdits`), the clustering in
  `storyline_grouper.dart` (`StorylineGrouper`), the shared card statics in
  `storyline_cards.dart`, and `storyline_service.dart` keeping one-line
  delegates so its twenty-two importers, six in `lib` and sixteen in `test`, did
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
  something (`AiWorker.lastDrainCount`), and it defers above three floors read
  from ONE `pipelinePulse`; the sync-time `requeueSweep()` is the durable
  trigger.
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
  `$BOND_BOX_URL/decide/v1/embeddings`); the generative remote is four wide
  only while it follows the build, one for a stored address. A test asserting
  where a stage resolves says which placement it means, since
  `boxUrlDefault` is empty under `flutter test`. The writers are
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
- What the managed router serves is `managedManifestProvider`
  (`ModelManifest.forRoles`): embed, plus `bond-decide` while the decision
  role is on this Mac, plus the chosen generative model while that role is
  (`managedGenerativeIdFor`: full tier → 27B, inbox → 4B, a stored 27B on the
  inbox tier falls back to the 4B). The supervisor's `buildPreset` serves only
  `withPresentFiles(folder)`, because the server refuses a preset with a
  missing file and one absent model must not cost the others, and records the
  served ids with `setServedManagedIds`; `AppPrefs.unavailableFor(spec)` then
  puts a sentence on `LlmTarget.unavailable` for a managed target the router
  does not serve, and `LlmClient` and `DecisionClient` throw on it before any
  HTTP, so only that role parks (`not_installed`). `machineTierProvider` still
  answers what this Mac could hold. The decide entry is `source: local` (repo
  `local/bond-decide`, no download): the downloader and the ledger skip it,
  and it is installed when the GGUF AND the heads file are both in the folder.
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
  (`settings-role-check-decision`: `ensurePreset()` and refresh the status,
  which is how a `make decide-install` done while the app runs is picked up;
  the heads are re-read by the client when the file's mtime moves), and
  `settings-generative-status` with the 27B | 4B pick
  `settings-generative-managed` (the 27B disabled on the inbox tier). Also
  `settings-models-status`, `settings-models-progress`, `settings-show-log`,
  `settings-set-up-again` and `settings-idle-models`. Your server renders
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
  `SettingsHost` wires `onUseDecision`, `onUseGenerative`, `onCheckDecision`
  and `onRemoveKey` (null takes a control off), and every role write is
  followed by `supervisor.ensurePreset()`, which restarts the router only when
  the preset hash changed. The Advanced fold, the stage picker, the targets
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
  source-local decide entry by folder, file and heads (`DECIDE_DIR`,
  `DECIDE_FILE`, `DECIDE_QUANT` f16, `DECIDE_HEADS`) and by its server args
  (`DECIDE_ARGS`: pooling, `-c`, `-ub`, `-b`, `-np` against the preset);
  `CTX_SIZE`, `MODEL_CTX`, `SLOTS`, `FAST_SLOTS`, the embed `--pooling` word
  and the prose spec type. One blind spot remains: the recipes launch the
  servers from `MODEL_FLAGS` and `FAST_FLAGS`, so a literal written into those
  in place of `$(CTX_SIZE)` drifts past every assertion the test makes.
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
- The heads file (`decide-heads.json`, installed beside the GGUF under
  `<models>/local_bond-decide/` by `make decide-install`) is needed on THIS
  Mac for the encoder-heads kind even when its server is remote: the heads, temperatures and
  softmax run in Dart. It is SCHEMA 2 with 12 `questions`: the nine message
  fields (renderer `message`, `decisionFields` order), then `same_effort`
  (`pair`), `member_of` (`membership`) and `charter_specific` (`charter`),
  each `yes`/`no`. `apply` answers the nine; `pYes(question, vector)` answers
  one storyline question. `decisionHeadsProvider` re-reads it when its mtime
  moves and refuses a file whose `qhash` is not `decisionQhash`
  (`'f495a7dc48aa34d5'`, `decision_questions.dart`, the one place it is
  named). A schema-1 file (the older model) throws
  `DecisionOlderModelException` (in `llm_client.dart`, so `parkReasonFor`
  can name it), park `decision_older_model`, with `DecisionHeads.olderModelText`
  in plain words and no command; Settings adds a quieter `For developers:
  make decide-install` line. A missing file parks the decision pass. Tests
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
  default 0.35) is the only control; every reader goes through it; no
  language model is asked about needs-you, and the attention score only
  orders. A THREAD's p is the MAX over its kept inbound messages after its
  last outbound (all kept inbound when it has none), not the newest one's, so
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
  the storyline's title and charter at the press. Written ONLY by
  `StorylineEdits` at an owner press (Keep and Dismiss of a suggestion or
  possible row, add, remove, a charter written — Allow again writes none,
  lifting a veto is not a yes), never by an automatic pass; Clear AI results keeps it and `wipeAll` deletes it.
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
  option's calibrated probability plus `owner_known`. A row decided WITHOUT an
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
  unscripted `member_of` or `same_effort` files and links NOTHING: a storyline
  test that expects a filing scripts its yes (or builds
  `FakeDecisionClient.storyline(defaultYes: …)`).
- Generated drift schema files (`drift_schemas/bond/drift_schema_vN.json`,
  `test/drift/bond/generated/`) are never deleted or rewritten by hand from a
  session; the hook blocks it. Design around a schema bump you do not need:
  a new flag on an existing row can ride a JSON column (`owner_known` in
  `answers_json` is the example).
