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

  test('v2 to v3 adds storyline charter columns', () async {
    final schema = await verifier.schemaAt(2);
    schema.rawDatabase.execute("""
      INSERT INTO storylines (id, title, status, created_by, title_locked,
        pinned, created_at, updated_at)
      VALUES ('sl-1', 'Tahoe trip', 'active', 'user', 1, 0, 't', 't');
    """);

    final db = BondDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 3);
    addTearDown(db.close);

    // An existing storyline has no charter and nobody has edited one, which is
    // what the confirm task's summary fallback is for.
    Future<Map<String, Object?>> charterOf() async => (await db
            .customSelect(
                'SELECT charter, charter_locked FROM storylines WHERE id = ?',
                variables: [Variable('sl-1')])
            .getSingle())
        .data;

    final migrated = await charterOf();
    // `null` rather than `isNull`: drift exports an `isNull` of its own into
    // this file, and the two names collide.
    expect(migrated['charter'], null);
    expect(migrated['charter_locked'], 0);

    await db.customStatement(
        "UPDATE storylines SET charter = 'Planning the Tahoe trip.', "
        "charter_locked = 1 WHERE id = 'sl-1'");
    final edited = await charterOf();
    expect(edited['charter'], 'Planning the Tahoe trip.');
    expect(edited['charter_locked'], 1);
  });

  test('v3 to v4 adds draft option columns and keeps the draft', () async {
    final schema = await verifier.schemaAt(3);
    schema.rawDatabase.execute("""
      INSERT INTO drafts (source, conversation_key, reply_to_message_id, body,
        evidence, status, created_at, updated_at)
      VALUES ('email', 'c1', 'm-1', 'Sounds good — Friday works.',
        'They asked which day suits.', 'suggested', 't', 't');
    """);

    final db = BondDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 4);
    addTearDown(db.close);

    Future<Map<String, Object?>> draftRow() async => (await db
            .customSelect(
                'SELECT body, options_json, options_dismissed FROM drafts '
                'WHERE conversation_key = ?',
                variables: [Variable('c1')])
            .getSingle())
        .data;

    // A draft written before the options existed keeps its long form and
    // reads as "no suggestions, none dismissed" — the state a thread the model
    // has not revisited is supposed to be in.
    final migrated = await draftRow();
    expect(migrated['body'], 'Sounds good — Friday works.');
    expect(migrated['options_json'], null);
    expect(migrated['options_dismissed'], 0);

    await db.customStatement(
        'UPDATE drafts SET options_json = ?, options_dismissed = 1 '
        'WHERE conversation_key = ?',
        [r'[{"stance":"Confirm Friday","body":"Friday works."}]', 'c1']);
    final written = await draftRow();
    expect(
      written['options_json'],
      r'[{"stance":"Confirm Friday","body":"Friday works."}]',
    );
    expect(written['options_dismissed'], 1);
  });

  test('v4 to v5 adds the triage v2 columns and keeps the message', () async {
    final schema = await verifier.schemaAt(4);
    schema.rawDatabase.execute("""
      INSERT INTO messages (source, source_message_id, conversation_key,
        direction, subject, triage_status, created_at, updated_at)
      VALUES ('email', 'm-1', 'c1', 'inbound', 'Closing Friday', 'triaged',
        't', 't');
    """);

    final db = BondDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 5);
    addTearDown(db.close);

    final row = (await db
            .customSelect(
                'SELECT subject, addressed_me, reply_expected, deadline '
                'FROM messages WHERE source_message_id = ?',
                variables: [Variable('m-1')])
            .getSingle())
        .data;

    expect(row['subject'], 'Closing Friday');
    // A message stored before triage v2 existed was addressed to nobody in
    // particular as far as this app can tell, and carries no judgement at all
    // — `reply_expected` NULL is what `rejudgeStaleTriage` looks for, and it
    // must never arrive as a 0 that reads like a decided "no".
    expect(row['addressed_me'], 0);
    expect(row['reply_expected'], null);
    expect(row['deadline'], null);
  });

  test('v5 to v6 adds message_notify empty and leaves the backlog alone',
      () async {
    final schema = await verifier.schemaAt(5);
    schema.rawDatabase.execute("""
      INSERT INTO messages (source, source_message_id, conversation_key,
        direction, subject, triage_status, created_at, updated_at)
      VALUES ('email', 'm-1', 'c1', 'inbound', 'Closing Friday', 'triaged',
        't', 't');
    """);

    final db = BondDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 6);
    addTearDown(db.close);

    // The step creates the table and nothing else: an upgrade must not admit
    // the mail that was already sitting there, or the first launch after the
    // update announces the whole backlog.
    final pending = await db
        .customSelect('SELECT COUNT(*) AS c FROM message_notify')
        .getSingle();
    expect(pending.data['c'], 0);

    final subject = await db
        .customSelect('SELECT subject FROM messages WHERE source_message_id = ?',
            variables: [Variable('m-1')])
        .getSingle();
    expect(subject.data['subject'], 'Closing Friday');

    final indexes = (await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
            .get())
        .map((r) => r.data['name'])
        .toSet();
    expect(indexes, containsAll(['ix_message_notify_open', 'ix_messages_created']));
  });

  test('v6 to v7 backfills cluster_hash on auto-created storylines only',
      () async {
    final schema = await verifier.schemaAt(6);
    schema.rawDatabase.execute("""
      INSERT INTO storylines (id, title, status, created_by, title_locked,
        charter_locked, pinned, member_hash, created_at, updated_at)
      VALUES
        ('sl-auto', 'Website redesign', 'dismissed', 'auto', 0, 0, 0, 'h-auto',
          't', 't'),
        ('sl-user', 'Tahoe trip', 'active', 'user', 1, 0, 0, 'h-user', 't', 't'),
        ('sl-unhashed', 'Untitled', 'active', 'auto', 0, 0, 0, NULL, 't', 't');
    """);

    final db = BondDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 7);
    addTearDown(db.close);

    // Both hashes per row, so the backfill is pinned to READ member_hash and
    // to leave it alone — copying one column must not cost the other.
    Future<Map<String, List<Object?>>> hashesOf() async {
      final rows = await db
          .customSelect('SELECT id, member_hash, cluster_hash FROM storylines')
          .get();
      return {
        for (final row in rows)
          row.data['id'] as String: [
            row.data['member_hash'],
            row.data['cluster_hash'],
          ],
      };
    }

    // An auto-created row's `member_hash` started life as the cluster's hash,
    // so copying it forward is the closest thing to the truth that exists on
    // disk — and it is exactly the value the dismissal check used before this
    // column. A row a person made was never proposed out of a cluster, so it
    // gets nothing; `null` rather than `isNull`, which drift exports into this
    // file under the same name.
    expect(await hashesOf(), {
      'sl-auto': ['h-auto', 'h-auto'],
      'sl-user': ['h-user', null],
      'sl-unhashed': [null, null],
    });

    // The dismissal check reads the backfilled value on the arm that matters.
    final found = await db
        .customSelect(
            "SELECT 1 FROM storylines WHERE status = 'dismissed' "
            'AND (cluster_hash = ? OR member_hash = ?) LIMIT 1',
            variables: [Variable('h-auto'), Variable('h-auto')])
        .get();
    expect(found, hasLength(1));

    // And the column takes a write, which a STRICT table would reject if the
    // step had declared it as anything but TEXT.
    await db.customStatement(
        "UPDATE storylines SET cluster_hash = 'c-user' WHERE id = 'sl-user'");
    expect((await hashesOf())['sl-user'], ['h-user', 'c-user']);
  });
}
