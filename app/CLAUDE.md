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

## Tests

- Flat files: `test/<subject>_test.dart`; in-memory Drift via `testDb()` →
  `BondDatabase.memory()`; ALWAYS `await db.close()` in tearDown.
- Screen tests NEVER `pumpAndSettle` on `InboxScreen` (a 60 s periodic timer
  and no-looping-animation rule): three bare `tester.pump()` calls is the
  idiom; `pump(Duration(milliseconds: 400))` for scoring passes.
- Read pills and rows BY LABEL, never by count.
- Eight `@Skip`'d live harnesses (`test/llm_*_live_test.dart`,
  `llm_target_verify_test.dart`) sit in every run as skipped; they never get
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
  `reply`, `gates`, `sweep`) or it runs under that target too.
- A live bench prints counts, ms, ratios and enum words only, never a subject,
  title, charter, slug, participant or thread key. That is
  `SweepTally.table()`'s rule, and it holds because the golden storylines are
  named out of real mail.
- `make golden-vector` is the sweep test under `SWEEP_STAGE=vector`: the same
  body and the same seeding as `golden-sweep`, stopped after the embedding,
  one embed server and no model call. A new live STAGE goes inside the
  existing test body under a define, never as a second test name.
  `SWEEP_STAGE=declared` and `make golden-declared` are the same shape again.
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
- A bench runs from a DETACHED checkout whenever a later phase is editing the
  main one: `git worktree add --detach ~/projects/bond-desktop-bench <commit>`,
  copy the gitignored machine files in, `flutter pub get` in its `app/`, then
  `make -C` that checkout with `GOLDEN`, `GOLDEN_REGISTRY`, `GOLDEN_RUN` and
  `BENCH_OUT` pointed back at the main one. It compiles the committed tree, its
  build directory is its own so narrow tests cannot race it over the native
  assets, and its results still land in the main `tmp/bench`. A wall taken this
  way while the main checkout is busy is under load, and the row says so.
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

## Working rules

- Tool calls leave the shell inside `app/`: use absolute paths or `make
  app-analyze` / `make app-test` from the repo root.
- Never `dart format` a tracked file (it once rewrote `inbox_screen.dart`);
  gates are analyze + test only.
- `unnecessary_import` fires when one file imports both a re-exporting library
  and the library it re-exports. The fix is `show` on the wider import, naming
  what that file actually uses, never dropping the narrower one.
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
  (`draft` alone, at `AppPrefs.proseParallel` wide). A new handler goes on the
  lane whose server it calls, and order ACROSS lanes is enqueue-and-pump, not
  list position.
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
- The clustering card is ONE recipe (`clusteringCardForConversationRow` in
  `clustering_card.dart`, whose `ClusteringCardVariant` holds the five cards
  and `shippedClusteringCard` names the one that ships) behind
  `EmbeddingsClient.modelTag`; a tag bump orphans every stored
  conversation vector by construction, so it ships with a one-shot re-embed
  in `sync_service.dart` (Round A's pref idiom).
- `_accepts` in `storyline_service.dart` is the one membership rule at all
  five confirm sites (assign, recruit, sweep member, probe, audit), and a
  `suggested` storyline needs `high`. It and `_confirm` stayed in the service
  through the split, because one rule at five sites is not a seam.
- The storyline service is four files now and one public face: the user
  actions in `storyline_edits.dart` (`StorylineEdits`), the clustering in
  `storyline_grouper.dart` (`StorylineGrouper`), the shared card statics in
  `storyline_cards.dart`, and `storyline_service.dart` keeping one-line
  delegates so its twenty-two importers, six in `lib` and sixteen in `test`, did
  not change. A new pass goes in the file whose job it is, and the service gets
  a delegate only if callers outside already reach for it.
- ONE THREAD, ONE LIVE STORYLINE. `recruit`'s candidate walk excludes the
  sweep's `assignedOrBlockedKeys` set, read once per lap, so a declared
  storyline cannot take a thread another storyline already holds. Measured:
  before the rule, 41 of 57 recruited threads on the declared bench had landed
  in more than one storyline. The cost is that a contested thread goes to the
  first storyline to ask rather than the best match.
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
- Stages resolve their client through `stageLlmClientProvider(stageId)`, whose
  resolver reads `ref.read(appPrefsProvider.notifier).targetForStage(stageId)`
  at request time. Nothing in `lib/` watches `appPrefsProvider` for a target,
  so a prefs write rebuilds no worker, and `llm_routing_test` pins all four
  queues identical across a `setStageTarget`. A null `LlmTarget.wire` means
  the client's own wire; `toTarget` stamps only Converse.
- Stages resolve through the PLACEMENT as well as the stage map, and the
  placement is a RULE rather than stored rows. One pref, `box_url` ('' meaning
  the compiled `BOND_BOX_URL`), is the whole address; `AppPrefs.boxProseSpec`
  and `boxBulkSpec` are DERIVED from it and never stored, which is why
  `LlmTargetSpec.isBox` exists, why `isFixed = isBuiltIn || isBox` guards the
  editors, and why `_targets()` drops the two box ids at load. The stage map's
  default is `placementDefaultTargetId`: the six prose stages plus
  `storyline_membership` on `box-prose`, the other seven bulk stages on
  `box-bulk`, whenever the placement is box and an address exists, and the
  slot's built-in otherwise. `targetIdForStage` is a stored override that
  resolves, else that default. `usePlacement(p, hardwareTier:)` is the one door
  between placements: it drops the entries the app itself writes and keeps user
  `t-…` picks and the optional stage's entry. `useBox` is `setBoxUrl` plus
  `setBoxKey` (one token under BOTH keychain ids) plus `usePlacement(box)`. The
  one-shot `box_targets_derived` migration lifts Round G's stored pair. A test
  asserting where a stage resolves says which placement it means
  (`AppPrefs(modelPlacement: box, boxUrl: 'https://box.example.com')`, since
  `boxUrlDefault` is empty under `flutter test`), and the effective manifest
  tier is `effectiveTierProvider` (`remote` on the box) rather than
  `machineTierProvider`, which still answers what this Mac could run.
- `storyline_membership` is the ONE stage whose role depends on the placement,
  big on the box and small here, and `placementDefaultTargetId` is where that
  lives. `setStageTarget` and `applyPreset` compare against the PLACEMENT
  default, so picking `box-bulk` for it on the box stores an entry and picking
  `box-prose` clears one; `applyTierDefaults` keeps the SLOT default because it
  runs only on the local placement.
- The Models page is ONE question with everything else folded away.
  `SettingsModelsSimple` (`widgets/settings_models_simple.dart`) carries the
  keys `settings-placement`, `settings-use-local`, `settings-models-status`,
  `settings-models-advanced` and `settings-role-check-<big|small|embed>`.
  `SetupWhereBody` is the ONE box form, rendered by the wizard's Where step and
  by that page, with the keys `setup-box-url`, `setup-box-key` and
  `setup-box-check`; it OWNS the address rule (`isBoxOrigin`, the same rule
  `setBoxUrl` throws on) and refuses a bad address under the field rather than
  letting either host throw past a fire-and-forget press. The Advanced fold's
  body is `SettingsModelsBody`, so a test reaching a stage picker or a slot
  editor through `SettingsScreen` opens the fold first
  (`SettingsSection.toggleKey('Advanced')`). `RoleLine.fromPrefs` groups a
  role's steps by `defaultTargetIdForStage` and describes the modal target.
- Under `flutter test` `hardwareInfoProvider` answers `HardwareInfo.unknown` at
  its two-second timeout, so a real inbox in a widget test never offers **Reset
  per-step picks** (the unreadable-memory branch hides it by design) and the
  tier is `AsyncLoading` for the first two seconds. A test that presses it
  overrides `hardwareInfoProvider` with a readable machine and pumps past two
  seconds in bounded steps.
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
- Consent for a third-party target on `draft_reply` or `draft_improve` is
  enforced in `AppPrefs.specForStage` and in `applyPreset`, never on the
  screen alone.
- THIRD PARTY means Bedrock and the three model vendors, not AWS.
  `isThirdPartyHost` lives in `app/lib/services/llm/model_slots.dart`, beside
  `LlmTargetSpec`, and is true for a host under `anthropic.com`, `openai.com`
  or `deepseek.com`, and for a Bedrock runtime host, meaning one starting
  `bedrock` and ending `.amazonaws.com`. The owner's own inference box under a
  Route 53 name or an EC2 public name is the owner's machine and needs no
  drafts consent; `LlmTargetSpec.isThirdParty` still ORs the Converse wire, so
  a Converse target is third party wherever it lives.
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
- `draft_improve` is the one `PipelineStageInfo.optional` row: a routing
  destination with no schema of its own, so it runs `DraftTask` and its call
  record is labelled `draft_reply`. `model_slots_test` pins the exempt set
  literally.
- The machine tier is `MachineTier` in `model_slots.dart`, chosen from
  `hw.memsize` by `machineTierFor` and never persisted, so a models folder
  carried to another Mac is re-read on the Mac it is on. It is applied twice,
  by the wizard at Finish and by **Use this Mac's defaults**, and unknown
  memory resolves to `full` because unknown never refuses.
- The manifest and the Makefile are two worlds joined by
  `manifest_makefile_parity_test.dart`, so a change to any of them edits both
  or fails the test: the three repos, the quant either from a `:quant` suffix
  or from the repo name having to carry the manifest file's own quant token,
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
