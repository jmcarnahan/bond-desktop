import 'package:bond_inbox/models/drafts_models.dart';
import 'package:bond_inbox/widgets/drafts_pane.dart';
import 'package:bond_inbox/widgets/inline_alert.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The model's outbox and the user's own, side by side.
///
/// Two things this file exists to hold still: an empty section says WHICH
/// section is empty rather than going blank, and a card and its Dismiss are
/// separate targets — the card opens the thread, and a button inside its ink
/// would get hit by accident.

final DateTime _now = DateTime.utc(2026, 9, 3, 12);

PendingDraft _draft({
  String messageId = 'm1',
  String key = 'c1',
  String? who = 'Dana Whitfield',
  String? subject = 'Homepage copy',
  String body = 'Friday works.\nSee you then.',
}) =>
    PendingDraft(
      source: 'email',
      conversationKey: key,
      replyToMessageId: messageId,
      body: body,
      status: 'suggested',
      updatedAt: '2026-09-03T11:00:00Z',
      subject: subject,
      who: who,
    );

SentRow _sent({
  String id = 'o1',
  String key = 'c1',
  List<String> to = const ['dana@example.com'],
  String? preview = 'On it.',
  String? subject = 'Homepage copy',
}) =>
    SentRow(
      source: 'email',
      conversationKey: key,
      messageId: id,
      to: to,
      sentAt: '2026-09-03T11:30:00Z',
      subject: subject,
      preview: preview,
    );

void main() {
  Future<void> pumpPane(
    WidgetTester tester, {
    List<PendingDraft> drafts = const [],
    List<SentRow> sent = const [],
    bool loaded = true,
    String? error,
    void Function(PendingDraft)? onOpenDraft,
    void Function(PendingDraft)? onDismiss,
    void Function(SentRow)? onOpenSent,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DraftsPane(
          drafts: drafts,
          sent: sent,
          loaded: loaded,
          error: error,
          now: _now,
          onOpenDraft: onOpenDraft ?? (_) {},
          onDismiss: onDismiss ?? (_) {},
          onOpenSent: onOpenSent ?? (_) {},
        ),
      ),
    ));
  }

  testWidgets('an unread pane is a spinner, not two empty claims',
      (tester) async {
    await pumpPane(tester, loaded: false);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('No suggested replies waiting.'), findsNothing);
  });

  testWidgets('both sections carry their count', (tester) async {
    await pumpPane(
      tester,
      drafts: [_draft(messageId: 'm1'), _draft(messageId: 'm2', key: 'c2')],
      sent: [_sent()],
    );

    expect(find.text('SUGGESTED'), findsOneWidget);
    expect(find.text('SENT'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('an empty section says which one it is', (tester) async {
    await pumpPane(tester);

    expect(find.text('No suggested replies waiting.'), findsOneWidget);
    expect(find.text('Nothing sent yet.'), findsOneWidget);
  });

  testWidgets('a draft row names who and what, and previews one line',
      (tester) async {
    await pumpPane(tester, drafts: [_draft()]);

    expect(find.text('Dana Whitfield · Homepage copy'), findsOneWidget);
    // The FIRST line: a reply opens with a greeting, and a row running on into
    // the paragraph under it is a row nobody can scan.
    expect(find.text('Friday works.'), findsOneWidget);
  });

  testWidgets('an unnamed draft still says something', (tester) async {
    await pumpPane(tester, drafts: [_draft(who: null, subject: null)]);

    expect(find.text('(unknown) · (no subject)'), findsOneWidget);
  });

  testWidgets('tapping a draft card opens its thread', (tester) async {
    PendingDraft? opened;
    await pumpPane(
      tester,
      drafts: [_draft()],
      onOpenDraft: (d) => opened = d,
    );

    await tester.tap(find.byKey(DraftsPane.draftKeyFor('email', 'm1')));
    await tester.pump();

    expect(opened?.replyToMessageId, 'm1');
  });

  testWidgets('Dismiss is its own target and fires with its own draft',
      (tester) async {
    PendingDraft? dismissed;
    PendingDraft? opened;
    await pumpPane(
      tester,
      drafts: [_draft(messageId: 'm1'), _draft(messageId: 'm2', key: 'c2')],
      onOpenDraft: (d) => opened = d,
      onDismiss: (d) => dismissed = d,
    );

    await tester.tap(find.byKey(DraftsPane.dismissKeyFor('email', 'm2')));
    await tester.pump();

    expect(dismissed?.replyToMessageId, 'm2');
    // The card underneath was not opened by the same press.
    expect(opened, isNull);
  });

  testWidgets('a sent row names its recipient and opens its thread',
      (tester) async {
    SentRow? opened;
    await pumpPane(tester, sent: [_sent()], onOpenSent: (s) => opened = s);

    expect(find.text('dana@example.com · Homepage copy'), findsOneWidget);

    await tester.tap(find.byKey(DraftsPane.sentKeyFor('email', 'o1')));
    await tester.pump();

    expect(opened?.messageId, 'o1');
  });

  testWidgets('several recipients collapse to the first plus a count',
      (tester) async {
    await pumpPane(
      tester,
      sent: [
        _sent(to: const ['dana@example.com', 'eric@example.com']),
      ],
    );

    expect(find.text('dana@example.com +1 · Homepage copy'), findsOneWidget);
  });

  testWidgets('a failed re-read is said over the list, not instead of it',
      (tester) async {
    await pumpPane(
      tester,
      sent: [_sent()],
      error: "Couldn't read your drafts just now — showing what was already here.",
    );

    expect(find.byType(InlineAlert), findsOneWidget);
    expect(find.textContaining("Couldn't read your drafts"), findsOneWidget);
    // The row it already had is still there under the banner.
    expect(find.textContaining('Homepage copy'), findsOneWidget);
  });

  testWidgets('a message with nobody on it is titled by its subject alone',
      (tester) async {
    // A chat: the Teams connector stores no recipients, because the chat's
    // subject already names everyone in it.
    await pumpPane(tester, sent: [_sent(to: const [])]);

    expect(find.text('Homepage copy'), findsOneWidget);
    expect(find.textContaining('(no recipient)'), findsNothing);
  });

  testWidgets('an echo says it is still syncing', (tester) async {
    await pumpPane(tester, sent: [_sent(id: 'local:abc')]);

    // The Sent Items copy has not landed yet. The row is real mail with a
    // provisional id, so it shows with a caveat rather than not at all.
    expect(
      find.textContaining('syncing'),
      findsOneWidget,
    );
  });

  testWidgets('a server copy carries no caveat', (tester) async {
    await pumpPane(tester, sent: [_sent(id: 'AAMk-real')]);

    expect(find.textContaining('syncing'), findsNothing);
  });
}
