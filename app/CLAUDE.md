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
   pattern); never widen a frozen step.
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
- Seven `@Skip`'d live harnesses (`test/llm_*_live_test.dart`,
  `llm_target_verify_test.dart`) sit in every run as skipped; they never get
  accuracy thresholds (`docs/model-bakeoff.md`).
- Narrow scope while iterating (`flutter test test/<file>`); the full gate
  (`.claude/hooks/gate.sh <label>`) before review and commit.

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
- Prefer narrow SQL statements over widening a `copyWith`; `payload_json` is
  NULL on requeue — never plumb provenance through it.
