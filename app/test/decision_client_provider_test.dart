import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/data/setup_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/decision/decision_client.dart'
    show DecisionServerKind;
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_input.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/decision/decision_state.dart'
    show decisionRendererVersion;
import 'package:bond_inbox/services/decision/decision_heads_file.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:bond_inbox/services/system/system_info.dart' show HardwareInfo;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'fixtures/current_ledger.dart';
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

  /// The rest of what makes the registry entry's heads readable
  /// (`DownloadLedger.servable`): its GGUF beside them in [folder] and both
  /// download rows current, written through the container's own store, the
  /// one the heads reader asks.
  Future<void> installDecide(ProviderContainer container,
      {String? folder}) async {
    final gguf = File(p.join(
        folder ?? p.join(support.path, 'models'), decide.relativePath));
    await gguf.parent.create(recursive: true);
    await gguf.writeAsString('gguf');
    await container
        .read(setupStoreProvider)
        .recordDownload(currentLedgerFor([decide]));
  }

  ProviderContainer containerFor(
    AppPrefs prefs, {
    MemoryTokenStore? tokens,
    http.Client? httpClient,
    ModelManifest? which,
  }) {
    final made = ProviderContainer(overrides: [
      if (httpClient != null)
        decisionHttpClientProvider.overrideWithValue(httpClient),
      dbProvider.overrideWithValue(db),
      appPathsProvider.overrideWithValue(AppPaths(support)),
      modelManifestProvider.overrideWithValue(which ?? manifest),
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

  // The model ensurer's set (D10): what the placements serve here, plus the
  // decision model whenever the manifest has one. These replace the old
  // `DECIDE_DIR=` folder cases: nothing tells anybody where to copy the
  // decision model any more, the app downloads it.
  Future<Set<String>> ensureIds(AppPrefs prefs) async {
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      appPathsProvider.overrideWithValue(AppPaths(support)),
      modelManifestProvider.overrideWithValue(manifest),
      appPrefsProvider.overrideWith(
        (ref) => AppPrefsNotifier(
          MessageStore(db),
          initial: prefs,
          tokens: MemoryTokenStore(),
        ),
      ),
      // A full Mac, answered at once: the tier is what the set is cut from.
      hardwareInfoProvider.overrideWith((ref) async => const HardwareInfo(
            chip: 'Apple M2 Max',
            memoryBytes: 64 * 1024 * 1024 * 1024,
            appleSilicon: true,
            rosetta: false,
            osVersion: '15.6',
          )),
    ]);
    addTearDown(container.dispose);
    final set = await container.read(modelEnsureSetProvider.future);
    return {for (final model in set.models) model.id};
  }

  test('the ensure set holds the decision model when it runs on Your server, '
      'and no generative model while that runs there too', () async {
    final ids = await ensureIds(const AppPrefs(
      decisionPlacement: ModelPlacement.box,
      decisionUrl: 'https://box.example.com/decide/v1/embeddings',
      modelPlacement: ModelPlacement.box,
      boxBigUrl: 'https://box.example.com/prose/v1/chat/completions',
    ));
    // A ModernBERT server still reads this Mac's heads file, and the entry is
    // one download: decide is ensured although the router does not serve it.
    expect(ids, {routerEmbedId, routerDecideId});
    expect(ids, isNot(contains(routerProseId)));
    expect(ids, isNot(contains(routerBulkId)));
  });

  test('the ensure set on this Mac is what the router serves: embed, decide '
      'and the chosen generative model', () async {
    final local = await ensureIds(const AppPrefs(
      modelPlacement: ModelPlacement.local,
    ));
    expect(local, {routerEmbedId, routerDecideId, routerProseId});

    // Your server with no address still demands no local generative model.
    final noAddress = await ensureIds(const AppPrefs(
      modelPlacement: ModelPlacement.box,
    ));
    expect(noAddress, {routerEmbedId, routerDecideId});
  });

  test('under hand-started servers the ensure set is the embedding model and '
      'the decision model, both served from the models folder', () async {
    // `make embed` and `make decide` serve their files from the app's models
    // folder (the embedding model no longer comes from the Hugging Face
    // cache), and the heads file is read there too, so the app fills it. No
    // generative model: the hand-started 27B is `make model`'s own.
    final ids = await ensureIds(const AppPrefs(
      managedServer: false,
      modelPlacement: ModelPlacement.local,
    ));
    expect(ids, {routerEmbedId, routerDecideId});
  });

  test('the heads file is read from the registry entry\'s folder', () async {
    final path = p.join(support.path, 'models',
        'artifactory_bond-decide-mbl-v3swap', 'decide-heads.json');
    expect(headsPath(), path);
    final container = containerFor(const AppPrefs());
    final heads = container.read(decisionHeadsProvider);
    expect(heads.current, throwsA(anything), reason: 'nothing there yet');
    await File(path).create(recursive: true);
    await File(path).writeAsString(jsonEncode(syntheticHeadsJson()));
    await installDecide(container);
    expect(heads.current().model, 'bond-decide-synthetic');
  });

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

  group('which kind the wiring asks for', () {
    const kevUrl = 'https://box.example.com/decide/v1/systemone';
    late List<http.Request> seen;

    /// A Kev wrapper: its listing carries the question hash, and every ask
    /// is answered with each option's share.
    MockClient kev() => MockClient((request) async {
          seen.add(request);
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'models': [
                  {
                    'name': 'bond-decide-kev4b-fixture',
                    'qhash': decisionQhash,
                    'renderer': decisionRendererVersion,
                  },
                ],
              }),
              200,
            );
          }
          final questions = (jsonDecode(request.body)
              as Map<String, dynamic>)['questions'] as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'answers': {
                for (final MapEntry(:key, :value) in questions.entries)
                  key: {
                    'type': 'choice',
                    'probabilities': {
                      for (final o in ((value as Map)['criteria'] as Map).keys)
                        o: 1 / (value['criteria'] as Map).length,
                    },
                  },
              },
            }),
            200,
          );
        });

    final input = DecisionInput(
      owner: 'Rivera, Sam <sam.rivera@example.org>',
      source: 'email',
      fromName: 'Dana Whitfield',
      fromAddress: 'dana@example.com',
      subject: 'Venue list',
      receivedAt: '2026-09-15T17:05:00Z',
      bodyText: 'Could you send the list?',
      addressedMe: true,
      toCount: 1,
    );

    setUp(() => seen = []);

    test('a box-decide spec on a Kev server asks the kind, then systemone, '
        'with no heads file on this Mac', () async {
      final container = containerFor(
        const AppPrefs(
          decisionPlacement: ModelPlacement.box,
          decisionUrl: kevUrl,
          decisionModel: 'bond-decide-kev4b-fixture',
        ),
        httpClient: kev(),
      );
      await container.read(appPrefsProvider.notifier).ready;
      final client = container.read(decisionClientProvider);

      final result = await client.decide(input);

      expect(seen.map((r) => '${r.method} ${r.url.path}'), [
        'GET /decide/v1/models',
        'POST /decide/v1/systemone',
      ]);
      expect(result.model, 'bond-decide-kev4b-fixture');
      expect(client.kindOf(url: kevUrl, model: 'bond-decide-kev4b-fixture'),
          DecisionServerKind.systemOne);
    });

    test('a managed spec never asks /v1/models', () async {
      final file = File(headsPath());
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(syntheticHeadsJson()));
      final container = containerFor(const AppPrefs(), httpClient: kev());
      await container.read(appPrefsProvider.notifier).ready;

      // Whether the router serves it or not, the managed target is the
      // encoder, so no listing is ever asked for.
      await container
          .read(decisionClientProvider)
          .decide(input)
          .then<void>((_) {}, onError: (_) {});

      expect(seen.where((r) => r.method == 'GET'), isEmpty);
      expect(seen.where((r) => r.url.path.endsWith('/v1/systemone')), isEmpty);
    });
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
      throwsA(isA<DecisionNotInstalledException>()
          .having((e) => parkReasonFor(e), 'park word',
              'decision_not_installed')
          .having(
            (e) => e.message,
            'message',
            DecisionHeadsFile.notInstalledText,
          )),
    );
    expect(DecisionHeadsFile.notInstalledText,
        'The decision model is not downloaded yet. Open Settings, Models.');
    expect(DecisionHeadsFile.notInstalledText, isNot(contains('make')));
    expect(DecisionHeadsFile.notInstalledText, isNot(contains('—')));
  });

  test('the heads load from the models folder once, and again when the file '
      'changes', () async {
    final container = containerFor(const AppPrefs());
    final file = File(headsPath());
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(syntheticHeadsJson()));
    await installDecide(container);

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
    await installDecide(container, folder: elsewhere);
    final heads = container.read(decisionHeadsProvider);

    expect(heads.current, throwsA(isA<DecisionUnavailableException>()));

    await container.read(appPrefsProvider.notifier).setModelsFolder(elsewhere);
    expect(heads.current().model, 'bond-decide-synthetic');
  });

  group('a heads file this build cannot use parks, and is read once', () {
    for (final (what, contents, sentence) in [
      ('not JSON', '{not json', startsWith(DecisionHeadsFile.mismatchText)),
      (
        'not a JSON object',
        '[1, 2]',
        startsWith(DecisionHeadsFile.mismatchText),
      ),
      (
        'a different question set',
        jsonEncode({...syntheticHeadsJson(), 'qhash': 'not-this-one'}),
        startsWith(DecisionHeadsFile.mismatchText),
      ),
      (
        'another schema',
        jsonEncode({...syntheticHeadsJson(), 'schema': 3}),
        startsWith(DecisionHeadsFile.mismatchText),
      ),
      // The installed v2 model's file: its own sentence, naming the cause.
      (
        'the older model (schema 1)',
        jsonEncode({...syntheticHeadsJson(), 'schema': 1}),
        equals(DecisionHeads.olderModelText),
      ),
    ]) {
      test(what, () async {
        final container = containerFor(const AppPrefs());
        final file = File(headsPath());
        await file.parent.create(recursive: true);
        await file.writeAsString(contents);
        await installDecide(container);
        final heads = container.read(decisionHeadsProvider);

        Object? first;
        try {
          heads.current();
        } catch (e) {
          first = e;
        }
        expect(
          first,
          isA<DecisionMisconfiguredException>()
              // The older model's file parks under its own word: its fix is
              // an install, not an address.
              .having((e) => parkReasonFor(e), 'park word',
                  what.startsWith('the older model')
                      ? 'decision_older_model'
                      : 'decision_misconfigured')
              .having((e) => e.message, 'message', sentence),
        );
        // Cached on the file's mtime: the same failure, with no re-parse.
        Object? second;
        try {
          heads.current();
        } catch (e) {
          second = e;
        }
        expect(identical(first, second), isTrue);

        // A re-install (a newer mtime) is read again, and a good file loads.
        await file.writeAsString(jsonEncode(syntheticHeadsJson()));
        await file
            .setLastModified(DateTime.now().add(const Duration(minutes: 1)));
        expect(heads.current().model, 'bond-decide-synthetic');
      });
    }
  });

  group('a registry entry\'s heads are read only while its download record '
      'is current', () {
    Future<void> writeBoth() async {
      for (final (path, text) in [
        (p.join(support.path, 'models', decide.relativePath), 'gguf'),
        (headsPath(), jsonEncode(syntheticHeadsJson())),
      ]) {
        await File(path).parent.create(recursive: true);
        await File(path).writeAsString(text);
      }
    }

    Matcher notInstalled() => throwsA(isA<DecisionNotInstalledException>()
        .having((e) => parkReasonFor(e), 'park word', 'decision_not_installed')
        .having((e) => e.message, 'message',
            DecisionHeadsFile.notInstalledText));

    test('files on disk with no rows read as not installed, and are read '
        'once the rows are current', () async {
      final container = containerFor(const AppPrefs());
      await writeBoth();
      final store = container.read(setupStoreProvider);
      await store.recordDownload(DownloadLedger.empty);
      final heads = container.read(decisionHeadsProvider);

      expect(heads.current, notInstalled());

      // What the model ensurer's pass records once it has hashed them.
      await store.recordDownload(currentLedgerFor([decide]));
      expect(heads.current().model, 'bond-decide-synthetic');
    });

    test('a quit between the two legs after a digest change reads as not '
        'installed: the heads row is at the old digest', () async {
      final container = containerFor(const AppPrefs());
      await writeBoth();
      await container.read(setupStoreProvider).recordDownload(
            currentLedgerFor([decide]).record(FileDownloadState(
              id: DownloadLedger.headsId(decide.id),
              status: DownloadStatus.done,
              sha256: 'an-older-heads-digest',
            )),
          );

      expect(container.read(decisionHeadsProvider).current, notInstalled());
    });

    test('a loaded file stops being read the moment a Download again takes '
        'its rows out of done', () async {
      final container = containerFor(const AppPrefs());
      await writeBoth();
      await installDecide(container);
      final heads = container.read(decisionHeadsProvider);
      expect(heads.current().model, 'bond-decide-synthetic');

      await container.read(setupStoreProvider).recordDownload(
            currentLedgerFor([decide]).record(FileDownloadState(
              id: DownloadLedger.headsId(decide.id),
              status: DownloadStatus.pending,
              sha256: decide.heads!.sha256,
            )),
          );

      expect(heads.current, notInstalled(), reason: 'not the cached heads');
    });

    test('under an encoder-heads Your server the same rule holds', () async {
      final container = containerFor(const AppPrefs(
        decisionPlacement: ModelPlacement.box,
        decisionUrl: 'https://box.example.com/decide/v1/embeddings',
      ));
      await writeBoth();
      await container
          .read(setupStoreProvider)
          .recordDownload(DownloadLedger.empty);
      final heads = container.read(decisionHeadsProvider);

      expect(heads.current, notInstalled());
      await installDecide(container);
      expect(heads.current().model, 'bond-decide-synthetic');
    });

    test('a ledger the store has not read yet is loaded, and the call after '
        'the load reads the file', () async {
      final container = containerFor(const AppPrefs());
      await writeBoth();
      // Written by ANOTHER store over the same database: the container's
      // own has not read the row yet.
      await SetupStore(db).recordDownload(currentLedgerFor([decide]));
      final heads = container.read(decisionHeadsProvider);

      expect(heads.current, notInstalled());
      await container.read(setupStoreProvider).downloadLedger();
      expect(heads.current().model, 'bond-decide-synthetic');
    });

    test('a source: local entry reads its heads whenever they are there, '
        'with no ledger at all', () async {
      final local = testLocalDecideFile();
      final container = containerFor(
        const AppPrefs(),
        which: testManifest(decide: local),
      );
      final file =
          File(p.join(support.path, 'models', local.headsRelativePath!));
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(syntheticHeadsJson()));

      expect(container.read(decisionHeadsProvider).current().model,
          'bond-decide-synthetic');

      // A file it refuses says to copy the files: no button downloads it.
      await file.writeAsString('{not json');
      await file.setLastModified(DateTime.now().add(const Duration(minutes: 1)));
      expect(
        container.read(decisionHeadsProvider).current,
        throwsA(isA<DecisionMisconfiguredException>().having((e) => e.message,
            'message', startsWith(DecisionHeadsFile.mismatchLocalText))),
      );
    });
  });
}
