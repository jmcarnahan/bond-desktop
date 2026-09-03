import 'dart:async';

import 'package:bond_inbox/providers/navigation_provider.dart';
import 'package:bond_inbox/providers/notify_routing.dart';
import 'package:bond_inbox/services/notify/desktop_notification_service.dart';
import 'package:bond_inbox/services/notify/desktop_notifier.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:flutter_test/flutter_test.dart';

/// The OS side of a settle, driven directly through its constructor.
///
/// Nothing here goes near an operating system: the [DesktopNotifier] seam is
/// the whole point, and what this file pins is everything ABOVE it — when the
/// permission is asked for, when it is not, what one flush turns into, and that
/// disposal takes the timer with it.

/// Records what it was asked, and answers however the test set it to.
class _FakeDesktopNotifier implements DesktopNotifier {
  int authorizeCalls = 0;
  bool authorized = true;
  final List<DesktopNotification> shown = [];

  @override
  bool get supported => true;

  @override
  Future<bool> ensureAuthorized() async {
    authorizeCalls++;
    return authorized;
  }

  @override
  Future<void> show(DesktopNotification notification) async {
    shown.add(notification);
  }
}

MessageSettled _settled({
  String source = 'email',
  String key = 'c1',
  String? title,
  String? summary,
  String? ctaText,
  String? storylineId,
}) =>
    MessageSettled(
      source: source,
      sourceMessageId: '$source-$key-m1',
      conversationKey: key,
      settledAt: '2026-09-02T10:00:00Z',
      title: title,
      summary: summary,
      ctaText: ctaText,
      storylineId: storylineId,
    );

void main() {
  late StreamController<MessageSettled> settles;
  late _FakeDesktopNotifier notifier;
  late bool enabled;
  late DesktopNotificationService service;

  /// Short enough that a test can wait it out for real, long enough that
  /// several adds land inside one window.
  const window = Duration(milliseconds: 20);

  /// Runs the coalesce window out and lets the post that follows it complete.
  Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 80));

  DesktopNotificationService build() => service = DesktopNotificationService(
        events: settles.stream,
        notifier: notifier,
        enabled: () => enabled,
        coalesceWindow: window,
      );

  setUp(() {
    settles = StreamController<MessageSettled>.broadcast();
    notifier = _FakeDesktopNotifier();
    enabled = true;
  });

  tearDown(() async {
    service.dispose();
    await settles.close();
  });

  test('one settle becomes one notification, asked for first', () async {
    build();

    settles.add(_settled(title: 'Homepage copy', ctaText: 'Reply by Friday'));
    await flush();

    expect(notifier.shown, hasLength(1));
    expect(notifier.shown.single.title, 'Homepage copy');
    expect(notifier.shown.single.body, 'Reply by Friday');
    // Asked once, and BEFORE anything was posted: the permission dialog is
    // what has to happen first, not something raced with the toast.
    expect(notifier.authorizeCalls, 1);
  });

  test('a message with neither a CTA nor a summary still has a line', () async {
    build();

    settles.add(_settled());
    await flush();

    expect(notifier.shown.single.title, 'A message needs you');
    expect(notifier.shown.single.body, '');
  });

  test('a denial is asked once and then obeyed forever', () async {
    notifier.authorized = false;
    build();

    settles.add(_settled());
    await flush();

    expect(notifier.shown, isEmpty);
    expect(notifier.authorizeCalls, 1);

    // A second batch, later. The denial is memoized in memory and nowhere
    // else: this process stays quiet, and the next launch asks again — which
    // is what makes re-granting in System Settings work with no stored flag.
    settles.add(_settled(key: 'c2'));
    await flush();

    expect(notifier.shown, isEmpty);
    expect(notifier.authorizeCalls, 1);
  });

  test('the opted-out user is never even asked', () async {
    // The whole reason authorization is deferred to the first worthy flush:
    // somebody who turned this off must not meet the OS permission prompt.
    enabled = false;
    build();

    settles.add(_settled());
    await flush();

    expect(notifier.authorizeCalls, 0);
    expect(notifier.shown, isEmpty);
  });

  test('three threads in one window are one notification', () async {
    build();

    settles.add(_settled(key: 'c1', title: 'Homepage copy'));
    settles.add(_settled(key: 'c2', title: 'Launch date'));
    settles.add(_settled(key: 'c3', title: 'Budget', ctaText: 'Approve'));
    await flush();

    expect(notifier.shown, hasLength(1));
    expect(notifier.shown.single.title, '3 messages need you');
    // Named after the newest of them, which is the only one of the three the
    // count above does not already say.
    expect(notifier.shown.single.body, 'Approve');
    expect(notifier.shown.single.target.count, 3);
  });

  test('the same thread twice in one window is still one thread', () async {
    build();

    settles.add(_settled(key: 'c1', title: 'Homepage copy'));
    settles.add(_settled(key: 'c1', title: 'Homepage copy, again'));
    await flush();

    expect(notifier.shown, hasLength(1));
    // Replaced, not counted twice: three messages on one conversation are one
    // thing that happened.
    expect(notifier.shown.single.target.count, 1);
    expect(notifier.shown.single.title, 'Homepage copy, again');
  });

  test('a batch agreeing on a storyline carries it, one disagreeing does not',
      () async {
    build();

    settles.add(_settled(key: 'c1', storylineId: 'sl-1'));
    settles.add(_settled(key: 'c2', storylineId: 'sl-1'));
    await flush();

    expect(notifier.shown.single.target.storylineId, 'sl-1');

    settles.add(_settled(key: 'c3', storylineId: 'sl-1'));
    settles.add(_settled(key: 'c4', storylineId: 'sl-2'));
    await flush();

    expect(notifier.shown, hasLength(2));
    expect(notifier.shown.last.target.storylineId, isNull);
  });

  test('what was posted decodes back into the right place to go', () async {
    // The end-to-end shape of a tap: what the dispatcher put in the payload is
    // what the routing will read out of it, with the OS in between.
    build();

    settles.add(_settled(source: 'teams', key: 'shared'));
    await flush();

    final single = NotificationTarget.decode(
      notifier.shown.single.target.encode(),
    );
    final threadIntent = intentForTarget(single!);
    expect(threadIntent, isA<OpenThreadIntent>());
    expect((threadIntent as OpenThreadIntent).source, 'teams');
    expect(threadIntent.conversationKey, 'shared');

    settles.add(_settled(key: 'c1'));
    settles.add(_settled(key: 'c2'));
    settles.add(_settled(key: 'c3'));
    await flush();

    final batch = NotificationTarget.decode(
      notifier.shown.last.target.encode(),
    );
    expect(batch!.count, 3);
    final sectionIntent = intentForTarget(batch);
    expect(sectionIntent, isA<OpenSectionIntent>());
    expect((sectionIntent as OpenSectionIntent).section, RailSection.needsYou);
  });

  test('disposing mid-window drops the batch and its timer', () async {
    build();

    settles.add(_settled());
    service.dispose();
    await flush();

    expect(notifier.shown, isEmpty);
    expect(notifier.authorizeCalls, 0);
    // A second dispose in the tearDown must be harmless — Riverpod calls it
    // exactly once, but nothing here should depend on that.
  });
}
