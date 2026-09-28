import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/decision/decision_heads_file.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/decision_heads_fixture.dart';
import 'fixtures/memory_token_store.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// The decision client as the app wires it: the target resolved through the
/// prefs at request time, the heads off this Mac's disk.
///
/// A plain `test`, because the heads are a real file in a real folder. No
/// request is made: nothing calls `decide` until the classification cutover,
/// and what this pins is the wiring — which server the client would dial,
/// with which key, and that a missing heads file parks rather than fails.
void main() {
  late BondDatabase db;
  late Directory support;

  setUp(() async {
    db = testDb();
    support = await Directory.systemTemp.createTemp('decision-provider');
  });

  tearDown(() async {
    await db.close();
    await support.delete(recursive: true);
  });

  final manifest = testManifest(withDecide: true);
  final decide = manifest.byRole(ModelRole.decide);
  String headsPath() =>
      p.join(support.path, 'models', decide.headsRelativePath!);

  ProviderContainer containerFor(AppPrefs prefs, {MemoryTokenStore? tokens}) {
    final made = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      appPathsProvider.overrideWithValue(AppPaths(support)),
      modelManifestProvider.overrideWithValue(manifest),
      appPrefsProvider.overrideWith(
        (ref) => AppPrefsNotifier(
          MessageStore(db),
          initial: prefs,
          tokens: tokens ?? MemoryTokenStore(),
        ),
      ),
    ]);
    addTearDown(made.dispose);
    return made;
  }

  test('on this Mac it dials the managed router under bond-decide', () async {
    final container = containerFor(const AppPrefs());
    await container.read(appPrefsProvider.notifier).ready;

    final target = container.read(decisionClientProvider).target;

    expect(target.baseUrl, 'http://127.0.0.1:8080/v1/embeddings');
    expect(target.model, routerDecideId);
    expect(target.bearer, isNull);
  });

  test('on your server it dials that address with the decision key', () async {
    const key = 'sk-fixture-not-a-real-decide-token';
    final container = containerFor(
      const AppPrefs(
        decisionPlacement: ModelPlacement.box,
        decisionUrl: 'https://box.example.com/decide/v1/embeddings',
      ),
      tokens: MemoryTokenStore({'$llmTargetBearerKeyPrefix$boxDecideId': key}),
    );
    await container.read(appPrefsProvider.notifier).ready;

    final target = container.read(decisionClientProvider).target;

    expect(target.baseUrl, 'https://box.example.com/decide/v1/embeddings');
    expect(target.model, boxDecideModel);
    expect(target.bearer, key);
    expect(target.toString(), isNot(contains('sk-fixture')));
  });

  test('a prefs write moves the client without rebuilding it', () async {
    final container = containerFor(const AppPrefs());
    final notifier = container.read(appPrefsProvider.notifier);
    await notifier.ready;
    final client = container.read(decisionClientProvider);

    await notifier.useDecision(
      placement: ModelPlacement.box,
      url: 'https://box.example.com/decide/v1/embeddings',
    );

    expect(identical(container.read(decisionClientProvider), client), isTrue);
    expect(client.target.baseUrl,
        'https://box.example.com/decide/v1/embeddings');
  });

  test('without the heads file it throws the not-installed park', () async {
    final container = containerFor(const AppPrefs());
    final heads = container.read(decisionHeadsProvider);

    expect(
      heads.current,
      throwsA(isA<DecisionUnavailableException>().having(
        (e) => e.message,
        'message',
        DecisionHeadsFile.notInstalledText,
      )),
    );
    expect(DecisionHeadsFile.notInstalledText, contains('make decide-install'));
    expect(DecisionHeadsFile.notInstalledText, isNot(contains('—')));
  });

  test('the heads load from the models folder once, and again when the file '
      'changes', () async {
    final container = containerFor(const AppPrefs());
    final file = File(headsPath());
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(syntheticHeadsJson()));

    final heads = container.read(decisionHeadsProvider);
    final first = heads.current();
    expect(first.model, 'bond-decide-synthetic');
    // Cached: the same object while the file is unchanged.
    expect(identical(heads.current(), first), isTrue);

    // A re-install (a newer modification time) is read again.
    await file.writeAsString(jsonEncode(syntheticHeadsJson()));
    await file.setLastModified(DateTime.now().add(const Duration(minutes: 1)));
    expect(identical(heads.current(), first), isFalse);
  });

  test('a models folder moved in the prefs is followed', () async {
    final container = containerFor(const AppPrefs());
    final elsewhere = p.join(support.path, 'elsewhere');
    final file = File(p.join(elsewhere, decide.headsRelativePath!));
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(syntheticHeadsJson()));
    final heads = container.read(decisionHeadsProvider);

    expect(heads.current, throwsA(isA<DecisionUnavailableException>()));

    await container.read(appPrefsProvider.notifier).setModelsFolder(elsewhere);
    expect(heads.current().model, 'bond-decide-synthetic');
  });
}
