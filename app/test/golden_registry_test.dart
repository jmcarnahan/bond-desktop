import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/llm/storyline_tasks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/golden_registry.dart';
import 'fixtures/golden_set.dart';

/// The gold storyline registry loader, against a FICTIONAL registry-shaped
/// fixture.
///
/// The real registry is thirty efforts drawn from real correspondence and
/// never enters this repo, so what these tests pin is the SHAPE: that a
/// registry storyline rebuilds into the `Storyline` the confirm task would
/// have been handed, that a slug's people are unioned out of the set the way
/// the service unions them out of the database, and that an item's candidate
/// list is bounded, ordered and reproducible. A change to any of those changes
/// what a storyline row in the bakeoff ledger measured, silently, on the
/// machine that has the real files.
void main() {
  const fixturePath = 'test/fixtures/golden_fixture.json';
  const registryPath = 'test/fixtures/golden_registry_fixture.json';

  late GoldenSet set;
  late GoldenRegistry registry;

  setUp(() {
    set = GoldenSet.fromJson(
      jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>,
    );
    registry = GoldenRegistry.fromJson(
      jsonDecode(File(registryPath).readAsStringSync())
          as Map<String, dynamic>,
    );
  });

  test('the fixture registry loads in file order, storylines and anti alike',
      () {
    expect(registry.slugs, [
      'river-office-lease',
      'studio-website-redesign',
      'spring-portfolio-review',
    ]);
    expect(registry.antiSlugs, ['ANTI-person-hub']);
    for (final slug in registry.slugs) {
      expect(registry.bySlug[slug]?.slug, slug);
    }

    final lease = registry.bySlug['river-office-lease']!;
    expect(lease.title, 'River office lease');
    expect(lease.includes, hasLength(2));
    expect(lease.excludes, hasLength(1));
    expect(lease.memberKeys, ['email:fx-conv-lease', 'email:fx-conv-lease-2']);
    expect(
      lease.forbiddenNeighbors,
      ['studio-website-redesign', 'ANTI-person-hub'],
    );
  });

  test('every fixture charter crosses the task\'s clamp', () {
    // Real charters run 170–902 characters and `ConfirmMembershipTask` clamps
    // one at 400 at prompt time, so a fixture whose charters all fit under the
    // clamp would exercise a prompt the real registry never produces. The
    // window is wide because the point is "long enough to be truncated", not a
    // particular length.
    for (final storyline in registry.storylines) {
      expect(storyline.charter.length, greaterThanOrEqualTo(350),
          reason: storyline.slug);
      expect(storyline.charter.length, lessThanOrEqualTo(740),
          reason: storyline.slug);
    }
  });

  test('a registry storyline becomes the storyline the confirm task reads', () {
    final lease = registry.bySlug['river-office-lease']!;
    final storyline = lease.toAppStoryline();

    expect(storyline.id, 'river-office-lease');
    expect(storyline.title, 'River office lease');
    expect(storyline.charter, lease.charter);
    expect(storyline.status, 'active');
    expect(storyline.createdBy, 'gold');
    expect(storyline.summary, isNull);

    // The task renders the charter OR the summary, never both, so a null
    // summary is what makes the charter the criterion.
    final message = const ConfirmMembershipTask().buildUserMessage(
      ConfirmInput(
        storyline: storyline,
        storylineParticipants: const ['Alex Rivera'],
        candidateCard: 'a card | Alex Rivera |  | ',
      ),
    );
    expect(message, contains('Charter: '));
    expect(message, isNot(contains('Summary: ')));
  });

  test('a slug\'s people are the union over the set\'s own items', () {
    // Both lease items are on the fixture, and they share two names — the
    // union keeps first-seen order and de-duplicates case-insensitively, which
    // is what `_participantsOfStoryline` does over the database.
    expect(participantsFor('river-office-lease', set), [
      'Dana Whitfield',
      'Alex Rivera',
      'Priya Raman',
    ]);
    // A registry slug no golden item carries has nobody, and says so rather
    // than borrowing anyone.
    expect(participantsFor('spring-portfolio-review', set), isEmpty);
  });

  test('the candidate\'s own thread is not among the people it is judged '
      'against', () {
    // In the app a candidate is by construction not yet a member, so the
    // storyline it is judged against never contains it. Without the exclusion
    // the storyline fence would hand the model the candidate card's own
    // participants segment back as the storyline's People line.
    expect(
      participantsFor(
        'river-office-lease',
        set,
        excludingConversation: 'email:fx-conv-lease',
      ),
      ['Priya Raman', 'Alex Rivera'],
    );
    expect(
      participantsFor(
        'river-office-lease',
        set,
        excludingConversation: 'email:fx-conv-lease-2',
      ),
      ['Dana Whitfield', 'Alex Rivera', 'Priya Raman'],
    );
    // By CONVERSATION, so a key nobody has excludes nobody.
    expect(
      participantsFor(
        'river-office-lease',
        set,
        excludingConversation: 'email:fx-conv-nobody',
      ),
      participantsFor('river-office-lease', set),
    );
  });

  test('an item\'s candidates lead with gold, then the registry forbidden', () {
    final item = set.byId['email:fx-keep-tail']!;
    final candidates = candidatesFor(item, registry);

    // Gold first, then the one forbidden entry that is a registry slug; the
    // ANTI slug beside it is dropped, and the fixture's only remaining
    // storyline fills the extras.
    expect(candidates, [
      'river-office-lease',
      'studio-website-redesign',
      'spring-portfolio-review',
    ]);
    expect(candidates.where((s) => s.startsWith('ANTI-')), isEmpty);
    expect(candidates.toSet(), hasLength(candidates.length));
  });

  test('an item gold files nowhere is asked only about the extras', () {
    final item = set.byId['teams:fx-floor']!;
    final candidates = candidatesFor(item, registry);

    expect(item.gold.storylineId, 'none');
    // Three extras asked for, three storylines in the fixture registry.
    expect(candidates, hasLength(3));
    expect(candidates.toSet(), registry.slugs.toSet());
    expect(candidates.where((s) => s.startsWith('ANTI-')), isEmpty);
  });

  test('the extras are seeded per item — stable, and not the same for all', () {
    // A registry big enough that one extra apiece can differ. Fictional
    // efforts with no charter text, because nothing here reads one.
    final big = GoldenRegistry.fromJson({
      'storylines': [
        for (var i = 1; i <= 12; i++)
          {'slug': 'fx-effort-${i.toString().padLeft(2, '0')}'},
      ],
      'anti_storylines': const [],
    });

    final goldNone = [
      for (final item in set.items)
        if (item.gold.storylineId == 'none') item,
    ];
    expect(goldNone.length, greaterThan(1));

    final picks = <String, List<String>>{};
    for (final item in goldNone) {
      final once = candidatesFor(item, big, extras: 1);
      final twice = candidatesFor(item, big, extras: 1);
      expect(once, hasLength(1));
      // The same item asked twice is asked the same question: two runs of two
      // candidates have to sit the same exam.
      expect(twice, once);
      picks[item.id] = once;
    }
    // And two different items are not all handed the same storyline, which is
    // what a seed that ignored the id would do.
    expect(picks.values.map((p) => p.single).toSet().length, greaterThan(1));
  });

  test('stableSeed is FNV-1a and does not move', () {
    // FNV-1a 32-bit over the UTF-16 code units 97, 98 — pinned as a literal so
    // an SDK upgrade that changed the arithmetic could not pass quietly.
    expect(stableSeed('ab'), 1294271946);
    expect(stableSeed('a'), isNot(stableSeed('b')));
    expect(stableSeed('email:fx-keep-tail'), stableSeed('email:fx-keep-tail'));
  });

  test('a missing registry says what to set', () async {
    await expectLater(
      loadGoldenRegistry('${Directory.systemTemp.path}/no-such-registry.json'),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('GOLDEN_REGISTRY'),
      )),
    );
  });
}
