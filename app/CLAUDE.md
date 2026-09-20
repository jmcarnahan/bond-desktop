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
  (`processingProvider`, off at every launch). `AiWorker` and `TriageQueue`
  each take an `enabled` closure and read it on every launch decision, so a
  test that builds either one WITHOUT that argument is unaffected. Turning it
  off also calls `stop()` on all four drains.
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
- `completeJsonStreamed` is a SEPARATE method from `completeJson`: twenty-two
  test doubles extend `LlmClient` and override the latter's exact signature,
  so never add a named parameter to it. `runTask(onText:)` picks the path,
  only the draft call streams, and a streamed and a plain call of the same
  prompt must decode to the same object.
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
  `suggested` storyline needs `high`.
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
- A bearer is a SECRET. It belongs in the keychain under
  `llm_target_bearer:<id>`, in the notifier's cache, on the resolved
  `LlmTarget.bearer` and in the `Authorization` header, and nowhere else:
  never `app_prefs`, a `toString`, an `LlmCallRecord`, an exception message, a
  log line, an activity row or a draft row.
- Consent for a third-party target on `draft_reply` or `draft_improve` is
  enforced in `AppPrefs.specForStage` and in `applyPreset`, never on the
  screen alone.
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
