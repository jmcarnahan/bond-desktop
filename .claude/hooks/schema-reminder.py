#!/usr/bin/env python3
"""PostToolUse (Edit|Write) on schema.drift / database.dart: the schema-change
sequence arrives at the moment it matters instead of being copied into plans."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hooklib import hooks_off, read_input  # noqa: E402

SEQUENCE = (
    "schema-change sequence (hook reminder): "
    "1) new columns go AFTER existing ones in app/lib/data/schema.drift (STRICT tables, append-only; "
    "indexes as customStatement('CREATE INDEX IF NOT EXISTS …'); never a vec0/FTS virtual table in a migration or beforeOpen); "
    "2) bump `schemaVersion` in app/lib/data/database.dart and add a guarded `fromXToY` step (_columnExists pattern); "
    "3) from the repo root run `make app-migrations` (both drift_dev commands — the second restores the no-data-class snapshots) "
    "then `make app-gen`; "
    "4) stage and commit drift_schemas/bond/drift_schema_vN.json, test/drift/bond/generated/schema_vN.dart, "
    "database.g.dart and database.steps.dart with the change (generated output is committed; test/drift/bond/migration_test.dart covers every version pair). "
    "The commit hook checks all of this."
)


def main():
    data = read_input()
    if hooks_off():
        return
    path = (data.get("tool_input", {}) or {}).get("file_path", "") or ""
    norm = path.replace(os.sep, "/")
    if norm.endswith("/lib/data/schema.drift") or norm.endswith("/lib/data/database.dart"):
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": SEQUENCE}}))


if __name__ == "__main__":
    main()
