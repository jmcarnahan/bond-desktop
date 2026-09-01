// dart format width=80
// ignore_for_file: unused_local_variable, unused_import
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:bond_inbox/data/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'generated/schema.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = BondDatabase(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  test('v1 to v2 remaps the category taxonomy and adds messages.label',
      () async {
    // Seed a v1 database through the raw connection — the rows have to exist
    // BEFORE BondDatabase opens it, or there is nothing for the step to remap.
    final schema = await verifier.schemaAt(1);
    schema.rawDatabase.execute("""
      INSERT INTO messages (source, source_message_id, conversation_key,
        direction, category, created_at, updated_at)
      VALUES
        ('email', 'm-borrower', 'c1', 'inbound', 'borrower', 't', 't'),
        ('email', 'm-underwriting', 'c1', 'inbound', 'underwriting', 't', 't'),
        ('email', 'm-lead', 'c1', 'inbound', 'lead', 't', 't'),
        ('email', 'm-personal', 'c1', 'inbound', 'personal', 't', 't'),
        ('email', 'm-other', 'c1', 'inbound', 'other', 't', 't'),
        ('email', 'm-untriaged', 'c1', 'inbound', NULL, 't', 't');
    """);
    schema.rawDatabase.execute("""
      INSERT INTO conversations (source, conversation_key, category,
        created_at, updated_at)
      VALUES
        ('email', 'c-realtor', 'realtor_partner', 't', 't'),
        ('email', 'c-personal', 'personal', 't', 't'),
        ('email', 'c-untriaged', NULL, 't', 't');
    """);

    final db = BondDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 2);
    addTearDown(db.close);

    // `personal` and `other` carry over, every old work bucket becomes
    // `work`, and never-triaged rows stay NULL rather than gaining a claim.
    Future<Map<String, String?>> categoriesOf(
        String table, String keyColumn) async {
      final rows = await db
          .customSelect('SELECT $keyColumn AS k, category FROM $table')
          .get();
      return {
        for (final row in rows)
          row.data['k'] as String: row.data['category'] as String?,
      };
    }

    expect(await categoriesOf('messages', 'source_message_id'), {
      'm-borrower': 'work',
      'm-underwriting': 'work',
      'm-lead': 'work',
      'm-personal': 'personal',
      'm-other': 'other',
      'm-untriaged': null,
    });
    expect(await categoriesOf('conversations', 'conversation_key'), {
      'c-realtor': 'work',
      'c-personal': 'personal',
      'c-untriaged': null,
    });

    // The new column exists, reads NULL on migrated rows, and takes a write.
    await db.customStatement(
        "UPDATE messages SET label = 'dinner plans' WHERE source_message_id = 'm-personal'");
    final labels = await db
        .customSelect(
            "SELECT source_message_id AS k, label FROM messages WHERE source_message_id IN ('m-personal', 'm-other')")
        .get();
    expect(
      {for (final r in labels) r.data['k'] as String: r.data['label'] as String?},
      {'m-personal': 'dinner plans', 'm-other': null},
    );
  });
}
