import 'package:bond_inbox/services/draft_stream.dart';
import 'package:bond_inbox/services/event_bus.dart';
import 'package:bond_inbox/services/progress_bus.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one rule both buses in this app publish under, checked once.
///
/// The interesting property is not that a broadcast stream works — it is that
/// a producer can publish onto a disposed or disabled bus and carry on. Both
/// buses sit on hot paths (a stage write, a token arriving), and a bus that
/// could throw would be a queue that fails because nobody was watching it.

void main() {
  group('EventBus', () {
    test('a disabled bus says so, and swallows everything', () async {
      const bus = EventBus<String>.disabled();

      expect(bus.enabled, isFalse);
      expect(() => bus.publish('anything'), returnsNormally);
      expect(await bus.stream.toList(), isEmpty);
      expect(() => bus.dispose(), returnsNormally);
    });

    test('a live bus delivers to every listener', () async {
      final bus = EventBus<String>();
      addTearDown(bus.dispose);

      expect(bus.enabled, isTrue);
      final first = bus.stream.take(2).toList();
      final second = bus.stream.take(2).toList();
      bus.publish('one');
      bus.publish('two');

      expect(await first, ['one', 'two']);
      expect(await second, ['one', 'two']);
    });

    test('publishing after dispose is dropped, not raised', () {
      final bus = EventBus<String>();
      bus.dispose();

      expect(() => bus.publish('too late'), returnsNormally);
    });
  });

  group('ProgressBus', () {
    test('still streams ticks under its own name', () async {
      final bus = ProgressBus();
      addTearDown(bus.dispose);

      final ticks = bus.ticks.take(1).toList();
      bus.publish(const ProgressTick(
        source: 'email',
        sourceMessageId: 'm1',
        stage: 'triage',
        state: 'done',
        receivedAt: '2026-09-17T10:00:00Z',
      ));

      expect((await ticks).single.stage, 'triage');
    });

    test('the disabled one is still const-constructible', () {
      // The default every instrumented constructor takes.
      const bus = ProgressBus.disabled();
      expect(bus.enabled, isFalse);
    });
  });

  group('DraftStreamBus', () {
    test('is an EventBus of draft events, disabled twin included', () async {
      const off = DraftStreamBus.disabled();
      expect(off.enabled, isFalse);

      final bus = DraftStreamBus();
      addTearDown(bus.dispose);
      final events = bus.stream.take(2).toList();
      bus.publish(const DraftStreamEvent(
        source: 'email',
        conversationKey: 'k1',
        sourceMessageId: 'm1',
        path: 'reply_body',
        delta: 'Hi',
      ));
      bus.publish(const DraftStreamEvent.done(
        source: 'email',
        conversationKey: 'k1',
        sourceMessageId: 'm1',
      ));

      final seen = await events;
      expect(seen.first.delta, 'Hi');
      expect(seen.first.done, isFalse);
      expect(seen.last.done, isTrue);
      expect(seen.last.path, isEmpty);
    });
  });
}
