import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/registry_save.dart';
import 'package:bond_inbox/services/llm/model_slots.dart'
    show accessKeyCharsText, registryId;
import 'package:bond_inbox/widgets/model_registry_form.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/memory_token_store.dart';
import 'fixtures/test_db.dart';

/// The model registry's Save, the one Settings and the setup wizard share:
/// a landed write answers null, a refused one its sentence, and the token is
/// never in that sentence. Fixture tokens only.
void main() {
  late BondDatabase db;
  late MessageStore store;
  late MemoryTokenStore tokens;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    tokens = MemoryTokenStore();
  });

  tearDown(() => db.close());

  const registry = 'https://artifactory.example.com/artifactory/bond-models';
  const typedToken = 'test-typed-token-321';

  Future<AppPrefsNotifier> notifier() async {
    final made = AppPrefsNotifier(store, tokens: tokens);
    addTearDown(made.dispose);
    await made.ready;
    return made;
  }

  test('a good address and token land, and the answer is null', () async {
    final prefs = await notifier();

    final refusal = await saveRegistry(
      prefs,
      url: registry,
      token: typedToken,
      clearToken: false,
    );

    expect(refusal, isNull);
    expect(await store.getPref(registryUrlKey), registry);
    expect(prefs.state.effectiveRegistryUrl, registry);
    expect(prefs.state.registryTokenStored, isTrue);
    expect(prefs.bearerFor(registryId), typedToken);
  });

  test('an address that is not http or https is refused with the address '
      'sentence, and nothing is written', () async {
    final prefs = await notifier();

    final refusal = await saveRegistry(
      prefs,
      url: 'ftp://artifactory.example.com/x',
      token: typedToken,
      clearToken: false,
    );

    expect(refusal, ModelRegistryForm.addressRefusalText);
    expect(await store.getPref(registryUrlKey), isNull);
    expect(tokens.values, isEmpty);
    expect(prefs.state.registryTokenStored, isFalse);
  });

  test('a new origin saved with a blank token forgets the old host\'s token',
      () async {
    final prefs = await notifier();
    const otherRegistry = 'http://localhost:18082/artifactory/bond-models';
    expect(
      await saveRegistry(prefs,
          url: registry, token: typedToken, clearToken: false),
      isNull,
    );
    expect(prefs.state.registryTokenStored, isTrue);

    final refusal = await saveRegistry(
      prefs,
      url: otherRegistry,
      token: null,
      clearToken: true,
    );

    expect(refusal, isNull);
    expect(prefs.bearerFor(registryId), isNull);
    expect(prefs.state.registryTokenStored, isFalse);
    expect(prefs.state.effectiveRegistryUrl, otherRegistry);
    expect(await store.getPref(registryUrlKey), otherRegistry);
  });

  test('a token no header can carry is refused with the writer\'s sentence, '
      'which does not quote it', () async {
    final prefs = await notifier();
    const unusable = 'two words';

    final refusal = await saveRegistry(
      prefs,
      url: registry,
      token: unusable,
      clearToken: false,
    );

    expect(refusal, accessKeyCharsText);
    expect(refusal, isNot(contains(unusable)));
    expect(await store.getPref(registryUrlKey), isNull);
    expect(tokens.values, isEmpty);
  });
}
