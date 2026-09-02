import 'package:bond_inbox/providers/navigation_provider.dart';
import 'package:bond_inbox/providers/notify_routing.dart';
import 'package:bond_inbox/services/notify/desktop_notifier.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:flutter_test/flutter_test.dart';

/// Where a click on a notification goes.
///
/// The rule table is short and the reason it is short matters: the app never
/// picks a thread on the user's behalf. One settle is one thing to read;
/// several are a pile, and a pile only has a destination when the settles agree
/// on one.

MessageSettled _settled({
  String source = 'email',
  String key = 'c1',
  String? storylineId,
}) =>
    MessageSettled(
      source: source,
      sourceMessageId: '$key-m1',
      conversationKey: key,
      settledAt: '2026-09-02T10:00:00Z',
      storylineId: storylineId,
    );

void main() {
  test('one settle opens its thread, with the source it belongs to', () {
    // Never a bare id: a conversation key is unique within a connector and not
    // across them, so a chat and a mail thread can share one.
    final intent = intentFor([_settled(source: 'teams', key: 'shared')]);

    expect(intent, isA<OpenThreadIntent>());
    final thread = intent as OpenThreadIntent;
    expect(thread.source, 'teams');
    expect(thread.conversationKey, 'shared');
  });

  test('one settle inside a storyline still opens the thread', () {
    // The storyline is context on the way in, not the ask.
    final intent = intentFor([_settled(storylineId: 'sl-1')]);

    expect(intent, isA<OpenThreadIntent>());
  });

  test('two settles in one storyline open the storyline', () {
    final intent = intentFor([
      _settled(key: 'c1', storylineId: 'sl-1'),
      _settled(key: 'c2', storylineId: 'sl-1'),
    ]);

    expect(intent, isA<OpenStorylineIntent>());
    expect((intent as OpenStorylineIntent).storylineId, 'sl-1');
  });

  test('two settles in different storylines open Needs You', () {
    final intent = intentFor([
      _settled(key: 'c1', storylineId: 'sl-1'),
      _settled(key: 'c2', storylineId: 'sl-2'),
    ]);

    expect(intent, isA<OpenSectionIntent>());
    expect((intent as OpenSectionIntent).section, RailSection.needsYou);
  });

  test('one settle outside any storyline is enough to open Needs You', () {
    final intent = intentFor([
      _settled(key: 'c1', storylineId: 'sl-1'),
      _settled(key: 'c2'),
    ]);

    expect(intent, isA<OpenSectionIntent>());
  });

  test('settles with no storyline at all open Needs You', () {
    final intent = intentFor([_settled(key: 'c1'), _settled(key: 'c2')]);

    expect(intent, isA<OpenSectionIntent>());
  });

  test('nothing to announce has nowhere to go', () {
    expect(() => intentFor(const []), throwsArgumentError);
  });

  /// The same rule table, read off a payload instead of off the settles.
  ///
  /// A tapped toast has no list to look at — only what fitted in its payload —
  /// so the count it was posted with is the whole of what it can route on.
  group('a tapped toast', () {
    test('standing for one thread opens that thread', () {
      final intent = intentForTarget(const NotificationTarget(
        source: 'teams',
        conversationKey: 'shared',
      ));

      expect(intent, isA<OpenThreadIntent>());
      final thread = intent as OpenThreadIntent;
      expect(thread.source, 'teams');
      expect(thread.conversationKey, 'shared');
    });

    test('standing for several opens Needs You', () {
      final intent = intentForTarget(const NotificationTarget(
        source: 'email',
        conversationKey: 'c1',
        count: 2,
      ));

      // Even though the payload names one: it is the newest of a pile, not the
      // thing the user was told about.
      expect(intent, isA<OpenSectionIntent>());
      expect((intent as OpenSectionIntent).section, RailSection.needsYou);
    });

    test('carrying a storyline still opens the thread', () {
      // The storyline is payload, not trigger — the same rule [intentFor]
      // follows for a single settle.
      final intent = intentForTarget(const NotificationTarget(
        source: 'email',
        conversationKey: 'c1',
        storylineId: 'sl-1',
      ));

      expect(intent, isA<OpenThreadIntent>());
      expect((intent as OpenThreadIntent).conversationKey, 'c1');
    });
  });
}
