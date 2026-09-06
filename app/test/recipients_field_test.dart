import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/person.dart';
import 'package:bond_inbox/providers/recipient_search_provider.dart'
    show RecipientResults;
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/recipients_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The recipients field.
///
/// Two rules this file exists to pin. The first is that a keystroke is not a
/// search: the debounce has to swallow a burst and ask once. The second is
/// that picking the same person twice in one session has to work — the SDK's
/// `_select` early-returns on an option equal to the last one it selected, so
/// the option type must not carry value equality.

const Person sarah = Person(
  id: 'u1',
  displayName: 'Sarah Whitfield',
  mail: 'sarah@corp.example',
  jobTitle: 'Ops',
);

const Person sam = Person(
  id: 'mail:sam@corp.example',
  displayName: 'Sam Ortiz',
  mail: 'sam@corp.example',
  source: PersonSource.recent,
);

const Conversation crew = Conversation(
  id: 'chat-1',
  source: 'teams',
  subject: 'Launch crew',
  participants: [
    Participant(name: 'Sam Ortiz', email: 'teams:u2'),
    Participant(name: 'Rae Lin', email: 'teams:u3'),
  ],
);

/// A scripted `RecipientSearch.search` that remembers what it was asked.
class _FakeSearch {
  _FakeSearch({
    this.recents = const [],
    this.directory = const [],
    this.chats = const [],
    this.directoryOffline = false,
    this.scopeMissing = false,
  });

  List<Person> recents;
  List<Person> directory;
  List<Conversation> chats;
  bool directoryOffline;
  bool scopeMissing;

  final List<String> queries = [];

  Future<RecipientResults> call(String query) async {
    queries.add(query);
    return (
      recents: recents,
      directory: directory,
      chats: chats,
      directoryOffline: directoryOffline,
      scopeMissing: scopeMissing,
    );
  }
}

Future<RecipientResults> _throwingSearch(String query) async {
  throw StateError('the directory fell over');
}

/// Stands in for the compose screen: owns the picked list, the way the real
/// parent will, and records every list the field hands back.
class _Host extends StatefulWidget {
  const _Host({
    required this.initial,
    required this.changes,
    required this.search,
    required this.channel,
    this.max,
    this.allowTypedAddress = false,
    this.onChatPicked,
  });

  final List<Person> initial;
  final List<List<Person>> changes;
  final Future<RecipientResults> Function(String) search;
  final RecipientChannel channel;
  final int? max;
  final bool allowTypedAddress;
  final ValueChanged<Conversation>? onChatPicked;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<Person> _value = [...widget.initial];

  @override
  Widget build(BuildContext context) {
    return RecipientsField(
      value: _value,
      onChanged: (next) {
        widget.changes.add(next);
        setState(() => _value = next);
      },
      search: widget.search,
      channel: widget.channel,
      max: widget.max,
      allowTypedAddress: widget.allowTypedAddress,
      onChatPicked: widget.onChatPicked,
    );
  }
}

void main() {
  /// Pumps the field inside a host that owns the list, and returns the log of
  /// every list the field reported.
  Future<List<List<Person>>> pumpField(
    WidgetTester tester, {
    List<Person> value = const [],
    required Future<RecipientResults> Function(String) search,
    RecipientChannel channel = RecipientChannel.mail,
    int? max,
    bool allowTypedAddress = false,
    ValueChanged<Conversation>? onChatPicked,
    double width = 600,
  }) async {
    final changes = <List<Person>>[];
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(BondSpacing.s16),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: _Host(
                initial: value,
                changes: changes,
                search: search,
                channel: channel,
                max: max,
                allowTypedAddress: allowTypedAddress,
                onChatPicked: onChatPicked,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    return changes;
  }

  /// Past the debounce and through the search's own microtask.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await settle(tester);
  }

  group('typing', () {
    testWidgets('waits for the debounce and asks once with the final query',
        (tester) async {
      final search = _FakeSearch(directory: [sarah]);
      await pumpField(tester, search: search.call);

      await tester.enterText(find.byType(TextField), 's');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), 'sa');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), 'sar');
      await settle(tester);

      expect(search.queries, ['sar']);
    });

    testWidgets('a blank query asks nothing', (tester) async {
      final search = _FakeSearch(directory: [sarah]);
      await pumpField(tester, search: search.call);

      await type(tester, '   ');

      expect(search.queries, isEmpty);
      expect(find.byKey(const Key('recipients-options')), findsNothing);
    });

    testWidgets('results render in sections', (tester) async {
      final search = _FakeSearch(recents: [sam], directory: [sarah]);
      await pumpField(tester, search: search.call);

      await type(tester, 'sa');

      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Directory'), findsOneWidget);
      expect(find.byKey(const Key('recipient-option-u1')), findsOneWidget);
      expect(
        find.byKey(const Key('recipient-option-mail:sam@corp.example')),
        findsOneWidget,
      );
      expect(find.text('sarah@corp.example · Ops'), findsOneWidget);
    });

    testWidgets('a throwing search shows nothing and throws nothing',
        (tester) async {
      await pumpField(tester, search: _throwingSearch);

      await type(tester, 'sa');

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('recipients-options')), findsNothing);
      expect(find.byKey(const Key('recipients-footer')), findsOneWidget);
      expect(
        find.text('The directory could not be reached; showing recent people.'),
        findsOneWidget,
      );
    });

    testWidgets('an unreachable directory still lists recents',
        (tester) async {
      final search = _FakeSearch(recents: [sam], directoryOffline: true);
      await pumpField(tester, search: search.call);

      await type(tester, 'sa');

      expect(
        find.text('The directory could not be reached; showing recent people.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('recipient-option-mail:sam@corp.example')),
        findsOneWidget,
      );
    });

    testWidgets('the scope footer is informational', (tester) async {
      final search = _FakeSearch(recents: [sam], scopeMissing: true);
      await pumpField(tester, search: search.call);

      await type(tester, 'sa');

      expect(find.byKey(const Key('recipients-footer')), findsOneWidget);
      expect(
        find.text('Directory search is not enabled for this account.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('recipient-option-mail:sam@corp.example')),
        findsOneWidget,
      );
    });
  });

  group('picking', () {
    testWidgets('click picks and clears the field', (tester) async {
      final search = _FakeSearch(directory: [sarah]);
      final changes = await pumpField(tester, search: search.call);

      await type(tester, 'sa');
      await tester.tap(find.byKey(const Key('recipient-option-u1')));
      await settle(tester);

      expect(changes, [
        [sarah]
      ]);
      expect(find.byKey(const Key('recipient-chip-u1')), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
    });

    testWidgets('arrow down then Enter picks the second option',
        (tester) async {
      final search = _FakeSearch(recents: [sam], directory: [sarah]);
      final changes = await pumpField(tester, search: search.call);

      await type(tester, 'sa');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);

      expect(changes, [
        [sarah]
      ]);
    });

    testWidgets('the highlighted row is the one painted', (tester) async {
      final search = _FakeSearch(recents: [sam], directory: [sarah]);
      await pumpField(tester, search: search.call);

      Color? rowColor(String id) => tester
          .widget<Container>(find.descendant(
            of: find.byKey(Key('recipient-option-$id')),
            matching: find.byType(Container),
          ))
          .color;

      await type(tester, 'sa');
      expect(rowColor('mail:sam@corp.example'), BondColors.faintGround);
      expect(rowColor('u1'), Colors.transparent);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      expect(rowColor('mail:sam@corp.example'), Colors.transparent);
      expect(rowColor('u1'), BondColors.faintGround);
    });

    testWidgets('a picked person is excluded from later options',
        (tester) async {
      final search = _FakeSearch(recents: [sam], directory: [sarah]);
      await pumpField(tester, value: [sarah], search: search.call);

      await type(tester, 'sa');

      expect(find.byKey(const Key('recipient-option-u1')), findsNothing);
      expect(
        find.byKey(const Key('recipient-option-mail:sam@corp.example')),
        findsOneWidget,
      );
    });

    testWidgets('a directory twin of a typed address is excluded',
        (tester) async {
      final search = _FakeSearch(directory: [sarah]);
      await pumpField(
        tester,
        value: [Person.typed('sarah@corp.example')],
        search: search.call,
      );

      await type(tester, 'sa');

      expect(find.byKey(const Key('recipient-option-u1')), findsNothing);
      expect(find.byKey(const Key('recipients-options')), findsNothing);
    });

    testWidgets('retyping the same query after a pick shows results again',
        (tester) async {
      final search = _FakeSearch(recents: [sam], directory: [sarah]);
      await pumpField(tester, search: search.call);

      await type(tester, 'sa');
      await tester.tap(find.byKey(const Key('recipient-option-u1')));
      await settle(tester);
      await type(tester, 'sa');

      expect(
        find.byKey(const Key('recipient-option-mail:sam@corp.example')),
        findsOneWidget,
      );
    });

    testWidgets('picking, removing and picking the same person again works',
        (tester) async {
      final search = _FakeSearch(directory: [sarah]);
      final changes = await pumpField(tester, search: search.call, max: 1);

      await type(tester, 'sa');
      await tester.tap(find.byKey(const Key('recipient-option-u1')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('recipient-chip-remove-u1')));
      await settle(tester);

      await type(tester, 'sa');
      await tester.tap(find.byKey(const Key('recipient-option-u1')));
      await settle(tester);

      expect(changes, [
        [sarah],
        <Person>[],
        [sarah],
      ]);
    });

    testWidgets('max 1 replaces rather than appends', (tester) async {
      final search = _FakeSearch(directory: [sarah]);
      final changes = await pumpField(
        tester,
        value: [sam],
        search: search.call,
        max: 1,
      );

      await type(tester, 'sa');
      await tester.tap(find.byKey(const Key('recipient-option-u1')));
      await settle(tester);

      expect(changes, [
        [sarah]
      ]);
    });

    testWidgets('a full field hides the text box', (tester) async {
      final search = _FakeSearch();
      await pumpField(
        tester,
        value: [sam, sarah],
        search: search.call,
        max: 2,
      );

      expect(find.byType(TextField), findsNothing);
      expect(find.byType(RecipientChip), findsNWidgets(2));
    });

    testWidgets('an existing chat is offered for Teams and picked through '
        'its own callback', (tester) async {
      final search = _FakeSearch(chats: [crew]);
      final picked = <Conversation>[];
      final changes = await pumpField(
        tester,
        search: search.call,
        channel: RecipientChannel.teams,
        onChatPicked: picked.add,
      );

      await type(tester, 'la');

      expect(find.text('Chats'), findsOneWidget);
      expect(find.byKey(const Key('recipient-chat-chat-1')), findsOneWidget);
      expect(find.text('Launch crew'), findsOneWidget);
      expect(find.text('Sam Ortiz, Rae Lin'), findsOneWidget);

      await tester.tap(find.byKey(const Key('recipient-chat-chat-1')));
      await settle(tester);

      expect(picked, [crew]);
      expect(changes, isEmpty);
    });

    testWidgets('chats are never offered for mail', (tester) async {
      final search = _FakeSearch(recents: [sam], chats: [crew]);
      await pumpField(
        tester,
        search: search.call,
        onChatPicked: (_) {},
      );

      await type(tester, 'sa');

      expect(find.byKey(const Key('recipient-chat-chat-1')), findsNothing);
      expect(find.text('Chats'), findsNothing);
      expect(
        find.byKey(const Key('recipient-option-mail:sam@corp.example')),
        findsOneWidget,
      );
    });
  });

  group('removing', () {
    testWidgets('the remove affordance drops that chip', (tester) async {
      final search = _FakeSearch();
      final changes =
          await pumpField(tester, value: [sam, sarah], search: search.call);

      await tester.tap(find.byKey(const Key('recipient-chip-remove-u1')));
      await settle(tester);

      expect(changes, [
        [sam]
      ]);
    });

    testWidgets('Backspace on an empty field pops the last chip',
        (tester) async {
      final search = _FakeSearch();
      final changes =
          await pumpField(tester, value: [sam, sarah], search: search.call);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await settle(tester);

      expect(changes, [
        [sam]
      ]);
    });

    testWidgets('Backspace with text in the field does not pop',
        (tester) async {
      final search = _FakeSearch();
      final changes =
          await pumpField(tester, value: [sam, sarah], search: search.call);

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await settle(tester);

      expect(changes, isEmpty);
    });

    testWidgets('removing a chip while an address is typed keeps both changes',
        (tester) async {
      final search = _FakeSearch();
      final changes = await pumpField(
        tester,
        value: [sam],
        search: search.call,
        allowTypedAddress: true,
      );

      await tester.enterText(find.byType(TextField), 'bob@x.example');
      await tester.pump();
      // A click on a remove target lands outside the text box: the field
      // blurs on pointer down, which banks the address, and the removal
      // follows on pointer up — possibly before a frame has shown the parent
      // the banked list. `idle` runs the focus change without that frame.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.idle();
      await tester.tap(
        find.byKey(const Key('recipient-chip-remove-mail:sam@corp.example')),
      );
      await settle(tester);

      expect(changes, [
        [sam, Person.typed('bob@x.example')],
        [Person.typed('bob@x.example')],
      ]);
    });
  });

  group('typed addresses', () {
    testWidgets('Enter turns a valid address into a chip when allowed',
        (tester) async {
      final search = _FakeSearch();
      final changes = await pumpField(
        tester,
        search: search.call,
        allowTypedAddress: true,
      );

      await tester.enterText(find.byType(TextField), 'bob@x.example');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);

      expect(changes, [
        [Person.typed('bob@x.example')]
      ]);
      expect(
        find.byKey(const Key('recipient-chip-mail:bob@x.example')),
        findsOneWidget,
      );
    });

    testWidgets('a comma turns a valid address into a chip', (tester) async {
      final search = _FakeSearch();
      final changes = await pumpField(
        tester,
        search: search.call,
        allowTypedAddress: true,
      );

      await tester.enterText(find.byType(TextField), 'bob@x.example,');
      await settle(tester);

      expect(changes, [
        [Person.typed('bob@x.example')]
      ]);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
    });

    testWidgets('a semicolon ends an address the way Outlook does',
        (tester) async {
      final search = _FakeSearch();
      final changes = await pumpField(
        tester,
        search: search.call,
        allowTypedAddress: true,
      );

      await tester.enterText(find.byType(TextField), 'bob@x.example;');
      await settle(tester);

      expect(changes, [
        [Person.typed('bob@x.example')]
      ]);
    });

    testWidgets('blur turns a valid address into a chip', (tester) async {
      final search = _FakeSearch();
      final changes = await pumpField(
        tester,
        search: search.call,
        allowTypedAddress: true,
      );

      await tester.enterText(find.byType(TextField), 'bob@x.example');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(tester);

      expect(changes, [
        [Person.typed('bob@x.example')]
      ]);
    });

    testWidgets('an invalid address never becomes a chip', (tester) async {
      final search = _FakeSearch();
      final changes = await pumpField(
        tester,
        search: search.call,
        allowTypedAddress: true,
      );

      await tester.enterText(find.byType(TextField), 'bob');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);

      await tester.enterText(find.byType(TextField), 'bob,');
      await settle(tester);

      FocusManager.instance.primaryFocus?.unfocus();
      await settle(tester);

      expect(changes, isEmpty);
      // The comma is dropped; what was typed before it survives.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'bob',
      );
    });

    testWidgets('typed addresses are refused when not allowed', (tester) async {
      final search = _FakeSearch();
      final changes = await pumpField(tester, search: search.call);

      await tester.enterText(find.byType(TextField), 'bob@x.example');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);

      expect(changes, isEmpty);
    });

    testWidgets('a matching recent stands in for the typed suggestion',
        (tester) async {
      final search = _FakeSearch(recents: [sam]);
      await pumpField(
        tester,
        search: search.call,
        allowTypedAddress: true,
      );

      await type(tester, 'sam@corp.example');

      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Address'), findsNothing);
      expect(
        find.byKey(const Key('recipient-option-mail:sam@corp.example')),
        findsOneWidget,
      );
    });

    testWidgets('an unknown address is offered under Address', (tester) async {
      final search = _FakeSearch();
      await pumpField(
        tester,
        search: search.call,
        allowTypedAddress: true,
      );

      await type(tester, 'new@x.example');

      expect(find.text('Address'), findsOneWidget);
      expect(
        find.byKey(const Key('recipient-option-mail:new@x.example')),
        findsOneWidget,
      );
    });
  });

  group('overlay', () {
    testWidgets('Escape closes the overlay', (tester) async {
      final search = _FakeSearch(directory: [sarah]);
      await pumpField(tester, search: search.call);

      await type(tester, 'sa');
      expect(find.byKey(const Key('recipients-options')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(find.byKey(const Key('recipients-options')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('refocusing after a pick shows no leftovers, and Enter picks '
        'nobody from them', (tester) async {
      final search = _FakeSearch(recents: [sam], directory: [sarah]);
      final changes = await pumpField(tester, search: search.call);

      await type(tester, 'sa');
      await tester.tap(find.byKey(const Key('recipient-option-u1')));
      await settle(tester);

      // Off to another field and back: the SDK still holds the list the
      // pick was made from and re-shows it on focus.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(find.byKey(const Key('recipients-options')), findsNothing);
      expect(
        find.byKey(const Key('recipient-option-mail:sam@corp.example')),
        findsNothing,
      );

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);

      expect(changes, [
        [sarah]
      ]);

      // Typing again is a fresh list, and picks work as before.
      await type(tester, 'sa');
      expect(
        find.byKey(const Key('recipient-option-mail:sam@corp.example')),
        findsOneWidget,
      );
    });

    testWidgets('a narrow host lays out without overflow', (tester) async {
      final search = _FakeSearch();
      await pumpField(
        tester,
        value: [sam, sarah, Person.typed('bob@x.example')],
        search: search.call,
        width: 220,
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(RecipientChip), findsNWidgets(3));
    });
  });

  group('RecipientChip', () {
    Future<void> pumpChip(WidgetTester tester, Person person,
        {VoidCallback? onRemove}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: RecipientChip(
              person: person,
              onRemove: onRemove ?? () {},
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    BoxDecoration decorationOf(WidgetTester tester) {
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(RecipientChip),
          matching: find.byType(Container),
        ),
      );
      return container.decoration! as BoxDecoration;
    }

    testWidgets('a typed address is neutral, a known person is primary',
        (tester) async {
      await pumpChip(tester, Person.typed('bob@x.example'));
      expect(
        decorationOf(tester).color,
        bondToneColors[BondTone.neutral]!.background,
      );

      await pumpChip(tester, sarah);
      expect(
        decorationOf(tester).color,
        bondToneColors[BondTone.primary]!.background,
      );
    });

    testWidgets('the label falls back to the address', (tester) async {
      await pumpChip(
        tester,
        const Person(id: 'u9', displayName: '', mail: 'nameless@x.example'),
      );

      expect(find.text('nameless@x.example'), findsOneWidget);
    });

    testWidgets('the tooltip carries the address', (tester) async {
      await pumpChip(tester, sarah);

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'sarah@corp.example');
    });

    testWidgets('a Teams-only person says so instead', (tester) async {
      await pumpChip(
        tester,
        const Person(id: 'u7', displayName: 'Rae Lin'),
      );

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'Teams user');
    });

    testWidgets('the remove target calls back', (tester) async {
      var removed = 0;
      await pumpChip(tester, sarah, onRemove: () => removed++);

      await tester.tap(find.byKey(const Key('recipient-chip-remove-u1')));
      await tester.pump();

      expect(removed, 1);
    });
  });
}
