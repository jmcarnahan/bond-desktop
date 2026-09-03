import 'dart:async';

import 'package:bond_inbox/models/message_models.dart' show CtaUrgency;
import 'package:bond_inbox/providers/notification_provider.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
import 'package:flutter_test/flutter_test.dart';

/// The ribbon's notifier: what it says, and how long it says it for.
///
/// Everything below is about restraint. A settle per message would be a stack
/// of banners over the mail, so the batch coalesces by thread; a burst that
/// kept arriving would keep restarting the dwell, so there is a ceiling on it;
/// and a user who turned the ribbon off is not asking to be caught up when
/// they turn it back on.

MessageSettled _settled({
  String source = 'email',
  String id = 'm1',
  String key = 'c1',
  String? title,
  String? ctaText,
  CtaUrgency ctaUrgency = CtaUrgency.normal,
  String? storylineId,
  String? storylineTitle,
}) =>
    MessageSettled(
      source: source,
      sourceMessageId: id,
      conversationKey: key,
      settledAt: '2026-09-02T10:00:00Z',
      title: title,
      ctaText: ctaText,
      ctaUrgency: ctaUrgency,
      storylineId: storylineId,
      storylineTitle: storylineTitle,
    );

void main() {
  late StreamController<MessageSettled> events;
  late bool enabled;

  /// Twenty and sixty milliseconds stand in for eight and twenty seconds. The
  /// same injection [DraftNotifier] takes for its undo window, and for the
  /// same reason: a suite must not spend the real dwell on every case.
  NotificationRibbonNotifier notifier({
    Duration dwell = const Duration(milliseconds: 20),
    Duration maxDwell = const Duration(milliseconds: 60),
  }) {
    final made = NotificationRibbonNotifier(
      events: events.stream,
      enabled: () => enabled,
      dwell: dwell,
      maxDwell: maxDwell,
    );
    addTearDown(made.dispose);
    return made;
  }

  /// Lets the stream deliver, and optionally lets the clock run.
  Future<void> tick([int ms = 0]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  setUp(() {
    events = StreamController<MessageSettled>.broadcast();
    enabled = true;
  });

  tearDown(() => events.close());

  test('a settle puts the message on screen by name', () async {
    final ribbon = notifier();

    events.add(_settled(title: 'Homepage copy'));
    await tick();

    expect(ribbon.state.visible, isTrue);
    expect(ribbon.state.total, 1);
    expect(ribbon.state.text, 'Homepage copy');
  });

  test('a message with no subject falls back to its ask, then to a default',
      () async {
    final ribbon = notifier();

    // An empty subject has to fall through exactly as a missing one does.
    events.add(_settled(title: '', ctaText: 'Confirm the launch date'));
    await tick();
    expect(ribbon.state.text, 'Confirm the launch date');

    ribbon.dismiss();
    events.add(_settled(key: 'c2', id: 'm2', title: '', ctaText: ''));
    await tick();
    expect(ribbon.state.text, 'A message needs you');
  });

  test('a lone settle names its storyline as context', () async {
    final ribbon = notifier();

    events.add(_settled(
      title: 'Homepage copy',
      storylineId: 'sl-1',
      storylineTitle: 'Website redesign',
    ));
    await tick();

    expect(ribbon.state.text, 'Homepage copy · in Website redesign');
  });

  test('it goes on its own after the dwell, without losing what it said',
      () async {
    final ribbon = notifier();

    events.add(_settled(title: 'Homepage copy'));
    await tick();
    expect(ribbon.state.visible, isTrue);

    await tick(60);

    expect(ribbon.state.visible, isFalse);
    // Kept: the widget is still animating out and needs its text to do it.
    expect(ribbon.state.items, hasLength(1));
  });

  test('a second settle restarts the dwell', () async {
    final ribbon = notifier();

    events.add(_settled(title: 'Homepage copy'));
    await tick();
    await tick(15);
    events.add(_settled(key: 'c2', id: 'm2', title: 'Launch date'));
    await tick();

    // Past the first settle's own dwell, well short of the second's.
    await tick(12);
    expect(ribbon.state.visible, isTrue);
  });

  test('three threads are one ribbon that counts them', () async {
    final ribbon = notifier();

    for (var i = 1; i <= 3; i++) {
      events.add(_settled(key: 'c$i', id: 'm$i', title: 'Subject $i'));
      await tick();
    }

    expect(ribbon.state.total, 3);
    expect(ribbon.state.items, hasLength(3));
    expect(ribbon.state.text, '3 messages need you');
  });

  test('threads that share one storyline are named after it', () async {
    final ribbon = notifier();

    for (var i = 1; i <= 3; i++) {
      events.add(_settled(
        key: 'c$i',
        id: 'm$i',
        storylineId: 'sl-1',
        storylineTitle: 'Website redesign',
      ));
      await tick();
    }

    expect(ribbon.state.text, '3 messages in Website redesign');

    // One of them somewhere else and the storyline is no longer the answer.
    events.add(_settled(key: 'c4', id: 'm4', storylineId: 'sl-2'));
    await tick();
    expect(ribbon.state.text, '4 messages need you');
  });

  test('the same thread settling twice replaces itself', () async {
    final ribbon = notifier();

    events.add(_settled(title: 'Homepage copy'));
    await tick();
    events.add(_settled(id: 'm2', title: 'Homepage copy, again'));
    await tick();

    expect(ribbon.state.total, 1, reason: 'one thread, twice');
    expect(ribbon.state.items, hasLength(1));
    expect(ribbon.state.text, 'Homepage copy, again');
  });

  test('past five threads it keeps five and counts them all', () async {
    final ribbon = notifier();

    for (var i = 1; i <= 8; i++) {
      events.add(_settled(key: 'c$i', id: 'm$i'));
      await tick();
    }

    expect(ribbon.state.items, hasLength(NotificationRibbonNotifier.retained));
    expect(ribbon.state.total, 8);
    expect(ribbon.state.text, '8 messages need you');
    // The oldest went, the newest stayed.
    expect(ribbon.state.items.first.conversationKey, 'c4');
    expect(ribbon.state.items.last.conversationKey, 'c8');
  });

  test('a rolling burst cannot pin the ribbon past the ceiling', () async {
    final ribbon = notifier();

    // A settle every fifteen milliseconds would restart a twenty-millisecond
    // dwell forever. The ceiling starts at the first one and is not restarted.
    for (var i = 1; i <= 8; i++) {
      events.add(_settled(key: 'c$i', id: 'm$i'));
      await tick(15);
    }

    expect(ribbon.state.visible, isFalse);
  });

  test('with the ribbon off, a settle is dropped rather than queued', () async {
    enabled = false;
    final ribbon = notifier();

    events.add(_settled(title: 'Homepage copy'));
    await tick();

    expect(ribbon.state.visible, isFalse);
    expect(ribbon.state.items, isEmpty);

    // Turning it back on is not a request to be caught up.
    enabled = true;
    await tick(30);
    expect(ribbon.state.visible, isFalse);
    expect(ribbon.state.items, isEmpty);
  });

  test('dismiss hides it now and keeps its contents', () async {
    final ribbon = notifier();

    events.add(_settled(title: 'Homepage copy'));
    await tick();
    ribbon.dismiss();

    expect(ribbon.state.visible, isFalse);
    expect(ribbon.state.items, hasLength(1));

    // The dwell timer went with it, so nothing fires later.
    await tick(60);
    expect(ribbon.state.visible, isFalse);
  });

  test('the next settle after a dismiss starts a fresh batch', () async {
    final ribbon = notifier();

    events.add(_settled(key: 'c1', id: 'm1'));
    await tick();
    ribbon.dismiss();

    events.add(_settled(key: 'c2', id: 'm2', title: 'Launch date'));
    await tick();

    expect(ribbon.state.total, 1);
    expect(ribbon.state.text, 'Launch date');
  });

  test('urgency is the loudest thing in the batch', () async {
    final ribbon = notifier();

    events.add(_settled(key: 'c1', id: 'm1'));
    await tick();
    expect(ribbon.state.anyUrgent, isFalse);

    events.add(_settled(key: 'c2', id: 'm2', ctaUrgency: CtaUrgency.urgent));
    await tick();
    expect(ribbon.state.anyUrgent, isTrue);

    events.add(_settled(key: 'c3', id: 'm3', ctaUrgency: CtaUrgency.high));
    await tick();
    expect(ribbon.state.anyUrgent, isTrue, reason: 'one urgent is enough');
  });

  testWidgets('dispose leaves no timer behind', (tester) async {
    // In a widget test every timer runs in FakeAsync and flutter_test fails
    // the test if one is still pending at the end — which is exactly the bug
    // this pins. A leaked dwell timer here would fail dozens of suites that
    // build the real provider graph.
    final ribbon = NotificationRibbonNotifier(
      events: events.stream,
      enabled: () => true,
    );
    events.add(_settled(title: 'Homepage copy'));
    await tester.pump();
    expect(ribbon.state.visible, isTrue,
        reason: 'the dwell and the ceiling are both armed');

    ribbon.dispose();
  });
}
