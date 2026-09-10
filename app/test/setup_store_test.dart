import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/setup_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

void main() {
  late BondDatabase db;
  late SetupStore store;

  setUp(() {
    db = testDb();
    store = SetupStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('a key that was never written is null', () async {
    expect(await store.get('models_downloaded'), isNull);
  });

  test('set writes, and writes again over itself', () async {
    await store.set('step', 'welcome');
    expect(await store.get('step'), 'welcome');

    await store.set('step', 'models');
    expect(await store.get('step'), 'models');
    // An upsert, not a delete-then-insert: the first-run flow polls this
    // table while a download writes to it, and a reader must never see the
    // key missing.
    expect(await store.all(), {'step': 'models'});
  });

  test('remove takes one key and leaves the rest', () async {
    await store.set('step', 'models');
    await store.set(SetupStore.containerMigrationKey, '{"migrated":true}');

    await store.remove('step');

    expect(await store.get('step'), isNull);
    expect(
      await store.get(SetupStore.containerMigrationKey),
      '{"migrated":true}',
    );
  });

  test('removing a key that is not there is not an error', () async {
    await store.remove('never written');
    expect(await store.all(), isEmpty);
  });

  test('all reads every row, by key', () async {
    await store.set('zebra', '1');
    await store.set('alpha', '2');
    await store.set('middle', '3');

    expect(await store.all(), {'alpha': '2', 'middle': '3', 'zebra': '1'});
    expect((await store.all()).keys.toList(), ['alpha', 'middle', 'zebra']);
  });

  test('clearExcept keeps what is expensive and still true', () async {
    await store.set('step', 'done');
    await store.set('models_downloaded', '["bond-embed","bond-bulk"]');
    await store.set(SetupStore.containerMigrationKey, '{"migrated":true}');

    // "Set up again" must not throw away the models on disk or the fact that
    // the container was already brought across.
    await store.clearExcept({
      'models_downloaded',
      SetupStore.containerMigrationKey,
    });

    expect(await store.all(), {
      SetupStore.containerMigrationKey: '{"migrated":true}',
      'models_downloaded': '["bond-embed","bond-bulk"]',
    });
  });

  test('clearExcept with nothing kept empties the table', () async {
    await store.set('step', 'done');
    await store.set('models_downloaded', '[]');

    await store.clearExcept(const {});

    expect(await store.all(), isEmpty);
  });

  test('a value is opaque to the store', () async {
    // JSON where a caller needs structure; the store neither parses nor
    // validates it.
    const payload = '{"copied":["bond_inbox.db"],"migrated":true}';
    await store.set(SetupStore.containerMigrationKey, payload);
    expect(await store.get(SetupStore.containerMigrationKey), payload);
  });
}
