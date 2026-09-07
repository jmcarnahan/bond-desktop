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
///
/// Every case is a widget test on purpose, even though nothing here renders:
/// in a widget test the timers run on the binding's fake clock, so
/// `tester.pump(duration)` advances time exactly and a dwell due at 65ms is
/// still pending at 61ms no matter how loaded the machine is. As plain tests
/// with real timers, the burst case below came down to which of two timers
/// due at the same instant fired first — it passed on insertion order and
/// flaked the moment a busy suite delayed a callback.

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
  /// same injection [DraftNotifier] takes for its undo window — here not to
  /// save wall-clock time, which the fake clock already does, but to keep the
  /// dwell arithmetic in the cases below small enough to read.
  ///
  /// Every caller disposes at the end of its own body, not via [addTearDown]:
  /// the binding asserts no timer is pending BEFORE the teardown callbacks
  /// run, so a teardown-time dispose is too late to cancel a live dwell.
  NotificationRibbonNotifier notifier({
    Duration dwell = const Duration(milliseconds: 20),
    Duration maxDwell = const Duration(milliseconds: 60),
  }) {
    return NotificationRibbonNotifier(
      events: events.stream,
      enabled: () => enabled,
      dwell: dwell,
      maxDwell: maxDwell,
    );
  }

  setUp(() {
    events = StreamController<MessageSettled>.broadcast();
    enabled = true;
  });

  tearDown(() => events.close());

  testWidgets('a settle puts the message on screen by name', (tester) async {
    final ribbon = notifier();

    events.add(_settled(title: 'Homepage copy'));
    await tester.pump();

    expect(ribbon.state.visible, isTrue);
    expect(ribbon.state.total, 1);
    expect(ribbon.state.text, 'Homepage copy');

    ribbon.dispose();
  });

  testWidgets('a message with no subject falls back to its ask, then to a '
      'default', (tester) async {
    final ribbon = notifier();

    // An empty subject has to fall through exactly as a missing one does.
    events.add(_settled(title: '', ctaText: 'Confirm the launch date'));
    await tester.pump();
    expect(ribbon.state.text, 'Confirm the launch date');

    ribbon.dismiss();
    events.add(_settled(key: 'c2', id: 'm2', title: '', ctaText: ''));
    await tester.pump();
    expect(ribbon.state.text, 'A message needs you');

    ribbon.dispose();
  });

  testWidgets('a lone settle names its storyline as context', (tester) async {
    final ribbon = notifier();

    events.add(_settled(
      title: 'Homepage copy',
      storylineId: 'sl-1',
      storylineTitle: 'Website redesign',
    ));
    await tester.pump();

    expect(ribbon.state.text, 'Homepage copy · in Website redesign');

    ribbon.dispose();
  });

  testWidgets('it goes on its own after the dwell, without losing what it '
      'said', (tester) async {
    final ribbon = notifier();

    events.add(_settled(title: 'Homepage copy'));
    await tester.pump();
    expect(ribbon.state.visible, isTrue);

    await tester.pump(const Duration(milliseconds: 60));

    expect(ribbon.state.visible, isFalse);
    // Kept: the widget is still animating out and needs its text to do it.
    expect(ribbon.state.items, hasLength(1));

    ribbon.dispose();
  });

  testWidgets('a second settle restarts the dwell', (tester) async {
    final ribbon = notifier();

    events.add(_settled(title: 'Homepage copy'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 15));
    events.add(_settled(key: 'c2', id: 'm2', title: 'Launch date'));
    await tester.pump();

    // Past the first settle's own dwell, well short of the second's.
    await tester.pump(const Duration(milliseconds: 12));
    expect(ribbon.state.visible, isTrue);

    ribbon.dispose();
  });

  testWidgets('three threads are one ribbon that counts them', (tester) async {
    final ribbon = notifier();

    for (var i = 1; i <= 3; i++) {
      events.add(_settled(key: 'c$i', id: 'm$i', title: 'Subject $i'));
      await tester.pump();
    }

    expect(ribbon.state.total, 3);
    expect(ribbon.state.items, hasLength(3));
    expect(ribbon.state.text, '3 messages need you');

    ribbon.dispose();
  });

  testWidgets('threads that share one storyline are named after it',
      (tester) async {
    final ribbon = notifier();

    for (var i = 1; i <= 3; i++) {
      events.add(_settled(
        key: 'c$i',
        id: 'm$i',
        storylineId: 'sl-1',
        storylineTitle: 'Website redesign',
      ));
      await tester.pump();
    }

    expect(ribbon.state.text, '3 messages in Website redesign');

    // One of them somewhere else and the storyline is no longer the answer.
    events.add(_settled(key: 'c4', id: 'm4', storylineId: 'sl-2'));
    await tester.pump();
    expect(ribbon.state.text, '4 messages need you');

    ribbon.dispose();
  });

  testWidgets('the same thread settling twice replaces itself', (tester) async {
    final ribbon = notifier();

    events.add(_settled(title: 'Homepage copy'));
    await tester.pump();
    events.add(_settled(id: 'm2', title: 'Homepage copy, again'));
    await tester.pump();

    expect(ribbon.state.total, 1, reason: 'one thread, twice');
    expect(ribbon.state.items, hasLength(1));
    expect(ribbon.state.text, 'Homepage copy, again');

    ribbon.dispose();
  });

  testWidgets('past five threads it keeps five and counts them all',
      (tester) async {
    final ribbon = notifier();

    for (var i = 1; i <= 8; i++) {
      events.add(_settled(key: 'c$i', id: 'm$i'));
      await tester.pump();
    }

    expect(ribbon.state.items, hasLength(NotificationRibbonNotifier.retained));
    expect(ribbon.state.total, 8);
    expect(ribbon.state.text, '8 messages need you');
    // The oldest went, the newest stayed.
    expect(ribbon.state.items.first.conversationKey, 'c4');
    expect(ribbon.state.items.last.conversationKey, 'c8');

    ribbon.dispose();
  });

  testWidgets('a rolling burst cannot pin the ribbon past the ceiling',
      (tester) async {
    final ribbon = notifier();

    // A settle every fifteen milliseconds restarts the twenty-millisecond
    // dwell every time: at t=45 the fourth one has just pushed the dwell out
    // to t=65, and left alone that would go on forever.
    for (var i = 1; i <= 4; i++) {
      events.add(_settled(key: 'c$i', id: 'm$i'));
      if (i < 4) await tester.pump(const Duration(milliseconds: 15));
    }
    await tester.pump();
    expect(ribbon.state.visible, isTrue);

    // One millisecond past the ceiling — and four short of the dwell the
    // burst keeps renewing. The ceiling started at the first settle, was
    // never restarted, and outranks the dwell that is still pending.
    await tester.pump(const Duration(milliseconds: 16));
    expect(ribbon.state.visible, isFalse);

    // Hidden is not muted: the next settle is a fresh batch, not a casualty
    // of the burst before it.
    events.add(_settled(key: 'c9', id: 'm9', title: 'Launch date'));
    await tester.pump();
    expect(ribbon.state.visible, isTrue);
    expect(ribbon.state.total, 1);
    expect(ribbon.state.text, 'Launch date');

    ribbon.dispose();
  });

  testWidgets('with the ribbon off, a settle is dropped rather than queued',
      (tester) async {
    enabled = false;
    final ribbon = notifier();

    events.add(_settled(title: 'Homepage copy'));
    await tester.pump();

    expect(ribbon.state.visible, isFalse);
    expect(ribbon.state.items, isEmpty);

    // Turning it back on is not a request to be caught up.
    enabled = true;
    await tester.pump(const Duration(milliseconds: 30));
    expect(ribbon.state.visible, isFalse);
    expect(ribbon.state.items, isEmpty);

    ribbon.dispose();
  });

  testWidgets('dismiss hides it now and keeps its contents', (tester) async {
    final ribbon = notifier();

    events.add(_settled(title: 'Homepage copy'));
    await tester.pump();
    ribbon.dismiss();

    expect(ribbon.state.visible, isFalse);
    expect(ribbon.state.items, hasLength(1));

    // The dwell timer went with it, so nothing fires later.
    await tester.pump(const Duration(milliseconds: 60));
    expect(ribbon.state.visible, isFalse);

    ribbon.dispose();
  });

  testWidgets('the next settle after a dismiss starts a fresh batch',
      (tester) async {
    final ribbon = notifier();

    events.add(_settled(key: 'c1', id: 'm1'));
    await tester.pump();
    ribbon.dismiss();

    events.add(_settled(key: 'c2', id: 'm2', title: 'Launch date'));
    await tester.pump();

    expect(ribbon.state.total, 1);
    expect(ribbon.state.text, 'Launch date');

    ribbon.dispose();
  });

  testWidgets('urgency is the loudest thing in the batch', (tester) async {
    final ribbon = notifier();

    events.add(_settled(key: 'c1', id: 'm1'));
    await tester.pump();
    expect(ribbon.state.anyUrgent, isFalse);

    events.add(_settled(key: 'c2', id: 'm2', ctaUrgency: CtaUrgency.urgent));
    await tester.pump();
    expect(ribbon.state.anyUrgent, isTrue);

    events.add(_settled(key: 'c3', id: 'm3', ctaUrgency: CtaUrgency.high));
    await tester.pump();
    expect(ribbon.state.anyUrgent, isTrue, reason: 'one urgent is enough');

    ribbon.dispose();
  });

  testWidgets('dispose leaves no timer behind', (tester) async {
    // Every timer here runs in FakeAsync and flutter_test fails the test if
    // one is still pending at the end — which is exactly the bug this pins. A
    // leaked dwell timer would fail dozens of suites that build the real
    // provider graph.
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
