import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/message_row.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Message _message({
  required String id,
  required String receivedAt,
  String from = 'Sarah Chen',
  String address = 'sarah@example.com',
  String? body,
  String source = 'email',
}) =>
    Message(
      id: id,
      source: source,
      outbound: false,
      fromName: from,
      fromAddress: address,
      receivedAt: receivedAt,
      bodyText: body ?? 'body of $id',
    );

StorylineEpisode _episode({
  required String key,
  required List<Message> messages,
  String source = 'email',
  String subject = '',
  List<String> participants = const ['Sarah Chen'],
  String? latestAt,
  String? summary,
}) =>
    StorylineEpisode(
      source: source,
      conversationKey: key,
      subject: subject,
      participants: participants,
      messages: messages,
      latestAt: latestAt ?? messages.last.receivedAt,
      summary: summary,
    );

/// The messages actually on screen, in order — which is what "expanded" means
/// here. A shut card renders a preview and no [MessageRow].
List<String> _renderedIds(WidgetTester tester) => tester
    .widgetList<MessageRow>(find.byType(MessageRow))
    .map((row) => row.message.id)
    .toList();

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
    void Function(String source, String key)? onRemoveThread,
    void Function(String source, String key)? onOpenThread,
    VoidCallback? onBack,
    VoidCallback? onAddThread,
    bool newestFirst = false,
    VoidCallback? onToggleSort,
    VoidCallback? onDismiss,
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
          onRemoveThread: onRemoveThread ?? (_, _) {},
          onOpenThread: onOpenThread ?? (_, _) {},
          onAddThread: onAddThread ?? () {},
          newestFirst: newestFirst,
          onToggleSort: onToggleSort ?? () {},
          onDismiss: onDismiss ?? () {},
        ),
      ),
    ));
  }

  group('header', () {
    testWidgets('shows the title, the summary and the thread count',
        (tester) async {
      await pumpPanel(tester);

      expect(find.text('Website redesign'), findsOneWidget);
      expect(find.text('The studio is reviewing the homepage copy.'),
          findsOneWidget);
      expect(find.text('2 threads'), findsOneWidget);
    });

    testWidgets('the back arrow is absent when there is nowhere to go back to',
        (tester) async {
      await pumpPanel(tester);
      expect(find.byIcon(Icons.arrow_back), findsNothing);

      await pumpPanel(tester, onBack: () {});
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
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

    testWidgets('newest first flips the spine, not the default expansion',
        (tester) async {
      await pumpPanel(tester, newestFirst: true);

      final homepageCard = find.text('✉ Homepage copy');
      final launchCard = find.text('✉ Launch date');
      expect(
        tester.getTopLeft(launchCard).dy,
        lessThan(tester.getTopLeft(homepageCard).dy),
      );
      // The preference is a reading direction and nothing more: the newest
      // thread is still the one the reader lands in, now at the top.
      expect(_renderedIds(tester), ['m2']);
    });

    testWidgets('the sort button names the current order and reports a toggle',
        (tester) async {
      var toggled = 0;
      await pumpPanel(tester, onToggleSort: () => toggled++);

      expect(find.text('Oldest first'), findsOneWidget);
      expect(find.text('Newest first'), findsNothing);

      await tester.tap(find.text('Oldest first'));
      await tester.pumpAndSettle();

      // The host owns the preference, so the label only follows a rebuild
      // with the new value.
      expect(toggled, 1);

      await pumpPanel(tester, newestFirst: true);
      expect(find.text('Newest first'), findsOneWidget);
    });

    testWidgets('the newest episode is the one that opens', (tester) async {
      await pumpPanel(tester);

      // The last card holds the newest message, so it is the one the reader
      // lands in. Everything above it is a headline until they ask for more.
      expect(_renderedIds(tester), ['m2']);
    });

    testWidgets('tapping a card header opens it, and tapping again shuts it',
        (tester) async {
      await pumpPanel(tester);

      await tester.tap(find.text('✉ Homepage copy'));
      await tester.pumpAndSettle();

      // Opening one leaves the other where it was: this is skimming, not a
      // single-expansion accordion.
      expect(_renderedIds(tester), ['m1', 'm3', 'm2']);

      await tester.tap(find.text('✉ Launch date'));
      await tester.pumpAndSettle();

      expect(_renderedIds(tester), ['m1', 'm3']);
    });

    testWidgets('a shut card previews the newest message in its thread',
        (tester) async {
      await pumpPanel(tester);

      // m3 is the homepage thread's last message, and the card is shut, so the
      // preview is the only place it appears.
      expect(_renderedIds(tester), ['m2']);
      expect(find.text('body of m3'), findsOneWidget);
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

    testWidgets('day dividers live inside an episode', (tester) async {
      final overnight = _episode(
        key: 'c3',
        subject: 'Overnight',
        messages: [
          _message(id: 'n1', receivedAt: '2026-08-01T09:00:00Z'),
          _message(id: 'n2', receivedAt: '2026-08-02T09:00:00Z'),
        ],
      );
      await pumpPanel(tester, only: [overnight]);

      expect(find.byType(MessageRow), findsNWidgets(2));
      expect(find.byType(DayDivider), findsNWidgets(2));
    });

    testWidgets('nothing left of the seam pills', (tester) async {
      await pumpPanel(tester);

      // The seam is the card boundary now. A pill at every thread change was
      // the merged transcript's way of coping and it went with it.
      expect(find.byType(BondFilterPill), findsNothing);
    });

    testWidgets('an empty storyline says so rather than going blank',
        (tester) async {
      await pumpPanel(tester, only: const []);

      expect(find.text('No messages in this storyline.'), findsOneWidget);
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

    testWidgets('the close icon removes that thread from the storyline',
        (tester) async {
      final removed = <String>[];
      await pumpPanel(
        tester,
        onRemoveThread: (source, key) => removed.add('$source/$key'),
      );

      await tester.tap(find.byTooltip('Remove from storyline').first);

      expect(removed, ['email/c1']);
    });
  });

  group('dismiss', () {
    testWidgets('asks before it retires anything, and takes no for an answer',
        (tester) async {
      var dismissed = 0;
      await pumpPanel(tester, onDismiss: () => dismissed++);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();

      expect(find.text('Dismiss storyline'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(dismissed, 0);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Dismiss'), findsOneWidget);
      expect(find.text('Dismiss storyline'), findsNothing);
      expect(dismissed, 0);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('the second tap is what retires it', (tester) async {
      var dismissed = 0;
      await pumpPanel(tester, onDismiss: () => dismissed++);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dismiss storyline'));
      await tester.pumpAndSettle();

      expect(dismissed, 1);
      // The confirmation is a pair of buttons in the header, not a popup over
      // it — the same rule the rest of this panel follows.
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

  group('member strip evidence', () {
    testWidgets('the model reasoning reads inline, not in a dialog',
        (tester) async {
      await pumpPanel(tester);

      // Shut until asked — the strip is an explanation, not a fixture.
      expect(find.text('Both concern the website redesign.'), findsNothing);

      await tester.tap(find.text('2 threads'));
      await tester.pumpAndSettle();

      expect(find.text('Both concern the website redesign.'), findsOneWidget);
      // A thread a person filed has no model reasoning to show, and inventing
      // one would be worse than saying who did it.
      expect(find.text('You added this.'), findsOneWidget);
      expect(find.text('Homepage copy'), findsOneWidget);
      expect(find.text('Launch date'), findsOneWidget);
      // The explanation is the strip itself now. Nothing here opens a popup.
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('is a read-only explanation — no tick, no way out',
        (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.text('2 threads'));
      await tester.pumpAndSettle();

      // Hiding a thread was a view filter nobody could tell from a removal.
      // Both gestures live on the episode cards now.
      expect(find.byType(Checkbox), findsNothing);
      // Two cards carry one each; the strip adds none.
      expect(find.byTooltip('Remove from storyline'), findsNWidgets(2));
    });

    testWidgets('labels a member by its own connector, not by a key twin',
        (tester) async {
      // One conversation key under two connectors — legal, since keys are
      // only unique within the connector that issued them. Each member row
      // must take its subject from ITS episode, not whichever twin a lookup
      // on the bare key happens to find first.
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
          ),
          StorylineMember(
            storylineId: 'sl-1',
            source: 'teams',
            conversationKey: 'shared-1',
            addedBy: 'auto',
          ),
        ],
      );

      await tester.tap(find.text('2 threads'));
      await tester.pumpAndSettle();

      expect(find.text('Homepage copy'), findsOneWidget);
      expect(find.text('Sarah Whitfield'), findsOneWidget);
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

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();

      expect(find.text(placeholder), findsOneWidget);
    });

    testWidgets('and shows the charter once there is one', (tester) async {
      await pumpPanel(tester, storyline: _chartered);

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();

      expect(find.text(charter), findsOneWidget);
    });

    testWidgets('tapping it opens a prefilled field that saves what it holds',
        (tester) async {
      final saved = <String>[];
      await pumpPanel(
        tester,
        storyline: _chartered,
        onSetCharter: saved.add,
      );

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
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

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
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

      await tester.tap(find.text('Add thread'));
      await tester.pumpAndSettle();

      expect(asked, 1);
    });
  });
}
