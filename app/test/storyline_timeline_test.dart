import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/widgets/attachment_documents_strip.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/inline_alert.dart';
import 'package:bond_inbox/widgets/message_row.dart';
import 'package:bond_inbox/widgets/pinned_documents_bar.dart';
import 'package:bond_inbox/widgets/room_header.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

Message _message({
  required String id,
  required String receivedAt,
  String from = 'Sarah Chen',
  String address = 'sarah@example.com',
  String? body,
  String source = 'email',
  bool outbound = false,
  bool? needsAction,
  List<String> actionItems = const [],
  String? deadline,
  List<AttachmentRef> attachments = const [],
}) =>
    Message(
      id: id,
      source: source,
      outbound: outbound,
      fromName: from,
      fromAddress: address,
      receivedAt: receivedAt,
      bodyText: body ?? 'body of $id',
      needsAction: needsAction,
      actionItems: actionItems,
      deadline: deadline,
      attachments: attachments,
    );

StorylineEpisode _episode({
  required String key,
  required List<Message> messages,
  String source = 'email',
  String subject = '',
  List<String> participants = const ['Sarah Chen'],
  String? latestAt,
  String? summary,
  ConversationState state = ConversationState.waiting,
  String? ctaText,
}) =>
    StorylineEpisode(
      source: source,
      conversationKey: key,
      subject: subject,
      participants: participants,
      messages: messages,
      latestAt: latestAt ?? messages.last.receivedAt,
      summary: summary,
      state: state,
      ctaText: ctaText,
    );

const _storyline = Storyline(
  id: 'sl-1',
  title: 'Website redesign',
  summary: 'The studio is reviewing the homepage copy.',
  status: 'active',
  memberCount: 2,
);

/// The same storyline once someone has written down what belongs in it.
const _chartered = Storyline(
  id: 'sl-1',
  title: 'Website redesign',
  summary: 'The studio is reviewing the homepage copy.',
  status: 'active',
  charter: 'Threads about the new homepage and its launch.',
  charterLocked: true,
  memberCount: 2,
);

/// The same storyline once the recap pass has caught the reader up.
///
/// The watermark is relative to now rather than a calendar date: the header
/// dates the paragraph with `relativeTime`, and a pinned date would answer
/// differently every day the suite runs.
Storyline _recapped({
  String recapText =
      'The studio cut the hero paragraph and the launch slipped a week.',
  String? openJson = '["Who signs off the new hero copy?"]',
  String? decidedJson = '["Launch moved to the 14th."]',
  String? charterSuggestion,
}) =>
    Storyline(
      id: 'sl-1',
      title: 'Website redesign',
      summary: 'The studio is reviewing the homepage copy.',
      status: 'active',
      charter: 'Threads about the new homepage and its launch.',
      charterLocked: true,
      charterSuggestion: charterSuggestion,
      recapText: recapText,
      recapOpenJson: openJson,
      recapDecisionsJson: decidedJson,
      recapThrough:
          DateTime.now().subtract(const Duration(hours: 3)).toIso8601String(),
      memberCount: 2,
    );

void main() {
  // Two member threads, oldest activity first: the homepage thread ran in the
  // morning, the launch thread answered later. Newest last is what the panel is
  // handed and what it renders.
  final homepage = _episode(
    key: 'c1',
    subject: 'Homepage copy',
    summary: 'The studio wants the hero paragraph cut.',
    messages: [
      _message(id: 'm1', receivedAt: '2026-08-01T09:00:00Z'),
      _message(id: 'm3', receivedAt: '2026-08-01T09:02:00Z'),
    ],
  );
  final launch = _episode(
    key: 'c2',
    subject: 'Launch date',
    messages: [_message(id: 'm2', receivedAt: '2026-08-01T10:00:00Z')],
  );
  final episodes = [homepage, launch];

  const members = [
    StorylineMember(
      storylineId: 'sl-1',
      conversationKey: 'c1',
      addedBy: 'auto',
      evidence: 'Both concern the website redesign.',
    ),
    StorylineMember(
      storylineId: 'sl-1',
      conversationKey: 'c2',
      addedBy: 'user',
    ),
  ];

  Future<void> pumpPanel(
    WidgetTester tester, {
    Storyline storyline = _storyline,
    List<StorylineEpisode>? only,
    List<StorylineMember>? withMembers,
    void Function(String title)? onRename,
    void Function(String charter)? onSetCharter,
    void Function(String charter)? onAcceptSuggestion,
    VoidCallback? onDismissSuggestion,
    void Function(String source, String key)? onRemoveThread,
    void Function(String source, String key)? onOpenThread,
    void Function(StorylineEpisode episode)? onOpenEpisode,
    VoidCallback? onBack,
    VoidCallback? onAddThread,
    bool newestFirst = false,
    VoidCallback? onToggleSort,
    VoidCallback? onDismiss,
    Future<void> Function()? onSync,
    bool syncing = false,
    List<AttachmentRef> documents = const [],
    void Function(AttachmentRef attachment)? onOpenDocument,
    void Function(AttachmentRef attachment)? onPinDocument,
    void Function(AttachmentRef attachment)? onUnpinDocument,
    List<StorylineBlock> blocks = const [],
    void Function(String source, String key)? onUnblockThread,
    void Function(String source, String key)? onAddBackThread,
    VoidCallback? onAudit,
    bool auditing = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StorylineTimelinePanel(
          storyline: storyline,
          episodes: only ?? episodes,
          members: withMembers ?? members,
          onBack: onBack,
          onRename: onRename ?? (_) {},
          onSetCharter: onSetCharter ?? (_) {},
          onAcceptSuggestion: onAcceptSuggestion ?? (_) {},
          onDismissSuggestion: onDismissSuggestion ?? () {},
          onRemoveThread: onRemoveThread ?? (_, _) {},
          onOpenThread: onOpenThread ?? (_, _) {},
          onOpenEpisode: onOpenEpisode ?? (_) {},
          onAddThread: onAddThread ?? () {},
          newestFirst: newestFirst,
          onToggleSort: onToggleSort ?? () {},
          onDismiss: onDismiss ?? () {},
          onSync: onSync ?? () async {},
          syncing: syncing,
          documents: documents,
          onOpenDocument: onOpenDocument,
          onPinDocument: onPinDocument,
          onUnpinDocument: onUnpinDocument,
          blocks: blocks,
          onUnblockThread: onUnblockThread,
          onAddBackThread: onAddBackThread,
          onAudit: onAudit,
          auditing: auditing,
        ),
      ),
    ));
  }

  /// Opens the header's ⋯ and waits for the menu route to arrive. Sort, Sync
  /// and Dismiss live in there now: they are corrections and housekeeping, not
  /// part of reading a storyline.
  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(find.byKey(RoomHeader.moreKey));
    await tester.pumpAndSettle();
  }

  /// Selects one of the header's tabs.
  Future<void> openTab(WidgetTester tester, StorylineTab tab) async {
    await tester.tap(find.byKey(RoomHeader.tabKey(tab)));
    await tester.pumpAndSettle();
  }

  group('header', () {
    testWidgets('shows the title and what the storyline holds',
        (tester) async {
      await pumpPanel(tester);

      expect(find.text('Website redesign'), findsOneWidget);
      // The subtitle is the room's size, in one line. The summary moved to the
      // Messages tab, where it is the first thing read rather than a caption
      // wedged under the name.
      expect(find.text('2 threads · 0 open'), findsOneWidget);
      expect(find.text('The studio is reviewing the homepage copy.'),
          findsOneWidget);
    });

    testWidgets('the three tabs are there and Messages is the one that opens',
        (tester) async {
      await pumpPanel(tester);

      expect(find.text('Messages'), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
      // Messages is what a storyline is for; the other two are reference.
      expect(find.text('✉ Homepage copy'), findsOneWidget);
    });

    testWidgets('a tab swaps the body rather than stacking on it',
        (tester) async {
      await pumpPanel(tester, documents: [ref(name: 'Quote.pdf')]);

      await openTab(tester, StorylineTab.files);
      expect(find.byKey(StorylineTimelinePanel.documentsStripKey),
          findsOneWidget);
      expect(find.text('✉ Homepage copy'), findsNothing);

      await openTab(tester, StorylineTab.about);
      expect(find.byKey(StorylineTimelinePanel.documentsStripKey), findsNothing);
      // About is the charter alone now: the membership is read on the spine,
      // one line per card.
      expect(find.text('CHARTER'), findsOneWidget);
      expect(find.textContaining('THREADS ·'), findsNothing);

      await openTab(tester, StorylineTab.messages);
      expect(find.text('✉ Homepage copy'), findsOneWidget);
    });

    testWidgets('the back arrow is absent when there is nowhere to go back to',
        (tester) async {
      await pumpPanel(tester);
      expect(find.byIcon(Icons.arrow_back), findsNothing);

      await pumpPanel(tester, onBack: () {});
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    });

    testWidgets('the ⋯ offers Sync and fires it', (tester) async {
      var synced = 0;
      await pumpPanel(tester, onSync: () async => synced++);

      // Not on the header itself: it is the only control here that is not
      // about this storyline in particular.
      expect(find.text('Sync'), findsNothing);

      await openMore(tester);
      expect(find.text('Sync'), findsOneWidget);

      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();

      expect(synced, 1);
    });

    testWidgets('a running sync is inert and says so', (tester) async {
      var synced = 0;
      await pumpPanel(tester, onSync: () async => synced++, syncing: true);

      await openMore(tester);

      // The screen owns the flag, so the panel's only job is to say what it
      // is being told and to stop asking for a second pull.
      expect(find.text('Syncing…'), findsOneWidget);
      expect(find.text('Sync'), findsNothing);

      await tester.tap(find.text('Syncing…'));
      await tester.pumpAndSettle();

      expect(synced, 0);
    });
  });

  group('the spine', () {
    testWidgets('is one card per episode, in the order it was given',
        (tester) async {
      await pumpPanel(tester);

      // The source is marked on both, mail included: an unmarked card leaves
      // the reader guessing what it was.
      final homepageCard = find.text('✉ Homepage copy');
      final launchCard = find.text('✉ Launch date');
      expect(homepageCard, findsOneWidget);
      expect(launchCard, findsOneWidget);
      expect(
        tester.getTopLeft(homepageCard).dy,
        lessThan(tester.getTopLeft(launchCard).dy),
      );
    });

    testWidgets('newest first flips the spine', (tester) async {
      await pumpPanel(tester, newestFirst: true);

      final homepageCard = find.text('✉ Homepage copy');
      final launchCard = find.text('✉ Launch date');
      expect(
        tester.getTopLeft(launchCard).dy,
        lessThan(tester.getTopLeft(homepageCard).dy),
      );
    });

    testWidgets('the sort item names the order it switches TO',
        (tester) async {
      var toggled = 0;
      await pumpPanel(tester, onToggleSort: () => toggled++);

      // A menu item says what it DOES. The old button named the order the
      // spine was already in, which read as a statement you could not act on.
      await openMore(tester);
      expect(find.text('Newest first'), findsOneWidget);
      expect(find.text('Oldest first'), findsNothing);

      await tester.tap(find.text('Newest first'));
      await tester.pumpAndSettle();

      // The host owns the preference, so the label only follows a rebuild
      // with the new value.
      expect(toggled, 1);

      await pumpPanel(tester, newestFirst: true);
      await openMore(tester);
      expect(find.text('Oldest first'), findsOneWidget);
    });

    testWidgets('tapping a card opens the thread it stands for',
        (tester) async {
      final opened = <String>[];
      await pumpPanel(
        tester,
        onOpenEpisode: (episode) => opened.add(episode.conversationKey),
      );

      await tester.tap(find.text('✉ Homepage copy'));
      await tester.pump();

      // A card is a root message, not a drawer: the tap opens the thread
      // beside the spine, where the transcript and the reply box are.
      expect(opened, ['c1']);
      expect(find.byType(MessageRow), findsNothing);
    });

    testWidgets('and says how much of the thread is behind it', (tester) async {
      await pumpPanel(tester);

      expect(find.text('2 messages · open ›'), findsOneWidget);
      expect(find.text('1 message · open ›'), findsOneWidget);
    });

    testWidgets('every card previews the newest message in its thread',
        (tester) async {
      await pumpPanel(tester);

      // m3 is the homepage thread's last message and m2 the launch thread's.
      // Both cards carry their own, always: there is no open state left for a
      // preview to be the alternative to.
      expect(find.text('body of m3'), findsOneWidget);
      expect(find.text('body of m2'), findsOneWidget);
      expect(find.text('body of m1'), findsNothing);
    });

    testWidgets('the summary rides on the card, and its absence is quiet',
        (tester) async {
      await pumpPanel(tester);

      expect(find.text('The studio wants the hero paragraph cut.'),
          findsOneWidget);
      // The launch episode has no summary at all, which is a card with one
      // line fewer rather than an empty one.
      expect(tester.takeException(), isNull);
      expect(find.text('✉ Launch date'), findsOneWidget);
    });

    testWidgets('nothing left of the seam pills', (tester) async {
      await pumpPanel(tester);

      // The seam is the card boundary now. A pill at every thread change was
      // the merged transcript's way of coping and it went with it. The only
      // pills left on this panel are the header's three tabs.
      expect(find.byType(BondFilterPill), findsNWidgets(3));
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(BondFilterPill),
        ),
        findsNothing,
      );
    });

    testWidgets('an empty storyline says so rather than going blank',
        (tester) async {
      await pumpPanel(tester, only: const []);

      expect(find.text('No messages in this storyline.'), findsOneWidget);
    });
  });

  group('the ask on a card', () {
    testWidgets('a thread that needs a reply says what it is waiting for',
        (tester) async {
      final asking = _episode(
        key: 'c1',
        subject: 'Homepage copy',
        summary: 'The studio wants the hero paragraph cut.',
        state: ConversationState.needsReply,
        ctaText: 'Confirm the hero paragraph can go — by Friday',
        messages: [_message(id: 'm1', receivedAt: '2026-08-01T09:00:00Z')],
      );
      await pumpPanel(tester, only: [asking]);

      expect(find.byType(InlineAlert), findsOneWidget);
      expect(find.text('Confirm the hero paragraph can go — by Friday'),
          findsOneWidget);
      // The ask replaces the summary rather than stacking on it — the same
      // fact in two moods, and the card only has room for one of them.
      expect(find.text('The studio wants the hero paragraph cut.'),
          findsNothing);
    });

    testWidgets('a waiting thread shows its summary and no ask',
        (tester) async {
      final waiting = _episode(
        key: 'c1',
        subject: 'Homepage copy',
        summary: 'The studio wants the hero paragraph cut.',
        // The thread panel's rule, shared: a thread that no longer needs the
        // user shows no CTA anywhere, even though the text is still on the row.
        ctaText: 'Confirm the hero paragraph can go — by Friday',
        messages: [_message(id: 'm1', receivedAt: '2026-08-01T09:00:00Z')],
      );
      await pumpPanel(tester, only: [waiting]);

      expect(find.byType(InlineAlert), findsNothing);
      expect(find.text('The studio wants the hero paragraph cut.'),
          findsOneWidget);
    });

    testWidgets('a needs-reply thread with no ask keeps its summary',
        (tester) async {
      final asking = _episode(
        key: 'c1',
        subject: 'Homepage copy',
        summary: 'The studio wants the hero paragraph cut.',
        state: ConversationState.needsReply,
        messages: [_message(id: 'm1', receivedAt: '2026-08-01T09:00:00Z')],
      );
      await pumpPanel(tester, only: [asking]);

      expect(find.byType(InlineAlert), findsNothing);
      expect(find.text('The studio wants the hero paragraph cut.'),
          findsOneWidget);
    });

    testWidgets('the banner counts the older asks still open', (tester) async {
      final asking = _episode(
        key: 'c1',
        subject: 'Homepage copy',
        state: ConversationState.needsReply,
        ctaText: 'Confirm attendance',
        messages: [
          _message(
            id: 'm1',
            receivedAt: '2026-08-01T09:00:00Z',
            needsAction: true,
            actionItems: ['Send the deck'],
          ),
          _message(
            id: 'm2',
            receivedAt: '2026-08-01T09:30:00Z',
            needsAction: true,
            actionItems: ['Confirm attendance'],
          ),
        ],
      );
      await pumpPanel(tester, only: [asking]);

      expect(find.text('Confirm attendance · 2 open asks'), findsOneWidget);
    });

    testWidgets('one open ask leaves the banner as the ask itself',
        (tester) async {
      final asking = _episode(
        key: 'c1',
        subject: 'Homepage copy',
        state: ConversationState.needsReply,
        ctaText: 'Confirm attendance',
        messages: [
          _message(
            id: 'm1',
            receivedAt: '2026-08-01T09:00:00Z',
            needsAction: true,
            actionItems: ['Send the deck'],
          ),
        ],
      );
      await pumpPanel(tester, only: [asking]);

      expect(find.text('Confirm attendance'), findsOneWidget);
      expect(find.textContaining('open asks'), findsNothing);
    });

    testWidgets('and the banner does not swallow the card', (tester) async {
      final asking = _episode(
        key: 'c1',
        subject: 'Homepage copy',
        state: ConversationState.needsReply,
        ctaText: 'Confirm attendance',
        messages: [_message(id: 'm1', receivedAt: '2026-08-01T09:00:00Z')],
      );
      final opened = <String>[];
      await pumpPanel(
        tester,
        only: [asking],
        onOpenEpisode: (episode) => opened.add(episode.conversationKey),
      );

      // The ask used to take its own tap, to reach a reply box on the spine.
      // There is no box there now, so the banner is a statement and the tap
      // means what every other part of the card means: open the thread.
      await tester.tap(find.text('Confirm attendance'));
      await tester.pump();

      expect(opened, ['c1']);
    });
  });

  group('card actions', () {
    testWidgets('Open thread reports the source as well as the key',
        (tester) async {
      final opened = <String>[];
      final chat = _episode(
        key: 'chat-1',
        source: 'teams',
        subject: 'Sarah Whitfield',
        messages: [
          _message(
            id: 't1',
            source: 'teams',
            receivedAt: '2026-08-01T11:00:00Z',
          ),
        ],
      );
      await pumpPanel(
        tester,
        only: [homepage, chat],
        onOpenThread: (source, key) => opened.add('$source/$key'),
      );

      // A key is only unique within its connector: dropping the source is how
      // a chat card opened a mail thread.
      await tester.tap(find.byTooltip('Open thread').last);

      expect(opened, ['teams/chat-1']);
    });

    testWidgets('the close icon asks before it removes that thread',
        (tester) async {
      final removed = <String>[];
      await pumpPanel(
        tester,
        onRemoveThread: (source, key) => removed.add('$source/$key'),
      );

      await tester.tap(find.byTooltip('Remove from storyline').first);
      await tester.pumpAndSettle();

      // The first tap only arms. A × sitting next to Open thread is one slip
      // away from taking a thread out of a group nobody meant to touch.
      expect(removed, isEmpty);
      expect(find.text('Remove thread'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.text('Remove thread'));
      await tester.pumpAndSettle();

      expect(removed, ['email/c1']);
    });

    testWidgets('and takes no for an answer, twice over', (tester) async {
      final removed = <String>[];
      await pumpPanel(
        tester,
        onRemoveThread: (source, key) => removed.add('$source/$key'),
      );

      await tester.tap(find.byTooltip('Remove from storyline').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(removed, isEmpty);
      expect(find.text('Remove thread'), findsNothing);

      // Disarmed, not spent: the × still asks the next time it is tapped.
      await tester.tap(find.byTooltip('Remove from storyline').first);
      await tester.pumpAndSettle();

      expect(find.text('Remove thread'), findsOneWidget);
    });

    testWidgets('and only the card that was tapped asks anything',
        (tester) async {
      await pumpPanel(tester);

      // Two cards on the spine; arming one must leave the other's icons alone,
      // or the whole panel would look like it was about to lose everything.
      expect(find.byTooltip('Remove from storyline'), findsNWidgets(2));

      await tester.tap(find.byTooltip('Remove from storyline').first);
      await tester.pumpAndSettle();

      expect(find.text('Remove thread'), findsOneWidget);
      expect(find.byTooltip('Remove from storyline'), findsOneWidget);
      expect(find.byTooltip('Open thread'), findsOneWidget);
    });
  });

  group('dismiss', () {
    testWidgets('asks before it retires anything, and takes no for an answer',
        (tester) async {
      var dismissed = 0;
      await pumpPanel(tester, onDismiss: () => dismissed++);

      await openMore(tester);
      await tester.tap(find.text('Dismiss…'));
      await tester.pumpAndSettle();

      // The question stands under the header, not inside the menu: a two-step
      // that asked its second question in a popup would ask it somewhere the
      // first answer is no longer visible.
      expect(find.text('Dismiss this storyline?'), findsOneWidget);
      expect(find.text('Dismiss storyline'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(dismissed, 0);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Dismiss this storyline?'), findsNothing);
      expect(find.text('Dismiss storyline'), findsNothing);
      expect(dismissed, 0);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('the second tap is what retires it', (tester) async {
      var dismissed = 0;
      await pumpPanel(tester, onDismiss: () => dismissed++);

      await openMore(tester);
      await tester.tap(find.text('Dismiss…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dismiss storyline'));
      await tester.pumpAndSettle();

      expect(dismissed, 1);
      // The confirmation is a pair of buttons under the header, not a popup
      // over it — the same rule the rest of this panel follows.
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('rename', () {
    testWidgets('tapping the title opens a field that commits on submit',
        (tester) async {
      final renamed = <String>[];
      await pumpPanel(tester, onRename: renamed.add);

      await tester.tap(find.text('Website redesign'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Brightsea launch');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(renamed, ['Brightsea launch']);
    });

    testWidgets('an empty rename is a cancel', (tester) async {
      final renamed = <String>[];
      await pumpPanel(tester, onRename: renamed.add);

      await tester.tap(find.text('Website redesign'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(renamed, isEmpty);
      expect(find.text('Website redesign'), findsOneWidget);
    });

    testWidgets('submitting the same title writes nothing', (tester) async {
      final renamed = <String>[];
      await pumpPanel(tester, onRename: renamed.add);

      await tester.tap(find.text('Website redesign'));
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(renamed, isEmpty);
    });
  });

  group('evidence on the card', () {
    testWidgets('the model reasoning reads inline, not in a dialog',
        (tester) async {
      // On the spine, where the thread it explains is — the strip on a
      // reference tab said the same thing a tab away from the cards.
      await pumpPanel(tester);

      final evidence =
          find.byKey(StorylineTimelinePanel.evidenceKeyFor('email', 'c1'));
      expect(evidence, findsOneWidget);
      expect(
        tester.widget<Text>(evidence).data,
        'Both concern the website redesign.',
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('a hand-filed thread says so', (tester) async {
      // A thread a person filed has no model reasoning to show, and inventing
      // one would be worse than saying who did it.
      await pumpPanel(tester);

      expect(
        tester
            .widget<Text>(
              find.byKey(StorylineTimelinePanel.evidenceKeyFor('email', 'c2')),
            )
            .data,
        'Filed by you',
      );
    });

    testWidgets('an automatic member with no sentence says nothing',
        (tester) async {
      // 'Grouped automatically.' was filler: it said only what the absence of
      // a name already said.
      await pumpPanel(
        tester,
        withMembers: const [
          StorylineMember(
            storylineId: 'sl-1',
            conversationKey: 'c1',
            addedBy: 'auto',
          ),
        ],
      );

      expect(
        find.byKey(StorylineTimelinePanel.evidenceKeyFor('email', 'c1')),
        findsNothing,
      );
    });

    testWidgets('is a read-only explanation — no tick, no way out',
        (tester) async {
      await pumpPanel(tester);

      // Hiding a thread was a view filter nobody could tell from a removal.
      // The removal gesture is the card's own ×, beside the messages that show
      // whether the thread belongs; the evidence line itself answers nothing.
      expect(find.byType(Checkbox), findsNothing);
      expect(
        find.ancestor(
          of: find.byKey(StorylineTimelinePanel.evidenceKeyFor('email', 'c1')),
          matching: find.byType(TextButton),
        ),
        findsNothing,
      );
      // Two cards carry one remove each.
      expect(find.byTooltip('Remove from storyline'), findsNWidgets(2));
    });

    testWidgets('reads a member by its own connector, not by a key twin',
        (tester) async {
      // One conversation key under two connectors — legal, since keys are
      // only unique within the connector that issued them. Each card must
      // take its reason from ITS member row, not whichever twin a lookup on
      // the bare key happens to find first.
      final mailTwin = _episode(
        key: 'shared-1',
        subject: 'Homepage copy',
        messages: [_message(id: 'm1', receivedAt: '2026-08-01T09:00:00Z')],
      );
      final chatTwin = _episode(
        key: 'shared-1',
        source: 'teams',
        subject: 'Sarah Whitfield',
        messages: [_message(id: 'm2', receivedAt: '2026-08-01T10:00:00Z')],
      );
      await pumpPanel(
        tester,
        only: [mailTwin, chatTwin],
        withMembers: const [
          StorylineMember(
            storylineId: 'sl-1',
            conversationKey: 'shared-1',
            addedBy: 'auto',
            evidence: 'The mail thread carries the copy.',
          ),
          StorylineMember(
            storylineId: 'sl-1',
            source: 'teams',
            conversationKey: 'shared-1',
            addedBy: 'auto',
            evidence: 'The chat is where the launch was agreed.',
          ),
        ],
      );

      expect(
        tester
            .widget<Text>(find
                .byKey(StorylineTimelinePanel.evidenceKeyFor('email', 'shared-1')))
            .data,
        'The mail thread carries the copy.',
      );
      expect(
        tester
            .widget<Text>(find
                .byKey(StorylineTimelinePanel.evidenceKeyFor('teams', 'shared-1')))
            .data,
        'The chat is where the launch was agreed.',
      );
    });
  });

  group('the charter', () {
    const placeholder = 'No charter yet — the model drafts one from the '
        'threads.';
    const charter = 'Threads about the new homepage and its launch.';

    testWidgets('About says so when nothing has been written yet',
        (tester) async {
      await pumpPanel(tester);
      expect(find.text(placeholder), findsNothing);

      await openTab(tester, StorylineTab.about);

      expect(find.text(placeholder), findsOneWidget);
    });

    testWidgets('and shows the charter once there is one', (tester) async {
      await pumpPanel(tester, storyline: _chartered);

      await openTab(tester, StorylineTab.about);

      expect(find.text(charter), findsOneWidget);
    });

    testWidgets('is labelled, and Edit opens the field', (tester) async {
      // A sentence that reads as prose is not an invitation. The tap still
      // works — two doors, one action — but this is the door that says so.
      await pumpPanel(tester, storyline: _chartered);

      await openTab(tester, StorylineTab.about);
      expect(find.text('CHARTER'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.byKey(StorylineTimelinePanel.charterEditKey));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      // Nothing to open while it is already open.
      expect(
        find.byKey(StorylineTimelinePanel.charterEditKey),
        findsNothing,
      );
    });

    testWidgets('the caption explains what saving does', (tester) async {
      const caption = 'What belongs in this storyline, in a sentence. Edit it '
          'to narrow or widen the group — saving pins it and hunts for '
          'matching threads.';
      await pumpPanel(tester, storyline: _chartered);

      await openTab(tester, StorylineTab.about);
      expect(find.text(caption), findsOneWidget);

      // The field carries its own caption about saving; two at once would be
      // one too many.
      await tester.tap(find.byKey(StorylineTimelinePanel.charterEditKey));
      await tester.pumpAndSettle();
      expect(find.text(caption), findsNothing);
    });

    testWidgets('tapping it opens a prefilled field that saves what it holds',
        (tester) async {
      final saved = <String>[];
      await pumpPanel(
        tester,
        storyline: _chartered,
        onSetCharter: saved.add,
      );

      await openTab(tester, StorylineTab.about);
      await tester.tap(find.text(charter));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        charter,
      );

      await tester.enterText(
        find.byType(TextField),
        'Only the launch announcement threads.',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(saved, ['Only the launch announcement threads.']);
    });

    testWidgets('Cancel writes nothing', (tester) async {
      final saved = <String>[];
      await pumpPanel(
        tester,
        storyline: _chartered,
        onSetCharter: saved.add,
      );

      await openTab(tester, StorylineTab.about);
      await tester.tap(find.text(charter));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Something else.');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(saved, isEmpty);
      expect(find.text(charter), findsOneWidget);
    });

    testWidgets('Add thread asks the host for a picker', (tester) async {
      var asked = 0;
      await pumpPanel(tester, onAddThread: () => asked++);

      // A header action rather than a menu item: filing a thread here is
      // something you come to this screen to do.
      await tester.tap(find.byTooltip('Add thread'));
      await tester.pumpAndSettle();

      expect(asked, 1);
    });
  });

  group('the recap', () {
    const paragraph =
        'The studio cut the hero paragraph and the launch slipped a week.';
    const summary = 'The studio is reviewing the homepage copy.';

    testWidgets('is the header when there is one', (tester) async {
      await pumpPanel(tester, storyline: _recapped());

      expect(find.text(paragraph), findsOneWidget);
      expect(find.text('OPEN · 1'), findsOneWidget);
      expect(find.text('DECIDED · 1'), findsOneWidget);
      expect(find.text('as of 3h ago'), findsOneWidget);

      // The lists come folded, so their contents are one tap away rather than
      // between the paragraph and the spine.
      await tester.tap(find.text('OPEN · 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DECIDED · 1'));
      await tester.pumpAndSettle();

      expect(find.text('Who signs off the new hero copy?'), findsOneWidget);
      expect(find.text('Launch moved to the 14th.'), findsOneWidget);

      // The one-liner is the rail's text, not this screen's: showing both
      // would be the same answer twice at two lengths.
      expect(find.text(summary), findsNothing);
    });

    testWidgets('no recap falls back to the summary', (tester) async {
      await pumpPanel(tester);

      expect(find.text(summary), findsOneWidget);
      expect(find.textContaining('OPEN'), findsNothing);
      expect(find.textContaining('DECIDED'), findsNothing);
    });

    testWidgets('the lists are folded until asked', (tester) async {
      await pumpPanel(
        tester,
        storyline: _recapped(
          openJson: '["Who signs off the new hero copy?","Pick a date"]',
          decidedJson: '["Launch moved to the 14th."]',
        ),
      );

      // The heading counts what is folded behind it — OPEN on its own would
      // not tell the reader whether the tap is worth making.
      expect(find.text('OPEN · 2'), findsOneWidget);
      expect(find.text('DECIDED · 1'), findsOneWidget);
      expect(find.text('Who signs off the new hero copy?'), findsNothing);
      expect(find.text('Pick a date'), findsNothing);
      expect(find.text('Launch moved to the 14th.'), findsNothing);
    });

    testWidgets('OPEN opens on a tap and folds on the next', (tester) async {
      await pumpPanel(tester, storyline: _recapped());

      await tester.tap(find.text('OPEN · 1'));
      await tester.pumpAndSettle();
      expect(find.text('Who signs off the new hero copy?'), findsOneWidget);
      // The heading stays where it is and keeps its count: unfolding a list
      // is not the list replacing its own heading.
      expect(find.text('OPEN · 1'), findsOneWidget);

      await tester.tap(find.text('OPEN · 1'));
      await tester.pumpAndSettle();
      expect(find.text('Who signs off the new hero copy?'), findsNothing);
    });

    testWidgets('the two lists fold independently', (tester) async {
      await pumpPanel(tester, storyline: _recapped());

      await tester.tap(find.text('OPEN · 1'));
      await tester.pumpAndSettle();

      expect(find.text('Who signs off the new hero copy?'), findsOneWidget);
      // What is still owed and what has been settled are separate questions,
      // and opening one is not asking the other.
      expect(find.text('Launch moved to the 14th.'), findsNothing);

      await tester.tap(find.text('DECIDED · 1'));
      await tester.pumpAndSettle();

      expect(find.text('Who signs off the new hero copy?'), findsOneWidget);
      expect(find.text('Launch moved to the 14th.'), findsOneWidget);
    });

    testWidgets('an empty list still shows no heading', (tester) async {
      await pumpPanel(
        tester,
        storyline: _recapped(openJson: '[]'),
      );

      // Nothing outstanding is not a fold with nothing behind it: there is no
      // OPEN heading to tap at all, while DECIDED keeps its own.
      expect(find.textContaining('OPEN'), findsNothing);
      expect(find.text('DECIDED · 1'), findsOneWidget);
    });

    testWidgets('empty lists render no Open or Decided headings',
        (tester) async {
      await pumpPanel(
        tester,
        storyline: _recapped(openJson: '[]', decidedJson: '[]'),
      );

      expect(find.text(paragraph), findsOneWidget);
      expect(find.textContaining('OPEN'), findsNothing);
      expect(find.textContaining('DECIDED'), findsNothing);
    });

    testWidgets('a short recap needs no Show more', (tester) async {
      await pumpPanel(tester, storyline: _recapped());

      expect(find.text('Show more'), findsNothing);
      expect(find.text('Show less'), findsNothing);
    });

    testWidgets('a long one is clamped, and Show more unfolds it',
        (tester) async {
      // Past the clamp: the recap is the pinned topic at the top of the
      // reading, and six lines of it is a header nobody scrolls past.
      const long =
          'The studio cut the hero paragraph, moved the launch a week, and '
          'asked for a second round of photography before anything else is '
          'signed off. Legal still owe the press briefing wording, and the '
          'agency want a decision on the pricing table by Thursday.';
      await pumpPanel(tester, storyline: _recapped(recapText: long));

      final clamped = tester.widget<Text>(find.text(long));
      expect(clamped.maxLines, 2);
      expect(find.text('Show more'), findsOneWidget);

      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.text(long)).maxLines, isNull);
      expect(find.text('Show less'), findsOneWidget);

      await tester.tap(find.text('Show less'));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.text(long)).maxLines, 2);
    });

    testWidgets('a column that is not a list of strings shows nothing',
        (tester) async {
      await pumpPanel(
        tester,
        storyline: _recapped(openJson: 'not json at all', decidedJson: '{}'),
      );

      // The paragraph is still the header: a half-written column costs the
      // lists, not the recap.
      expect(find.text(paragraph), findsOneWidget);
      expect(find.textContaining('OPEN'), findsNothing);
      expect(find.textContaining('DECIDED'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('the charter suggestion', () {
    const suggestion =
        'Threads about the homepage, its launch, and the press briefing.';
    const charter = 'Threads about the new homepage and its launch.';

    testWidgets('offers Use this and Discard under the charter',
        (tester) async {
      await pumpPanel(
        tester,
        storyline: _recapped(charterSuggestion: suggestion),
      );

      await openTab(tester, StorylineTab.about);

      expect(find.text('SUGGESTED UPDATE'), findsOneWidget);
      expect(find.text(suggestion), findsOneWidget);
      expect(find.text('Use this'), findsOneWidget);
      // Not "Dismiss": that word is already spoken for by the header, where
      // it retires the whole storyline.
      expect(find.text('Discard'), findsOneWidget);
    });

    testWidgets('Use this arms first and fires on the second tap',
        (tester) async {
      final accepted = <String>[];
      await pumpPanel(
        tester,
        storyline: _recapped(charterSuggestion: suggestion),
        onAcceptSuggestion: accepted.add,
      );

      await openTab(tester, StorylineTab.about);
      await tester.tap(find.text('Use this'));
      await tester.pumpAndSettle();

      // The first tap only asks: it overwrites a sentence the user wrote.
      expect(accepted, isEmpty);
      expect(find.text('Replace the charter'), findsOneWidget);

      await tester.tap(find.text('Replace the charter'));
      await tester.pumpAndSettle();

      expect(accepted, [suggestion]);
      // Disarmed on the way out, so the row is back to its two offers.
      expect(find.text('Use this'), findsOneWidget);
    });

    testWidgets('Cancel disarms and writes nothing', (tester) async {
      final accepted = <String>[];
      await pumpPanel(
        tester,
        storyline: _recapped(charterSuggestion: suggestion),
        onAcceptSuggestion: accepted.add,
      );

      await openTab(tester, StorylineTab.about);
      await tester.tap(find.text('Use this'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(accepted, isEmpty);
      expect(find.text('Use this'), findsOneWidget);
    });

    testWidgets('Discard fires at once', (tester) async {
      var dismissed = 0;
      await pumpPanel(
        tester,
        storyline: _recapped(charterSuggestion: suggestion),
        onDismissSuggestion: () => dismissed++,
      );

      await openTab(tester, StorylineTab.about);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      // Throwing away the model's text costs the user nothing of their own,
      // so it does not ask twice.
      expect(dismissed, 1);
    });

    testWidgets('no suggestion, no block', (tester) async {
      await pumpPanel(tester, storyline: _chartered);

      await openTab(tester, StorylineTab.about);

      expect(find.text('SUGGESTED UPDATE'), findsNothing);
      expect(find.text('Use this'), findsNothing);
    });

    testWidgets('hides while the charter is being edited', (tester) async {
      await pumpPanel(
        tester,
        storyline: _recapped(charterSuggestion: suggestion),
      );

      await openTab(tester, StorylineTab.about);
      await tester.tap(find.text(charter));
      await tester.pumpAndSettle();

      // The field is where the user answers this suggestion, and offering to
      // overwrite what they are typing is offering to throw it away.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('SUGGESTED UPDATE'), findsNothing);
      expect(find.text('Use this'), findsNothing);
    });
  });

  group('removed threads under the spine', () {
    final userBlock = StorylineBlock(
      storylineId: 'sl-1',
      conversationKey: 'c9',
      blockedBy: 'user',
      // Not the c1 member's sentence: the spine draws the evidence lines and
      // the removed lists together now, and one string on both would count
      // twice.
      evidence: 'The lease is a facilities matter, not the redesign.',
      subject: 'Office move',
      blockedAt: '2026-09-02T10:00:00Z',
    );
    final auditBlock = StorylineBlock(
      storylineId: 'sl-1',
      source: 'teams',
      conversationKey: 'c8',
      blockedBy: 'audit',
      evidence: 'The charter is about the homepage, this is hiring.',
      subject: 'Interview loop',
      blockedAt: '2026-09-01T10:00:00Z',
    );

    testWidgets('they sit at the foot of Messages, not on About',
        (tester) async {
      // The reader who has just looked at the cards and doubts three of them
      // is looking here — under the spine, not a reference tab away from it.
      await pumpPanel(tester, blocks: [userBlock, auditBlock]);

      expect(find.text('REMOVED BY YOU'), findsOneWidget);
      expect(find.text('REMOVED BY RE-CHECK'), findsOneWidget);
      expect(find.text('Office move'), findsOneWidget);
      expect(find.text('Re-check members'), findsOneWidget);

      await openTab(tester, StorylineTab.about);

      expect(find.text('REMOVED BY YOU'), findsNothing);
      expect(find.text('REMOVED BY RE-CHECK'), findsNothing);
      expect(find.text('Re-check members'), findsNothing);
    });

    testWidgets('a running re-check says so under the spine', (tester) async {
      await pumpPanel(tester, blocks: [auditBlock], auditing: true);

      expect(find.text('Re-checking…'), findsOneWidget);
      expect(find.text('Re-check members'), findsNothing);
    });

    testWidgets('both lists render under headings of their own',
        (tester) async {
      await pumpPanel(tester, blocks: [userBlock, auditBlock]);

      expect(find.text('REMOVED BY YOU'), findsOneWidget);
      expect(find.text('REMOVED BY RE-CHECK'), findsOneWidget);
      expect(find.text('Office move'), findsOneWidget);
      expect(find.text('Interview loop'), findsOneWidget);
      expect(
        find.text('The lease is a facilities matter, not the redesign.'),
        findsOneWidget,
      );
      expect(
        find.text('The charter is about the homepage, this is hiring.'),
        findsOneWidget,
      );
      // Inline, like every other explanation on this panel.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(Dialog), findsNothing);
    });
  });

  group('the documents shelf', () {
    // Pinned to the storyline the panel is showing, so the two-step Remove is
    // the control it carries.
    final quote =
        ref(name: 'Quote.pdf', size: 240 * 1024, pinnedStorylineId: 'sl-1');
    final photo = imageRef(name: 'Site.png', attachmentId: 'i9');

    testWidgets('the tab counts every document, pinned or not',
        (tester) async {
      await pumpPanel(tester, documents: [quote, photo]);

      // The count is the label, the way the thread count reads: a storyline
      // with no files should not need a tap to find that out.
      expect(find.text('Files (2)'), findsOneWidget);
      expect(find.byType(AttachmentDocumentsStrip), findsNothing);

      await openTab(tester, StorylineTab.files);

      expect(find.byKey(StorylineTimelinePanel.documentsStripKey),
          findsOneWidget);
      expect(find.textContaining('Quote.pdf'), findsOneWidget);
    });

    testWidgets('a storyline with no documents still says so', (tester) async {
      await pumpPanel(tester);

      // The bare label, because there is no count to give — and the shelf
      // behind it explains itself rather than opening empty.
      expect(find.text('Files'), findsOneWidget);

      await openTab(tester, StorylineTab.files);

      expect(find.byKey(AttachmentDocumentsStrip.emptyKey), findsOneWidget);
    });

    testWidgets('tapping a document reports it', (tester) async {
      final opened = <String>[];
      await pumpPanel(
        tester,
        documents: [quote],
        onOpenDocument: (attachment) => opened.add(attachment.attachmentId),
      );

      await openTab(tester, StorylineTab.files);
      await tester.tap(find.byKey(AttachmentDocumentsStrip.entryKeyFor(quote)));
      await tester.pump();

      expect(opened, ['a1']);
    });

    testWidgets('removing one is two taps and reports the unpin',
        (tester) async {
      final removed = <String>[];
      await pumpPanel(
        tester,
        documents: [quote],
        onUnpinDocument: (attachment) => removed.add(attachment.attachmentId),
      );

      await openTab(tester, StorylineTab.files);
      await tester.tap(find.byKey(AttachmentDocumentsStrip.unpinKeyFor(quote)));
      await tester.pump();

      expect(removed, isEmpty);

      await tester
          .tap(find.byKey(AttachmentDocumentsStrip.confirmKeyFor(quote)));
      await tester.pump();

      expect(removed, ['a1']);
    });

    testWidgets('a shelf with no unpin offers no way to remove anything',
        (tester) async {
      await pumpPanel(tester, documents: [quote]);

      await openTab(tester, StorylineTab.files);

      expect(find.byKey(AttachmentDocumentsStrip.unpinKeyFor(quote)),
          findsNothing);
    });

    testWidgets('Pin from the shelf reports through onPinDocument',
        (tester) async {
      // Not pinned anywhere: a document that arrived by membership, which is
      // how most of the shelf gets there.
      final loose = ref(name: 'Brief.pdf', attachmentId: 'a7');
      final pinned = <String>[];
      await pumpPanel(
        tester,
        documents: [loose],
        onPinDocument: (attachment) => pinned.add(attachment.attachmentId),
      );

      await openTab(tester, StorylineTab.files);
      await tester.tap(find.byKey(AttachmentDocumentsStrip.pinKeyFor(loose)));
      await tester.pump();

      expect(pinned, ['a7']);
    });

    testWidgets('the pinned ones ride on a bar above the spine',
        (tester) async {
      // Slack's bookmark bar: what this room keeps coming back to, under its
      // name, without opening the Files tab to find it.
      await pumpPanel(tester, documents: [quote, photo]);

      expect(find.byKey(PinnedDocumentsBar.barKey), findsOneWidget);
      expect(find.byKey(PinnedDocumentsBar.entryKeyFor(quote)), findsOneWidget);
      // A document that arrived by membership is not pinned, and the bar is a
      // statement about pins.
      expect(find.byKey(PinnedDocumentsBar.entryKeyFor(photo)), findsNothing);
    });

    testWidgets('a pin to ANOTHER storyline is not on this one\'s bar',
        (tester) async {
      final elsewhere = ref(
        name: 'Other.pdf',
        attachmentId: 'a9',
        pinnedStorylineId: 'sl-2',
      );
      await pumpPanel(tester, documents: [elsewhere]);

      expect(find.byKey(PinnedDocumentsBar.barKey), findsNothing);
      // It is still one of the storyline's files, and the Files tab says so.
      expect(find.text('Files (1)'), findsOneWidget);
    });

    testWidgets('nothing pinned draws no bar at all', (tester) async {
      await pumpPanel(tester, documents: [photo]);

      expect(find.byKey(PinnedDocumentsBar.barKey), findsNothing);
    });

    testWidgets('a tap on the bar reports through onOpenDocument',
        (tester) async {
      final opened = <String>[];
      await pumpPanel(
        tester,
        documents: [quote],
        onOpenDocument: (attachment) => opened.add(attachment.attachmentId),
      );

      await tester.tap(find.byKey(PinnedDocumentsBar.entryKeyFor(quote)));
      await tester.pump();

      expect(opened, ['a1']);
    });

    testWidgets('the panel tells the shelf which storyline it is', (tester) async {
      // Without the id the shelf cannot tell a pin to THIS storyline from a
      // pin to another one, and every entry would offer Pin.
      await pumpPanel(
        tester,
        documents: [quote],
        onPinDocument: (_) {},
        onUnpinDocument: (_) {},
      );

      await openTab(tester, StorylineTab.files);

      expect(find.byKey(AttachmentDocumentsStrip.unpinKeyFor(quote)),
          findsOneWidget);
      expect(find.byKey(AttachmentDocumentsStrip.pinKeyFor(quote)),
          findsNothing);
    });
  });
}
