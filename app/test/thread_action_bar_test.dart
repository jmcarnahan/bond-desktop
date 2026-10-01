import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/widgets/thread_action_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bar on its own: Mark done's choices, and where the labels go at the
/// widths a thread is actually drawn at — a full pane, and a side panel inside
/// its 420px floor.
void main() {
  const jira = Label(id: 'l-jira', name: 'jira');
  const metrics = Label(id: 'l-metrics', name: 'Metrics project');

  late int done;
  late int reason;
  late int reopened;
  late int kept;
  late List<String> found;
  late List<String> removed;
  late List<String> needsYou;

  setUp(() {
    needsYou = [];
    done = 0;
    reason = 0;
    reopened = 0;
    kept = 0;
    found = [];
    removed = [];
  });

  Future<void> pump(
    WidgetTester tester, {
    double width = 900,
    bool isDone = false,
    bool inLater = false,
    List<Label> labels = const [],
    bool withReason = true,
    bool fullBar = true,
    bool withAddLabel = true,
    bool withFind = true,
    int contextLinked = 0,
    bool inNeedsYou = false,
    bool withNeedsYou = false,
    bool needsYouDecided = true,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: ThreadActionBar(
              done: isDone,
              inLater: inLater,
              onDone: () => done++,
              onDoneWithReason: withReason ? () => reason++ : null,
              onReopen: () => reopened++,
              onLater: fullBar ? () {} : null,
              onKeepInInbox: () => kept++,
              inNeedsYou: inNeedsYou,
              needsYouDecided: needsYouDecided,
              onRemoveFromNeedsYou:
                  withNeedsYou ? () => needsYou.add('remove') : null,
              onAddToNeedsYou: withNeedsYou ? () => needsYou.add('add') : null,
              onStoryline: fullBar ? () {} : null,
              onContext: fullBar ? () {} : null,
              contextLinked: contextLinked,
              onCompose: fullBar ? () {} : null,
              labels: labels,
              onAddLabel: withAddLabel ? () {} : null,
              onRemoveLabel: (l) => removed.add(l.id),
              onFindLabel: withFind ? (l) => found.add(l.id) : null,
            ),
          ),
        ),
      ),
    ));
  }

  group('Mark done', () {
    testWidgets('opens its choices rather than acting', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();

      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsOneWidget);
      expect((done, reason), (0, 0));
    });

    testWidgets('the plain choice marks done and shuts', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();

      await tester.tap(find.byKey(ThreadActionBar.donePlainKey));
      await tester.pump();

      expect((done, reason), (1, 0));
      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
    });

    testWidgets('with no second way to finish it simply acts', (tester) async {
      await pump(tester, withReason: false);

      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();

      expect(done, 1);
      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
    });

    testWidgets('a second press closes the choices without acting',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();

      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();

      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
      expect((done, reason), (0, 0));
    });

    testWidgets('choices whose with-label way disappears under them close',
        (tester) async {
      // With one way left, Mark done acts directly — nothing else could
      // ever close a stale pair of choices.
      await pump(tester);
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();

      await pump(tester, withReason: false);

      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();
      expect(done, 1);
    });

    testWidgets('Reopen acts in place, and a Later thread offers Keep instead',
        (tester) async {
      await pump(tester, isDone: true);
      await tester.tap(find.byKey(ThreadActionBar.reopenKey));
      await tester.pump();
      expect(reopened, 1);

      await pump(tester, inLater: true);
      expect(find.byKey(ThreadActionBar.laterKey), findsNothing);
      await tester.tap(find.byKey(ThreadActionBar.keepKey));
      await tester.pump();
      expect(kept, 1);
    });

    testWidgets('a callback nobody wired draws no button', (tester) async {
      await pump(tester, fullBar: false, withAddLabel: false);

      expect(find.byKey(ThreadActionBar.doneKey), findsOneWidget);
      expect(find.byKey(ThreadActionBar.laterKey), findsNothing);
      expect(find.byKey(ThreadActionBar.storylineKey), findsNothing);
      expect(find.byKey(ThreadActionBar.contextKey), findsNothing);
      expect(find.byKey(ThreadActionBar.composeKey), findsNothing);
      expect(find.byKey(ThreadActionBar.addLabelKey), findsNothing);
    });

    testWidgets('Escape shuts the choices and does nothing else',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
      expect((done, reason), (0, 0));
    });

    testWidgets('the with-a-label choice asks for the reason and shuts',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();

      await tester.tap(find.byKey(ThreadActionBar.doneWithReasonKey));
      await tester.pump();

      expect((done, reason), (0, 1));
      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
    });

    testWidgets('Close shuts the choices and does nothing else',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();

      await tester.tap(find.descendant(
        of: find.byKey(ThreadActionBar.doneChoicesKey),
        matching: find.byTooltip('Close'),
      ));
      await tester.pump();

      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
      expect((done, reason), (0, 0));
    });

    testWidgets('Escape reaches the choices while the list holds focus, and '
        'focus goes back to the list', (tester) async {
      // The triage list holds focus the whole time the reader works, so the
      // choices must take it by hand — an autofocus is refused under a
      // focused scope, and Escape then went past them to the screen.
      final list = FocusNode(debugLabel: 'triage list');
      addTearDown(list.dispose);
      var escapesPast = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Focus(
            focusNode: list,
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                escapesPast++;
              }
              return KeyEventResult.ignored;
            },
            child: ThreadActionBar(
              onDone: () => done++,
              onDoneWithReason: () => reason++,
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(list.hasPrimaryFocus, isTrue);

      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
      expect(escapesPast, 0);
      expect(list.hasPrimaryFocus, isTrue);
    });

    testWidgets('choices left open do not come back after close and reopen',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();

      // `e` closed the thread while the choices were up, then Reopen.
      await pump(tester, isDone: true);
      expect(find.byKey(ThreadActionBar.reopenKey), findsOneWidget);
      await pump(tester);

      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
    });
  });

  group('the labels', () {
    testWidgets('share the row in a full pane', (tester) async {
      await pump(tester, labels: const [jira, metrics]);

      final bar = tester.getRect(find.byKey(ThreadActionBar.doneKey));
      final chip =
          tester.getRect(find.byKey(ThreadActionBar.labelKeyFor('l-jira')));
      expect(chip.center.dy, closeTo(bar.center.dy, 4));
    });

    testWidgets('take their own line in a side panel, every ✕ reachable',
        (tester) async {
      // A thread beside is at least 420px, less the card's own padding.
      await pump(tester, width: 380, labels: const [jira, metrics]);

      expect(tester.takeException(), isNull);
      final bar = tester.getRect(find.byKey(ThreadActionBar.doneKey));
      final chip =
          tester.getRect(find.byKey(ThreadActionBar.labelKeyFor('l-jira')));
      expect(chip.top, greaterThan(bar.bottom));
      // The add button stays up with the verbs — the chips' line is the
      // chips' — still one press away from the picker.
      final add = tester.getRect(find.byKey(ThreadActionBar.addLabelKey));
      expect(add.center.dy, closeTo(bar.center.dy, 4));
      final remove = tester.getRect(
        find.byKey(ThreadActionBar.removeLabelKey('l-jira')),
      );
      expect(remove.right, lessThanOrEqualTo(380));
    });

    testWidgets('an unlabelled thread never grows a line for "Add label"',
        (tester) async {
      await pump(tester, width: 380);

      expect(tester.takeException(), isNull);
      expect(find.byKey(ThreadActionBar.labelRowKey), findsOneWidget);
      final bar = tester.getRect(find.byKey(ThreadActionBar.doneKey));
      final add = tester.getRect(find.byKey(ThreadActionBar.addLabelKey));
      expect(add.center.dy, closeTo(bar.center.dy, 4));
      // One line, not one line and an empty second: the whole bar is the
      // row's height and the padding around it, nothing more.
      final height = tester.getSize(find.byType(ThreadActionBar)).height;
      expect(height, lessThan(bar.height + 24));
    });

    testWidgets('with room to spare the button says "Add label"',
        (tester) async {
      await pump(tester);

      expect(find.text('Add label'), findsOneWidget);
      // Chips arrived: the button gives its word up to them.
      await pump(tester, labels: const [jira]);
      expect(find.text('Add label'), findsNothing);
      expect(find.byKey(ThreadActionBar.addLabelKey), findsOneWidget);
    });

    testWidgets("a chip's name and its ✕ act on their own label",
        (tester) async {
      await pump(tester, labels: const [jira, metrics]);

      await tester.tap(find.text('jira'));
      await tester.pump();
      await tester.tap(
        find.byKey(ThreadActionBar.removeLabelKey('l-metrics')),
      );
      await tester.pump();

      expect(found, ['l-jira']);
      expect(removed, ['l-metrics']);
    });

    testWidgets('chips below with no add button leave no dangling rule',
        (tester) async {
      // The 1px rule divides the verbs from what follows on their row; with
      // the chips below and nothing adding, nothing follows.
      bool isRule(Widget w) =>
          w is Container &&
          w.constraints == const BoxConstraints.tightFor(width: 1, height: 20);
      await pump(tester, width: 380, labels: const [jira, metrics]);
      expect(find.byWidgetPredicate(isRule), findsOneWidget);

      await pump(
        tester,
        width: 380,
        labels: const [jira, metrics],
        withAddLabel: false,
      );
      expect(tester.takeException(), isNull);
      expect(find.byWidgetPredicate(isRule), findsNothing);
    });

    testWidgets('too narrow for its word, Mark done keeps its icon and name',
        (tester) async {
      await pump(tester, width: 260, labels: const [jira]);

      expect(tester.takeException(), isNull);
      expect(find.byKey(ThreadActionBar.doneKey), findsOneWidget);
      expect(find.text('Mark done'), findsNothing);
      expect(find.byTooltip('Mark done  ·  e'), findsOneWidget);
    });

    testWidgets('and so does Reopen, which is measured as its own word',
        (tester) async {
      // Reopen once drew its word whatever the arithmetic had assumed, and a
      // done thread overflowed at 250px.
      await pump(tester, width: 250, isDone: true);

      expect(tester.takeException(), isNull);
      expect(find.byKey(ThreadActionBar.reopenKey), findsOneWidget);
      expect(find.text('Reopen'), findsNothing);
    });

    testWidgets('no width or text size pushes any form of the row past the '
        'edge', (tester) async {
      const long = Label(
        id: 'l-long',
        name: 'A label whose name runs on far past any chip',
      );
      for (final scale in const [1.0, 2.0]) {
        for (final isDone in const [false, true]) {
          for (final labels in const [
            <Label>[],
            [jira],
            [long, jira, metrics],
          ]) {
            for (var w = 200.0; w <= 1400; w += 40) {
              await tester.binding.setSurfaceSize(Size(w, 600));
              // A new app each time: an overflow is reported once per render
              // object, and a reused one would hide the second.
              await tester.pumpWidget(MaterialApp(
                key: UniqueKey(),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(w, 600),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: Scaffold(
                    body: ThreadActionBar(
                      done: isDone,
                      onDone: () {},
                      onDoneWithReason: () {},
                      onReopen: () {},
                      onLater: () {},
                      // The longest word the row can carry: an open thread
                      // in Needs You draws "Remove from Needs You".
                      inNeedsYou: !isDone,
                      onRemoveFromNeedsYou: () {},
                      onAddToNeedsYou: () {},
                      onStoryline: () {},
                      onContext: () {},
                      contextLinked: 12,
                      onCompose: () {},
                      labels: labels,
                      onAddLabel: () {},
                      onRemoveLabel: (_) {},
                    ),
                  ),
                ),
              ));
              expect(
                tester.takeException(),
                isNull,
                reason: 'at ${w}px, ${scale}x, done $isDone, '
                    '${labels.length} labels',
              );
            }
          }
        }
      }
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('the widest chip\'s ✕ starts on screen', (tester) async {
      // The room the chips need beside the verbs counts the add button that
      // leads them, or a long label's ✕ starts past the edge.
      const long = Label(
        id: 'l-long',
        name: 'A label whose name runs on far past any chip',
      );
      for (var w = 500.0; w <= 640; w += 10) {
        await pump(tester, width: w, labels: const [long, jira]);
        final remove = tester.getRect(
          find.byKey(ThreadActionBar.removeLabelKey('l-long')),
        );
        expect(remove.right, lessThanOrEqualTo(w - 12 + 0.5),
            reason: 'at ${w}px');
      }
    });

    testWidgets('the ✕ is a target, not just a glyph', (tester) async {
      await pump(tester, labels: const [jira]);

      final remove = tester.getSize(
        find.byKey(ThreadActionBar.removeLabelKey('l-jira')),
      );
      expect(remove.width, greaterThanOrEqualTo(24));
    });

    testWidgets('a large text size never pushes the row past the edge',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(380, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: Scaffold(
            body: ThreadActionBar(
              onDone: () {},
              onDoneWithReason: () {},
              onLater: () {},
              onStoryline: () {},
              onContext: () {},
              onCompose: () {},
              labels: const [jira, metrics],
              onAddLabel: () {},
              onRemoveLabel: (_) {},
            ),
          ),
        ),
      ));

      expect(tester.takeException(), isNull);
    });

    testWidgets('a label name says what a tap does', (tester) async {
      await pump(tester, labels: const [jira]);

      expect(find.byTooltip('Filter Needs You by jira'), findsOneWidget);
    });

    testWidgets('a chip is spoken once: a filter button, or just its name',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, labels: const [jira]);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Filter Needs You by jira')),
        isSemantics(isButton: true, hasTapAction: true),
      );
      expect(find.bySemanticsLabel('jira'), findsNothing);

      // Nothing wired: the name is a word, said once — the tooltip used to
      // read it out and then the pill read itself out again.
      await pump(tester, labels: const [jira], withFind: false);
      expect(find.bySemanticsLabel('jira'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('the rest of the row', () {
    testWidgets('context shows its count, once', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, contextLinked: 3);

      expect(find.byTooltip('Context · 3'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      // Said once: the badge is not read out beside the name that holds it.
      expect(find.bySemanticsLabel('Context · 3'), findsOneWidget);
      expect(find.bySemanticsLabel('3'), findsNothing);

      await pump(tester);
      expect(find.byTooltip('Add context'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      semantics.dispose();
    });

    testWidgets('every button has a spoken name, icon or word',
        (tester) async {
      final semantics = tester.ensureSemantics();
      // Narrow enough that Mark done is its icon alone.
      await pump(tester, width: 260, labels: const [jira]);

      expect(
        tester.getSemantics(find.bySemanticsLabel('Mark done')),
        isSemantics(label: 'Mark done', isButton: true,
            hasTapAction: true),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Send to Later')),
        isSemantics(isButton: true, hasTapAction: true),
      );
      expect(find.bySemanticsLabel('Remove jira'), findsOneWidget);

      // Worded, it is named once, not "Mark done, Mark done".
      await pump(tester);
      expect(find.bySemanticsLabel('Mark done'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('Mark done says whether its choices are open, and they are '
        'two buttons', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);
      final button = find.bySemanticsLabel('Mark done');

      expect(
        tester.getSemantics(button),
        isSemantics(isButton: true, hasExpandedState: true, isExpanded: false),
      );
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();
      expect(
        tester.getSemantics(button),
        isSemantics(isButton: true, hasExpandedState: true, isExpanded: true),
      );
      for (final title in ['Mark done.', 'Mark done with a label.']) {
        final choice =
            find.bySemanticsLabel(RegExp('^${RegExp.escape(title)}'));
        expect(
          tester.getSemantics(choice),
          isSemantics(isButton: true, hasTapAction: true),
          reason: title,
        );
      }
      semantics.dispose();
    });

    testWidgets('a large text size grows the row rather than clipping it',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(900, 400),
            textScaler: TextScaler.linear(2.0),
          ),
          child: Scaffold(
            body: ThreadActionBar(onDone: () {}, onDoneWithReason: () {}),
          ),
        ),
      ));

      final button = tester.getSize(find.byKey(ThreadActionBar.doneKey));
      final word = tester.getSize(find.text('Mark done'));
      expect(button.height, greaterThan(34));
      expect(button.height, greaterThanOrEqualTo(word.height + 12));
    });

    testWidgets('a theme\'s letter spacing never pushes Mark done past the '
        'edge', (tester) async {
      // The word is measured in the style it renders in; a theme whose body
      // text is spaced out must not make the sum come out short.
      for (var w = 260.0; w <= 420; w += 4) {
        await tester.binding.setSurfaceSize(Size(w, 400));
        await tester.pumpWidget(MaterialApp(
          key: UniqueKey(),
          theme: ThemeData(
            textTheme: const TextTheme(
              bodyMedium: TextStyle(letterSpacing: 3, wordSpacing: 12),
            ),
          ),
          home: Scaffold(
            body: ThreadActionBar(
              onDone: () {},
              onDoneWithReason: () {},
              onLater: () {},
              onStoryline: () {},
              onContext: () {},
              onCompose: () {},
              labels: const [jira],
              onAddLabel: () {},
            ),
          ),
        ));
        expect(tester.takeException(), isNull, reason: 'at ${w}px');
      }
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('in a short window the choices scroll rather than overflow',
        (tester) async {
      // A third of the window at most, never under 180, and the transcript
      // under it keeps a height of its own. Both arms pinned: text at 3x
      // stands far taller than either cap, so the panel's height IS the cap
      // — a 500px window is under the floor, a 750px one is a third of
      // itself.
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final (height, cap) in const [(500.0, 180.0), (750.0, 250.0)]) {
        await tester.binding.setSurfaceSize(Size(420, height));
        await tester.pumpWidget(MaterialApp(
          key: UniqueKey(),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(420, height),
              textScaler: const TextScaler.linear(3.0),
            ),
            child: Scaffold(
              body: Column(
                children: [
                  ThreadActionBar(onDone: () {}, onDoneWithReason: () {}),
                  const Expanded(child: Placeholder()),
                ],
              ),
            ),
          ),
        ));
        await tester.tap(find.byKey(ThreadActionBar.doneKey));
        await tester.pump();

        expect(tester.takeException(), isNull, reason: 'at ${height}px');
        final panel = tester.getSize(find.ancestor(
          of: find.byKey(ThreadActionBar.doneChoicesKey),
          matching: find.byType(SingleChildScrollView),
        ));
        expect(panel.height, closeTo(cap, 0.1), reason: 'at ${height}px');
      }
    });

    testWidgets('the choice cards give their titles the room the key leaves',
        (tester) async {
      // A flex split once gave the key half the card whether it used it or
      // not, and the long title wrapped in a card with room to spare.
      await pump(tester);
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();

      final title = tester.getSize(find.text('Mark done with a label'));
      expect(title.height, lessThan(30), reason: 'one line at a full width');
    });

    testWidgets('open choices in a narrow panel at 2x never overflow',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(300, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(300, 700),
            textScaler: TextScaler.linear(2.0),
          ),
          child: Scaffold(
            body: Column(
              children: [
                ThreadActionBar(onDone: () {}, onDoneWithReason: () {}),
                const Expanded(child: Placeholder()),
              ],
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsOneWidget);
    });

    testWidgets('a closed thread offers no Later', (tester) async {
      await pump(tester, isDone: true);

      expect(find.byKey(ThreadActionBar.reopenKey), findsOneWidget);
      expect(find.byKey(ThreadActionBar.laterKey), findsNothing);
    });
  });

  group('Needs You', () {
    testWidgets('a thread in Needs You offers Remove, and only Remove',
        (tester) async {
      await pump(tester, inNeedsYou: true, withNeedsYou: true);

      expect(find.byKey(ThreadActionBar.needsYouAddKey), findsNothing);
      expect(find.text('Remove from Needs You'), findsOneWidget);
      await tester.tap(find.byKey(ThreadActionBar.needsYouRemoveKey));
      expect(needsYou, ['remove']);
    });

    testWidgets('a thread outside it offers Add, and only Add',
        (tester) async {
      await pump(tester, withNeedsYou: true);

      expect(find.byKey(ThreadActionBar.needsYouRemoveKey), findsNothing);
      expect(find.text('Add to Needs You'), findsOneWidget);
      await tester.tap(find.byKey(ThreadActionBar.needsYouAddKey));
      expect(needsYou, ['add']);
    });

    testWidgets('a callback nobody wired draws neither', (tester) async {
      await pump(tester, inNeedsYou: true);
      expect(find.byKey(ThreadActionBar.needsYouRemoveKey), findsNothing);

      await pump(tester);
      expect(find.byKey(ThreadActionBar.needsYouAddKey), findsNothing);
    });

    testWidgets('a done thread or one in Later is offered no Add',
        (tester) async {
      await pump(tester, isDone: true, withNeedsYou: true);
      expect(find.byKey(ThreadActionBar.needsYouAddKey), findsNothing);
      expect(find.byKey(ThreadActionBar.needsYouRemoveKey), findsNothing);

      await pump(tester, inLater: true, withNeedsYou: true);
      expect(find.byKey(ThreadActionBar.needsYouAddKey), findsNothing);
      expect(find.byKey(ThreadActionBar.needsYouRemoveKey), findsNothing);
    });

    testWidgets('a thread with nothing decided waiting on the owner is '
        'offered no Add', (tester) async {
      await pump(tester, withNeedsYou: true, needsYouDecided: false);

      expect(find.byKey(ThreadActionBar.needsYouAddKey), findsNothing);
      expect(find.byKey(ThreadActionBar.needsYouRemoveKey), findsNothing);
    });

    testWidgets('too narrow for its word, it keeps its icon and its name',
        (tester) async {
      await pump(tester, width: 360, inNeedsYou: true, withNeedsYou: true);

      expect(tester.takeException(), isNull);
      expect(find.byKey(ThreadActionBar.needsYouRemoveKey), findsOneWidget);
      expect(find.text('Remove from Needs You'), findsNothing);
      expect(
        find.byTooltip('Remove from Needs You — and anything like it'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Remove from Needs You'), findsOneWidget);
    });
  });
}
