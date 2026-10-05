import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/system/system_info.dart' show HardwareInfo;
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/model_servers_form.dart';
import 'package:bond_inbox/widgets/settings_models_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'fixtures/fake_system_info.dart';
import 'fixtures/memory_token_store.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// A keychain that notes, at the moment of each write, what the registry
/// address pref held: how a test proves the keychain moves BEFORE the
/// address.
class _OrderingTokenStore extends MemoryTokenStore {
  final MessageStore store;
  final List<String?> urlAtWrite = [];

  _OrderingTokenStore(this.store);

  @override
  Future<void> write(String key, String? value) async {
    urlAtWrite.add(await store.getPref(registryUrlKey));
    await super.write(key, value);
  }
}

/// The default-setup round's configuration seams: what `local.mk` compiles in
/// and how Settings layers over it.
///
/// Every define is `''` under `flutter test`, so each case hands the build's
/// values to `AppPrefsNotifier` (`compiledBoxUrl:`, `compiledBoxKey:`,
/// `compiledRegistryUrl:`, `compiledRegistryToken:`), the one seam that reads
/// them. The keys here are fixture strings, and the tests assert where they
/// go and that a field obscures them, never that a real one works.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  const boxUrl = 'https://box.example.com';
  const proseUrl = '$boxUrl/prose/v1/chat/completions';
  const decideUrl = '$boxUrl/decide/v1/embeddings';
  const otherUrl = 'https://other.example.com/v1/chat/completions';
  const boxKey = 'test-key-123';
  const typedKey = 'test-typed-key-789';
  const registryUrl = 'http://localhost:18082/artifactory/bond-models';
  const otherRegistry = 'https://artifactory.example.com/artifactory/bond-models';
  const registryToken = 'test-registry-token-456';
  const typedToken = 'test-typed-token-321';

  Future<AppPrefsNotifier> notifier({
    TokenStore? tokens,
    AppPrefs? initial,
    String compiledBoxUrl = boxUrl,
    String compiledBoxKey = boxKey,
    String compiledRegistryUrl = registryUrl,
    String compiledRegistryToken = registryToken,
  }) async {
    final made = AppPrefsNotifier(
      store,
      tokens: tokens ?? MemoryTokenStore(),
      initial: initial,
      compiledBoxUrl: compiledBoxUrl,
      compiledBoxKey: compiledBoxKey,
      compiledRegistryUrl: compiledRegistryUrl,
      compiledRegistryToken: compiledRegistryToken,
    );
    addTearDown(made.dispose);
    await made.ready;
    return made;
  }

  /// Every value in `app_prefs`, which is where a leaked secret would be.
  Future<List<String>> prefValues() async {
    final rows = await db.customSelect('SELECT value FROM app_prefs').get();
    return [for (final row in rows) row.read<String>('value')];
  }

  group("the build's box key", () {
    test('rides both roles while their addresses follow the build', () async {
      final prefs = await notifier();
      await prefs.useDecision(placement: ModelPlacement.box);

      expect(prefs.state.modelPlacement, ModelPlacement.box);
      expect(prefs.state.effectiveGenerativeUrl, proseUrl);
      expect(prefs.state.boxBigKeyStored, isFalse);
      expect(prefs.state.boxKeyCompiled, isTrue);
      expect(prefs.state.generativeKeyFromBuild, isTrue);
      expect(prefs.state.generativeSpec.hasBearer, isTrue);
      expect(prefs.bearerFor(boxProseId), boxKey);
      expect(prefs.targetForStage('message_text').bearer, boxKey);
      expect(prefs.targetForStage('draft_reply').bearer, boxKey);

      expect(prefs.state.effectiveDecisionUrl, decideUrl);
      expect(prefs.state.decisionKeyFromBuild, isTrue);
      expect(prefs.bearerFor(boxDecideId), boxKey);
      expect(prefs.targetForStage('decision').bearer, boxKey);

      // Never in a preference, and never on the value object's face.
      for (final value in await prefValues()) {
        expect(value, isNot(contains(boxKey)));
      }
      expect(prefs.state.toString(), isNot(contains(boxKey)));
      expect(prefs.targetForStage('message_text').toString(),
          isNot(contains(boxKey)));
    });

    test('a keychain entry beats it', () async {
      final prefs = await notifier(
        tokens: MemoryTokenStore({
          '$llmTargetBearerKeyPrefix$boxProseId': typedKey,
        }),
      );

      expect(prefs.state.boxBigKeyStored, isTrue);
      expect(prefs.state.generativeKeyFromBuild, isFalse);
      expect(prefs.state.generativeSpec.hasBearer, isTrue);
      expect(prefs.bearerFor(boxProseId), typedKey);
      expect(prefs.targetForStage('message_text').bearer, typedKey);
    });

    test('Remove key falls back to it', () async {
      final tokens = MemoryTokenStore({
        '$llmTargetBearerKeyPrefix$boxProseId': typedKey,
      });
      final prefs = await notifier(tokens: tokens);

      await prefs.clearRoleKey(boxProseId);

      expect(tokens.values, isEmpty);
      expect(prefs.state.boxBigKeyStored, isFalse);
      expect(prefs.state.generativeKeyFromBuild, isTrue);
      expect(prefs.bearerFor(boxProseId), boxKey);
      expect(prefs.targetForStage('message_text').bearer, boxKey);
    });

    test('a stored address on another origin gets no key from the build, '
        'one on the same origin does', () async {
      final prefs = await notifier();

      for (final (url, same) in [
        (otherUrl, false),
        ('http://box.example.com/prose/v1/chat/completions', false),
        ('https://box.example.com:8443/prose/v1/chat/completions', false),
        ('$boxUrl/custom/v1/chat/completions', true),
        ('https://box.example.com:443/prose/v1/chat/completions', true),
      ]) {
        await prefs.useGenerative(
          placement: ModelPlacement.box,
          url: url,
          hardwareTier: MachineTier.full,
        );
        expect(prefs.state.generativeSpec.url, url, reason: url);
        expect(prefs.state.generativeKeyFromBuild, same, reason: url);
        expect(prefs.state.generativeSpec.hasBearer, same, reason: url);
        expect(prefs.bearerFor(boxProseId), same ? boxKey : isNull,
            reason: url);
        expect(prefs.targetForStage('message_text').bearer,
            same ? boxKey : isNull,
            reason: url);
      }

      for (final (url, same) in [
        ('https://other.example.com/decide/v1/embeddings', false),
        ('$boxUrl/decide2/v1/embeddings', true),
      ]) {
        await prefs.useDecision(placement: ModelPlacement.box, url: url);
        expect(prefs.state.decisionKeyFromBuild, same, reason: url);
        expect(prefs.bearerFor(boxDecideId), same ? boxKey : isNull,
            reason: url);
        expect(prefs.targetForStage('decision').bearer,
            same ? boxKey : isNull,
            reason: url);
      }
    });

    test('with no compiled key nothing changes', () async {
      final prefs = await notifier(compiledBoxKey: '');
      await prefs.useDecision(placement: ModelPlacement.box);

      expect(prefs.state.boxKeyCompiled, isFalse);
      expect(prefs.state.generativeKeyFromBuild, isFalse);
      expect(prefs.state.decisionKeyFromBuild, isFalse);
      expect(prefs.state.generativeSpec.hasBearer, isFalse);
      expect(prefs.bearerFor(boxProseId), isNull);
      expect(prefs.bearerFor(boxDecideId), isNull);
      expect(prefs.targetForStage('message_text').bearer, isNull);
      expect(prefs.targetForStage('decision').bearer, isNull);

      // And a notifier built on the suite's own defines is today's: nothing
      // compiled, nothing borrowed.
      final bare = AppPrefsNotifier(store, tokens: MemoryTokenStore());
      addTearDown(bare.dispose);
      await bare.ready;
      expect(bare.state.compiledBoxUrl, isEmpty);
      expect(bare.state.boxKeyCompiled, isFalse);
      expect(bare.state.registryTokenCompiled, isFalse);
      expect(bare.bearerFor(boxProseId), isNull);
      expect(bare.bearerFor(boxDecideId), isNull);
      expect(bare.bearerFor(registryId), isNull);
    });

    test('a write that follows the build stores the empty address', () async {
      final prefs = await notifier();
      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: proseUrl,
        hardwareTier: MachineTier.full,
      );
      expect(await store.getPref(boxBigUrlKey), '');
      expect(prefs.state.generativeKeyFromBuild, isTrue);
    });
  });

  group('Your server with no address', () {
    test('is the generative role, unavailable with its sentence', () async {
      final prefs = await notifier(compiledBoxUrl: '', compiledBoxKey: '');

      expect(prefs.state.modelPlacement, ModelPlacement.box);
      expect(prefs.state.generativeSpec.id, boxProseId);
      expect(prefs.state.generativeSpec.url, isEmpty);
      final target = prefs.targetForStage('message_text');
      expect(target.baseUrl, isEmpty);
      expect(target.unavailable, generativeNoAddressText);
      expect(prefs.targetForStage('draft_reply').unavailable,
          generativeNoAddressText);
      // The decision model is untouched by it: this Mac, served.
      expect(prefs.targetForStage('decision').unavailable, isNull);
    });

    test('the client refuses it before any request, and it parks as '
        'no_address', () async {
      final prefs = await notifier(compiledBoxUrl: '', compiledBoxKey: '');
      final client = LlmClient(
        httpClient: MockClient((request) async {
          fail('no request may leave for a target with no address');
        }),
        resolveTarget: () => prefs.targetForStage('message_text'),
      );

      await expectLater(
        client.complete(system: 's', user: 'u'),
        throwsA(isA<ModelNoAddressException>()
            .having((e) => e, 'parks', isA<LlmUnavailableException>())
            .having((e) => parkReasonFor(e), 'park word', 'no_address')
            .having((e) => e.message, 'message', generativeNoAddressText)),
      );
    });

    test('the managed manifest serves no generative model for it', () async {
      final support = await Directory.systemTemp.createTemp('default-setup');
      addTearDown(() => support.delete(recursive: true));
      final system = FakeSystemInfo()
        ..hardwareInfo = const HardwareInfo(
          chip: 'Apple M2 Max',
          memoryBytes: 64 * 1024 * 1024 * 1024,
          appleSilicon: true,
          rosetta: false,
          osVersion: '15.6',
        );
      final container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        appPathsProvider.overrideWithValue(AppPaths(support)),
        modelManifestProvider.overrideWithValue(testManifest(withDecide: true)),
        systemInfoProvider.overrideWithValue(system),
        appPrefsProvider.overrideWith(
          (ref) => AppPrefsNotifier(
            MessageStore(db),
            tokens: MemoryTokenStore(),
            compiledBoxUrl: '',
            compiledBoxKey: '',
          ),
        ),
      ]);
      addTearDown(container.dispose);

      expect(container.read(appPrefsProvider).generativeSpec.id, boxProseId);
      final served = [
        for (final m
            in (await container.read(managedManifestProvider.future)).models)
          m.id,
      ];
      expect(served, [routerEmbedId, routerDecideId]);
      expect(served, isNot(contains(routerProseId)));
      expect(served, isNot(contains(routerBulkId)));
    });
  });

  group('the model registry', () {
    test('a stored address beats the build, and following the build stores '
        'the empty string', () async {
      final prefs = await notifier(compiledRegistryUrl: '$registryUrl/');
      expect(prefs.state.registryUrl, isEmpty);
      expect(prefs.state.effectiveRegistryUrl, registryUrl);

      await prefs.useRegistry(url: '$otherRegistry/');
      expect(await store.getPref(registryUrlKey), otherRegistry);
      expect(prefs.state.effectiveRegistryUrl, otherRegistry);
      expect((await AppPrefsNotifier.read(store)).registryUrl, otherRegistry);

      for (final same in [registryUrl, '$registryUrl//', '  $registryUrl ']) {
        await prefs.useRegistry(url: same);
        expect(await store.getPref(registryUrlKey), '', reason: same);
        expect(prefs.state.effectiveRegistryUrl, registryUrl, reason: same);
      }

      await prefs.useRegistry(url: '');
      expect(await store.getPref(registryUrlKey), '');
      expect(prefs.state.effectiveRegistryUrl, registryUrl);
    });

    test('no address anywhere is the empty string', () async {
      final prefs = await notifier(compiledRegistryUrl: '');
      expect(prefs.state.effectiveRegistryUrl, isEmpty);
      expect(prefs.state.registryTokenFromBuild, isFalse);
      expect(prefs.bearerFor(registryId), isNull);
    });

    test('a bad address or a bad token is refused, and nothing is written',
        () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens: tokens);

      for (final bad in ['not a url', 'ftp://artifactory.example.com/x']) {
        await expectLater(
          prefs.useRegistry(url: bad, token: typedToken),
          throwsArgumentError,
          reason: bad,
        );
      }
      await expectLater(
        prefs.useRegistry(url: otherRegistry, token: 'two words'),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', accessKeyCharsText)),
      );

      expect(await store.getPref(registryUrlKey), isNull);
      expect(tokens.values, isEmpty);
      expect(prefs.state.registryUrl, isEmpty);
      expect(prefs.state.registryTokenStored, isFalse);
    });

    test('the keychain moves before the address', () async {
      final tokens = _OrderingTokenStore(store);
      final prefs = await notifier(tokens: tokens);

      await prefs.useRegistry(url: otherRegistry, token: typedToken);

      expect(tokens.urlAtWrite, [null]);
      expect(await store.getPref(registryUrlKey), otherRegistry);
      expect(tokens.values['$llmTargetBearerKeyPrefix$registryId'],
          typedToken);
      expect(prefs.state.registryTokenStored, isTrue);
      expect(prefs.bearerFor(registryId), typedToken);
      for (final value in await prefValues()) {
        expect(value, isNot(contains(typedToken)));
      }
    });

    test('a keychain that refuses costs the token, not the address', () async {
      // useDecision's convention, mirrored: the write is guarded, the
      // address is saved either way.
      final prefs = await notifier(tokens: RefusingTokenStore());

      await prefs.useRegistry(url: otherRegistry, token: typedToken);

      expect(await store.getPref(registryUrlKey), otherRegistry);
      expect(prefs.state.effectiveRegistryUrl, otherRegistry);
    });

    test('a blank token keeps the stored one; clearToken forgets it',
        () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens: tokens);
      await prefs.useRegistry(url: otherRegistry, token: typedToken);

      await prefs.useRegistry(url: otherRegistry);
      expect(tokens.values['$llmTargetBearerKeyPrefix$registryId'],
          typedToken);

      await prefs.useRegistry(url: registryUrl, clearToken: true);
      expect(tokens.values, isEmpty);
      expect(prefs.state.registryTokenStored, isFalse);
    });

    test('an address on another host forgets the stored token untold; the '
        'same host on another path keeps it', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens: tokens);
      await prefs.useRegistry(url: otherRegistry, token: typedToken);

      await prefs.useRegistry(url: '$otherRegistry/elsewhere');
      expect(tokens.values['$llmTargetBearerKeyPrefix$registryId'],
          typedToken);

      await prefs.useRegistry(url: 'https://third.example.com/artifactory/m');
      expect(tokens.values, isEmpty);
      expect(prefs.state.registryTokenStored, isFalse);
      expect(prefs.bearerFor(registryId), isNull);
    });

    test('clearRegistryToken falls back to the build', () async {
      final tokens = MemoryTokenStore({
        '$llmTargetBearerKeyPrefix$registryId': typedToken,
      });
      final prefs = await notifier(tokens: tokens);
      expect(prefs.state.registryTokenStored, isTrue);
      expect(prefs.bearerFor(registryId), typedToken);

      await prefs.clearRegistryToken();

      expect(tokens.values, isEmpty);
      expect(prefs.state.registryTokenStored, isFalse);
      expect(prefs.state.registryTokenFromBuild, isTrue);
      expect(prefs.bearerFor(registryId), registryToken);
    });

    test("the build's token goes only to the build's registry origin",
        () async {
      final prefs = await notifier();
      expect(prefs.state.registryTokenFromBuild, isTrue);
      expect(prefs.bearerFor(registryId), registryToken);

      await prefs.useRegistry(url: otherRegistry);
      expect(prefs.state.registryTokenFromBuild, isFalse);
      expect(prefs.bearerFor(registryId), isNull);

      await prefs.useRegistry(url: 'http://localhost:18082/artifactory/other');
      expect(prefs.bearerFor(registryId), registryToken);

      await prefs.useRegistry(url: 'http://localhost:18083/artifactory/x');
      expect(prefs.bearerFor(registryId), isNull);

      final none = await notifier(compiledRegistryToken: '');
      expect(none.bearerFor(registryId), isNull);
    });

    test('the downloader looks the address and the token up through the '
        'prefs, at the moment it asks', () async {
      final support = await Directory.systemTemp.createTemp('default-setup');
      addTearDown(() => support.delete(recursive: true));
      final container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        appPathsProvider.overrideWithValue(AppPaths(support)),
        modelManifestProvider.overrideWithValue(testManifest(withDecide: true)),
        systemInfoProvider.overrideWithValue(FakeSystemInfo()),
        // Built inside the override, so the container is its one owner.
        appPrefsProvider.overrideWith(
          (ref) => AppPrefsNotifier(
            store,
            tokens: MemoryTokenStore(),
            compiledRegistryUrl: registryUrl,
            compiledRegistryToken: registryToken,
          ),
        ),
      ]);
      addTearDown(container.dispose);
      final prefs = container.read(appPrefsProvider.notifier);
      await prefs.ready;

      final downloader = container.read(modelDownloaderProvider);
      expect(downloader.registryBase!(), registryUrl);
      expect(downloader.registryToken!(), registryToken);

      // Late-bound: a typed address on another host is read on the next ask,
      // and the build's token does not follow it there.
      await prefs.useRegistry(url: otherRegistry);
      expect(downloader.registryBase!(), otherRegistry);
      expect(downloader.registryToken!(), isNull);
    });
  });

  group('the key field when the build carries the key', () {
    Future<void> pumpForm(
      WidgetTester tester, {
      required List<(String, String?)> asked,
      required List<bool> clears,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ModelServersForm(
              role: ServerFormRole.generative,
              url: proseUrl,
              keyFromBuild: true,
              probe: (url, {bearer}) async {
                asked.add((url, bearer));
                return const ModelProbeResult(
                  reachable: true,
                  modelIds: ['qwen3.8'],
                );
              },
              storedBearer: (id) => id == boxProseId ? boxKey : null,
              onConnect: ({
                required url,
                required model,
                key,
                required clearKey,
              }) async {
                clears.add(clearKey);
              },
              onRemoveKey: () async {},
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    void expectNoTextCarries(WidgetTester tester, String secret) {
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.data ?? '', isNot(contains(secret)));
        expect(text.textSpan?.toPlainText() ?? '', isNot(contains(secret)));
      }
    }

    testWidgets('hints the build key, hides Remove key, obscures the field, '
        'and borrows the key on the same host only', (tester) async {
      final asked = <(String, String?)>[];
      final clears = <bool>[];
      await pumpForm(tester, asked: asked, clears: clears);
      const gen = ServerFormRole.generative;

      expect(find.text(ModelServersForm.buildKeyHint), findsOneWidget);
      expect(find.text(ModelServersForm.storedHint), findsNothing);
      expect(find.byKey(ModelServersForm.removeKeyKey(gen)), findsNothing);
      final field =
          tester.widget<TextField>(find.byKey(ModelServersForm.keyKey(gen)));
      expect(field.obscureText, isTrue);
      expect(field.controller!.text, isEmpty);
      expectNoTextCarries(tester, boxKey);

      await tester.tap(find.byKey(ModelServersForm.connectKey(gen)));
      await tester.pump();
      await tester.pump();
      expect(asked, [(proseUrl, boxKey)]);
      expect(clears, [false]);
      expectNoTextCarries(tester, boxKey);

      // Another host: the build's key is not for it, so the field says
      // nothing and the press sends nothing, and there is nothing to forget.
      await tester.enterText(
          find.byKey(ModelServersForm.urlKey(gen)), otherUrl);
      await tester.pump();
      expect(find.text(ModelServersForm.buildKeyHint), findsNothing);
      await tester.tap(find.byKey(ModelServersForm.connectKey(gen)));
      await tester.pump();
      await tester.pump();
      expect(asked.last, (otherUrl, null));
      expect(clears.last, isFalse);
      expectNoTextCarries(tester, boxKey);
    });

    testWidgets("the Models page does not ask for a key the build carries, "
        'and names a missing address', (tester) async {
      Future<void> pumpPage(String url, {bool fromBuild = true}) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SettingsModelsPage(
                generativePlacement: ModelPlacement.box,
                generativeUrl: url,
                generativeModel: boxProseModel,
                generativeKeyFromBuild: fromBuild,
                onUseGenerative: ({
                  required placement,
                  managedModel,
                  url,
                  model,
                  key,
                  clearKey = false,
                }) async {},
              ),
            ),
          ),
        ));
        await tester.pump();
      }

      String status() => tester
          .widget<Text>(find.byKey(SettingsModelsPage.generativeStatusKey))
          .data!;

      await pumpPage(proseUrl);
      expect(status(), SettingsModelsPage.connectedText(boxProseModel, proseUrl));
      expect(find.text(ModelServersForm.buildKeyHint), findsOneWidget);

      await pumpPage(proseUrl, fromBuild: false);
      expect(status(), SettingsModelsPage.keyNeededText);

      await pumpPage('');
      expect(status(), generativeNoAddressText);
    });
  });
}
