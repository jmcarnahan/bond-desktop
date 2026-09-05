import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The owner's own needs-you rules, as a property of what is STORED.
///
/// The text goes into a prompt fence on every below-floor message, which makes
/// two things worth pinning: that a fresh install has none — the defaults are
/// meant to work for somebody who never opens the field — and that whatever
/// somebody types comes back byte for byte. A store that trimmed would mean
/// the text in the field and the text the model reads are not the same string.

void main() {
  late BondDatabase db;

  /// The container, with its stored settings already loaded — the notifier
  /// starts on the defaults and reads the database a microtask later, which is
  /// what `main()` waits for before the first frame.
  Future<ProviderContainer> container() async {
    final made = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(made.dispose);
    await made.read(appPrefsProvider.notifier).ready;
    return made;
  }

  setUp(() {
    db = testDb();
  });

  tearDown(() async => db.close());

  test('a fresh install has no rules of its own', () async {
    final ref = await container();

    expect(await MessageStore(db).getPref(needsYouRulesKey), isNull);
    expect(ref.read(appPrefsProvider).needsYouRules, '');
  });

  test('what is typed lands in app_prefs and in the state', () async {
    final store = MessageStore(db);
    final ref = await container();

    await ref
        .read(appPrefsProvider.notifier)
        .setNeedsYouRules('Invoices always need me.');

    expect(await store.getPref(needsYouRulesKey), 'Invoices always need me.');
    expect(
      ref.read(appPrefsProvider).needsYouRules,
      'Invoices always need me.',
    );
    expect(
      (await AppPrefsNotifier.read(store)).needsYouRules,
      'Invoices always need me.',
    );
  });

  test('clearing the field writes the empty value rather than the key away',
      () async {
    final store = MessageStore(db);
    final ref = await container();
    final prefs = ref.read(appPrefsProvider.notifier);

    await prefs.setNeedsYouRules('Invoices always need me.');
    await prefs.setNeedsYouRules('');

    expect(await store.getPref(needsYouRulesKey), '');
    expect(ref.read(appPrefsProvider).needsYouRules, '');
  });

  test('the rules survive the next launch', () async {
    final store = MessageStore(db);
    final first = await container();

    await first
        .read(appPrefsProvider.notifier)
        .setNeedsYouRules('Anything from the landlord needs me.');

    // A second read of the same database is what a relaunch is.
    final relaunched = await AppPrefsNotifier.read(store);
    expect(relaunched.needsYouRules, 'Anything from the landlord needs me.');
  });

  test('the text is stored verbatim, whitespace and all', () async {
    final store = MessageStore(db);
    final ref = await container();

    // The pane trims before it calls. Trimming again down here would mean the
    // field and the prompt disagree about what the rules say.
    await ref
        .read(appPrefsProvider.notifier)
        .setNeedsYouRules('  keep my spaces\n\n');

    expect(await store.getPref(needsYouRulesKey), '  keep my spaces\n\n');
    expect(
      (await AppPrefsNotifier.read(store)).needsYouRules,
      '  keep my spaces\n\n',
    );
  });
}
