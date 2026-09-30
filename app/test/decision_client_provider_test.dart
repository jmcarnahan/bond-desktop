import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
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
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

  ProviderContainer containerFor(
    AppPrefs prefs, {
    MemoryTokenStore? tokens,
    http.Client? httpClient,
  }) {
    final made = ProviderContainer(overrides: [
      if (httpClient != null)
        decisionHttpClientProvider.overrideWithValue(httpClient),
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

  test('the install folder is named only when the models folder moved',
      () async {
    final plain = containerFor(const AppPrefs());
    expect(plain.read(decideInstallDirProvider), isNull);

    final moved = p.join(support.path, 'elsewhere');
    final custom = containerFor(AppPrefs(modelsFolder: moved));
    expect(
      custom.read(decideInstallDirProvider),
      p.dirname(p.join(moved, decide.relativePath)),
    );
    expect(p.basename(custom.read(decideInstallDirProvider)!),
        'local_bond-decide');
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
}
