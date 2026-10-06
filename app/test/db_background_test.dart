import 'dart:io';
import 'dart:math' as math;

import 'package:bond_inbox/data/conversation_vec_index.dart';
import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
// drift exports an `isNull` and an `isNotNull` of its own, which would shadow
// the matchers.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart' show SqliteException;
import 'package:drift/isolate.dart' show DriftRemoteException;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

/// A unit vector in the plane spanned by dimensions `2 * plane` and
/// `2 * plane + 1`, zero everywhere else — the same geometry
/// `conversation_vec_index_test.dart` seeds with.
List<double> ray(int plane, double radians) {
  final v = List<double>.filled(ConversationVectorIndex.dims, 0.0);
  v[plane * 2] = math.cos(radians);
  v[plane * 2 + 1] = math.sin(radians);
  return v;
}

/// The app's database on its background isolate, through the same
/// [appExecutor] `openAppDb` uses. Every case here is a plain `test()`: a real
/// isolate and a real file must never be awaited inside a widget test's
/// fake-async zone.
void main() {
  // The native asset is expected to be here; the guard exists so a build
  // without code assets reports a skip rather than confusing failures.
  late bool available;
  late Directory tmp;
  late String path;
  final opened = <BondDatabase>[];

  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    available = ensureSqliteVecLoaded();
    if (!available) {
      printOnFailure('sqlite-vec native asset missing — vec cases skipped');
    }
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bond-db-bg-');
    path = p.join(tmp.path, 'bg.db');
  });

  // Closing a background database also ends its isolate.
  tearDown(() async {
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
    tmp.deleteSync(recursive: true);
  });

  BondDatabase background() {
    final db = BondDatabase(
      appExecutor(path, onUiIsolate: false, perfLog: false),
    );
    opened.add(db);
    return db;
  }

  Future<String?> pref(BondDatabase db, String key) async {
    final rows = await db.customSelect(
      'SELECT value FROM app_prefs WHERE "key" = ?1',
      variables: [Variable<String>(key)],
    ).get();
    return rows.isEmpty ? null : rows.single.data['value'] as String;
  }

  Future<void> setPref(BondDatabase db, String key, String value) =>
      db.customInsert(
        'INSERT INTO app_prefs("key", value) VALUES (?1, ?2)',
        variables: [Variable<String>(key), Variable<String>(value)],
      );

  test('creates the schema at the current version', () async {
    final db = background();
    final version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, db.schemaVersion);
    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'messages'",
        )
        .get();
    expect(tables, hasLength(1));
  });

  // Both pragmas are set in `beforeOpen`, which drift runs on THIS isolate and
  // whose statements it sends to the background connection.
  test('runs in WAL mode with foreign keys on', () async {
    final db = background();
    final mode = await db.customSelect('PRAGMA journal_mode').getSingle();
    expect(mode.data.values.single, 'wal');
    final keys = await db.customSelect('PRAGMA foreign_keys').getSingle();
    expect(keys.data.values.single, 1);
  });

  // The upgrade path every existing install takes after a schema bump: the
  // step closures run on this isolate, inside a transaction, and each of
  // their statements crosses to the background connection. The file is made
  // at the current shape and stamped one version back, so the newest step
  // replays — every step is a no-op on a replay by the house rule
  // `db_adoption_test` holds.
  test('an upgrade runs its steps across the isolate boundary', () async {
    final seed = BondDatabase.open(path);
    final current = seed.schemaVersion;
    await seed.customSelect('SELECT 1').get();
    await seed.customStatement('PRAGMA user_version = ${current - 1}');
    await seed.close();

    final db = background();
    final version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, current);
    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'messages'",
        )
        .get();
    expect(tables, hasLength(1));
  });

  // What this pins is that the connection opened on the background isolate
  // knows `vec0`. It cannot pin that `isolateSetup` ran: `setUpAll` registered
  // the extension process-wide, as `openAppDb` does, and that alone reaches
  // the background connection. The registration inside the isolate is
  // insurance against the order changing, which no in-process test can see.
  test('the background connection knows vec0', () async {
    if (!available) return;
    final db = background();
    final v = await db.customSelect('SELECT vec_version() AS v').getSingle();
    expect(v.data['v'], isA<String>());
    expect(v.data['v'] as String, isNotEmpty);
  });

  test('a vec0 round trip through the store', () async {
    if (!available) return;
    final db = background();
    final store = MessageStore(db);
    final first = encodeEmbedding(ray(0, 0));
    await store.upsertConversationAi(
      'email',
      'thread-ada',
      embedding: first,
      embeddedHash: 'h-ada',
      embedModel: EmbeddingsClient.modelTag,
    );
    await store.upsertConversationAi(
      'email',
      'thread-example',
      embedding: encodeEmbedding(ray(0, 1.0)),
      embeddedHash: 'h-example',
      embedModel: EmbeddingsClient.modelTag,
    );

    expect(
      await store.prepareConversationIndex(
        embedModel: EmbeddingsClient.modelTag,
      ),
      2,
    );
    final near = await store.conversationNeighbors(first, k: 2);
    expect(near, hasLength(2));
    expect(near.first.key, 'thread-ada');
  });

  test('nested transactions commit, and a throwing one rolls back', () async {
    final db = background();
    await db.transaction(() async {
      await setPref(db, 'outer', 'o');
      await db.transaction(() async {
        await setPref(db, 'inner', 'i');
      });
    });
    expect(await pref(db, 'outer'), 'o');
    expect(await pref(db, 'inner'), 'i');

    await expectLater(
      db.transaction(() async {
        await setPref(db, 'doomed', 'd');
        throw StateError('boom');
      }),
      throwsA(isA<StateError>()),
    );
    expect(await pref(db, 'doomed'), isNull);
  });

  test('a constraint failure surfaces as an exception', () async {
    final db = background();
    const insert =
        'INSERT INTO app_prefs("key", value) VALUES (\'dup\', \'v\')';
    await db.customStatement(insert);
    Object? caught;
    try {
      await db.customStatement(insert);
    } catch (e) {
      caught = e;
    }
    // The TYPE is the thing to know: an error from the background connection
    // arrives wrapped, so an `on SqliteException` written against the app's
    // database would never fire. Its text is still the cause's.
    expect(caught, isA<DriftRemoteException>());
    expect(
      (caught! as DriftRemoteException).remoteCause,
      isA<SqliteException>(),
    );
    expect(
      caught.toString(),
      anyOf(contains('UNIQUE'), contains('constraint')),
    );
  });

  test('what the background connection wrote is on disk', () async {
    final db = background();
    await setPref(db, 'persisted', 'yes');
    await db.close();
    opened.remove(db);

    final again = BondDatabase.open(path);
    opened.add(again);
    expect(await pref(again, 'persisted'), 'yes');
  });

  test('the UI-isolate executor with the perf log also opens', () async {
    final db = BondDatabase(
      appExecutor(path, onUiIsolate: true, perfLog: true),
    );
    opened.add(db);
    final one = await db.customSelect('SELECT 1 AS v').getSingle();
    expect(one.data['v'], 1);
  });

  // What `make app-profile BOND_PERF_LOG=1` runs: the interceptor around the
  // background connection.
  test('the background executor with the perf log reads, writes and closes',
      () async {
    final db = BondDatabase(
      appExecutor(path, onUiIsolate: false, perfLog: true),
    );
    opened.add(db);
    await db.transaction(() async {
      await setPref(db, 'logged', 'yes');
    });
    expect(await pref(db, 'logged'), 'yes');
  });
}
