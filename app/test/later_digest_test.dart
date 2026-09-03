import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/later_digest.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation _conv({
  required String id,
  String? who,
  String? email,
  String? subject,
  String? preview,
  String? cta,
  String bucket = 'later',
  ConversationState state = ConversationState.waiting,
  String lastMessageAt = '2026-01-14T10:00:00',
}) {
  return Conversation(
    id: id,
    subject: subject,
    participants:
        who == null ? const [] : [Participant(name: who, email: email)],
    state: state,
    ctaText: cta,
    lastMessagePreview: preview,
    bucket: bucket,
    lastMessageAt: lastMessageAt,
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<Conversation> conversations,
    String? dayFilter,
    void Function(String, String)? onOpen,
    void Function(String, String)? onKeepSender,
    void Function(String, String)? onKeepThread,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LaterDigestPanel(
          conversations: conversations,
          dayFilter: dayFilter,
          onOpen: onOpen ?? (_, _) {},
          onKeepSender: onKeepSender ?? (_, _) {},
          onKeepThread: onKeepThread ?? (_, _) {},
        ),
      ),
    ));
  }

  testWidgets('nothing deferred says so', (tester) async {
    await pump(tester, conversations: [_conv(id: 'a', bucket: '')]);
    expect(find.text('Nothing deferred.'), findsOneWidget);
  });

  testWidgets('every deferred thread is visible — nothing is collapsed away',
      (tester) async {
    await pump(tester, conversations: [
      for (var i = 0; i < 6; i++)
        _conv(
          id: 'c$i',
          who: 'Alice',
          email: 'alice@x.com',
          subject: 'Subject $i',
        ),
    ]);

    // The promise Later makes: it is a reading order, not a filter.
    for (var i = 0; i < 6; i++) {
      expect(find.text('Subject $i'), findsOneWidget);
    }
  });

  testWidgets('one sender name per group, however many rows it has',
      (tester) async {
    await pump(tester, conversations: [
      _conv(id: 'a', who: 'Alice', email: 'alice@x.com', subject: 'One'),
      _conv(id: 'b', who: 'Alice', email: 'alice@x.com', subject: 'Two'),
      _conv(id: 'c', who: 'Bruno', email: 'bruno@y.com', subject: 'Three'),
    ]);

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bruno'), findsOneWidget);
    expect(find.text('One'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
  });

  testWidgets('reply prefixes are stripped off the subject', (tester) async {
    await pump(tester, conversations: [
      _conv(id: 'a', who: 'Alice', subject: 'Re: Fwd: Rate sheet'),
    ]);

    expect(find.text('Rate sheet'), findsOneWidget);
  });

  testWidgets('a thread with no subject still renders a line', (tester) async {
    await pump(tester, conversations: [_conv(id: 'a', who: 'Alice')]);
    expect(find.text('(no subject)'), findsOneWidget);
  });

  testWidgets('the CTA wins over the preview when there is one',
      (tester) async {
    await pump(tester, conversations: [
      _conv(
        id: 'a',
        who: 'Alice',
        subject: 'Sub',
        preview: 'the preview',
        cta: 'the ask',
      ),
      _conv(id: 'b', who: 'Bruno', subject: 'Sub2', preview: 'just a preview'),
    ]);

    expect(find.text('the ask'), findsOneWidget);
    expect(find.text('the preview'), findsNothing);
    expect(find.text('just a preview'), findsOneWidget);
  });

  group('day grouping', () {
    final twoDays = [
      _conv(
        id: 'a',
        who: 'Alice',
        subject: 'Thursday mail',
        lastMessageAt: '2026-01-15T10:00:00',
      ),
      _conv(
        id: 'b',
        who: 'Bruno',
        subject: 'Wednesday mail',
        lastMessageAt: '2026-01-14T10:00:00',
      ),
    ];

    testWidgets('no filter renders a header per day, newest first',
        (tester) async {
      await pump(tester, conversations: twoDays);

      expect(find.text('THU, JAN 15'), findsOneWidget);
      expect(find.text('WED, JAN 14'), findsOneWidget);
      expect(find.text('Thursday mail'), findsOneWidget);
      expect(find.text('Wednesday mail'), findsOneWidget);
    });

    testWidgets('a day filter shows only that day and drops the header',
        (tester) async {
      await pump(tester, conversations: twoDays, dayFilter: '2026-01-14');

      expect(find.text('Wednesday mail'), findsOneWidget);
      expect(find.text('Thursday mail'), findsNothing);
      // The caller already named the day above the panel.
      expect(find.text('WED, JAN 14'), findsNothing);
    });

    testWidgets('a filter matching nothing says so rather than going blank',
        (tester) async {
      await pump(tester, conversations: twoDays, dayFilter: '2020-01-01');
      expect(find.text('Nothing deferred.'), findsOneWidget);
    });

    testWidgets('mail with an unreadable date still shows, under Undated',
        (tester) async {
      await pump(tester, conversations: [
        _conv(
          id: 'a',
          who: 'Alice',
          subject: 'Broken date',
          lastMessageAt: 'wharrgarbl',
        ),
      ]);

      expect(find.text('UNDATED'), findsOneWidget);
      expect(find.text('Broken date'), findsOneWidget);
    });
  });

  group('actions', () {
    testWidgets('Keep in inbox fires with the sender ADDRESS and its source',
        (tester) async {
      final kept = <(String, String)>[];
      await pump(
        tester,
        conversations: [
          _conv(id: 'a', who: 'Alice', email: 'alice@x.com', subject: 'One'),
          _conv(id: 'b', who: 'Alice', email: 'alice@x.com', subject: 'Two'),
        ],
        onKeepSender: (address, source) => kept.add((address, source)),
      );

      // One button for the whole group: the correction is sender-scoped, and
      // two rows from one sender is not two decisions. The source rides along
      // so the rule re-files the rows it actually applies to.
      expect(find.text('Keep in inbox'), findsOneWidget);
      await tester.tap(find.text('Keep in inbox'));
      expect(kept, [('alice@x.com', 'email')]);
    });

    testWidgets('a sender with no address gets no sender-scoped button',
        (tester) async {
      // A rule keyed on the empty string would apply to every anonymous
      // sender at once.
      await pump(tester, conversations: [
        _conv(id: 'a', who: 'Alice', subject: 'One'),
      ]);

      expect(find.text('Keep in inbox'), findsNothing);
    });

    testWidgets('Just this thread fires with the thread it sits on',
        (tester) async {
      final kept = <(String, String)>[];
      await pump(
        tester,
        conversations: [
          _conv(id: 'a', who: 'Alice', email: 'alice@x.com', subject: 'One'),
          _conv(id: 'b', who: 'Alice', email: 'alice@x.com', subject: 'Two'),
        ],
        onKeepThread: (source, key) => kept.add((source, key)),
      );

      await tester.tap(find.byIcon(Icons.more_horiz).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Just this thread'));
      await tester.pumpAndSettle();

      expect(kept, [('email', 'b')]);
    });

    testWidgets('tapping a line opens that thread', (tester) async {
      final opened = <(String, String)>[];
      await pump(
        tester,
        conversations: [
          _conv(id: 'a', who: 'Alice', email: 'alice@x.com', subject: 'One'),
        ],
        onOpen: (source, id) => opened.add((source, id)),
      );

      await tester.tap(find.text('One'));
      // With the source, for the same reason the keep-thread action carries
      // one: the id alone does not say which connector's thread this is.
      expect(opened, [('email', 'a')]);
    });
  });
}
