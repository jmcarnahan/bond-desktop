import 'dart:convert';

import 'package:bond_inbox/models/message_models.dart' show Conversation;
import 'package:bond_inbox/models/person.dart';
import 'package:bond_inbox/providers/recipient_search_provider.dart'
    show RecipientResults;
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_mail_backend.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Adding people to a reply the server built.
///
/// Three things this file exists to pin. The PATCH body: Graph replaces a
/// recipients line outright, so the call reads the draft first and sends the
/// merge — and a line nobody added to is not in the body AT ALL, because an
/// empty array would clear it. The capability: a connection that cannot do this
/// says so, and reaching for it there draws a sentence rather than a dead
/// control. And the seam's own forward, which compiles clean either way and
/// recurses until the stack goes if the cast in front of it is removed.

class _InMemoryTokenStore implements TokenStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> deleteAll() async => values.clear();
}

const String _grantedScopes =
    'https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send '
    'https://graph.microsoft.com/User.Read';

/// One request as the stub saw it. Duplicated from `graph_drafts_test.dart`
/// rather than shared, the way every Graph test in this suite keeps its own.
class _SeenRequest {
  _SeenRequest(this.method, this.url, this.body);

  final String method;
  final Uri url;
  final String body;

  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
}

/// An MCP client that answers nothing and records nothing: the MCP backend's
/// recipients behaviour is a refusal that never reaches a tool call.
class _SilentMcp implements BondMcpClient {
  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async =>
      <String, dynamic>{};

  @override
  Future<void> close() async {}
}

/// A backend that can amend recipients and does nothing but say it was asked.
/// The seam's forward is what this exists to catch.
class _RecordingEditor implements MailBackend, DraftRecipientsEditor {
  final List<({String draftId, List<String> to, List<String> cc})> calls = [];

  @override
  Future<void> updateDraftRecipients(
    String draftId, {
    List<String> to = const [],
    List<String> cc = const [],
  }) async {
    calls.add((draftId: draftId, to: [...to], cc: [...cc]));
  }

  @override
  Future<DeltaPage> deltaPage(
    String folder, {
    String? link,
    String? minReceivedIso,
  }) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> getMessageDetail(String id) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> createDraft({
    required List<String> to,
    List<String> cc = const [],
    required String subject,
    required String body,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> updateDraftBody(String draftId, String text) =>
      throw UnimplementedError();

  @override
  Future<SentDraft> sendDraft(String draftId) => throw UnimplementedError();

  @override
  Future<List<String>> markRead(
    List<String> messageIds, {
    bool isRead = true,
  }) =>
      throw UnimplementedError();
}

const Person dana = Person(
  id: 'user-dana',
  displayName: 'Dana Okoye',
  mail: 'dana@example.com',
  jobTitle: 'Contracts',
);

const Person rafi = Person(
  id: 'user-rafi',
  displayName: 'Rafi Ahmed',
  mail: 'rafi@example.net',
);

/// A `RecipientSearch.search` stand-in that answers one directory hit.
Future<RecipientResults> _findsDana(String query) async => (
      recents: const <Person>[],
      directory: const [dana],
      chats: const <Conversation>[],
      directoryOffline: false,
      scopeMissing: false,
    );

Future<RecipientResults> _directoryDown(String query) async => (
      recents: const <Person>[],
      directory: const <Person>[],
      chats: const <Conversation>[],
      directoryOffline: false,
      scopeMissing: true,
    );

/// The draft as `/createReply` leaves it: the person being answered on the To
/// line, nothing on Cc.
const Map<String, Object> _replyAsBuilt = {
  'toRecipients': [
    {
      'emailAddress': {
        'name': 'Sarah Whitfield',
        'address': 'sarah@example.org',
      },
    },
  ],
  'ccRecipients': <Object>[],
};

/// Stands in for the inbox: owns the added list, which is the host's job.
class _Host extends StatefulWidget {
  const _Host({
    required this.search,
    required this.changes,
    this.canEditRecipients = true,
    this.initial = const [],
  });

  final Future<RecipientResults> Function(String) search;
  final List<List<Person>> changes;
  final bool canEditRecipients;
  final List<Person> initial;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<Person> _added = [...widget.initial];
  final List<String> edits = [];

  @override
  Widget build(BuildContext context) {
    return Composer(
      onSend: (_) {},
      capability: SendCapability.send,
      addedRecipients: _added,
      canEditRecipients: widget.canEditRecipients,
      recipientSearch: widget.search,
      onRecipientsChanged: (next) {
        widget.changes.add(next);
        setState(() => _added = next);
      },
    );
  }
}

void main() {
  late _InMemoryTokenStore tokens;
  late List<_SeenRequest> seen;

  setUp(() {
    tokens = _InMemoryTokenStore();
    tokens.values['refresh_token'] = 'rt';
    tokens.values['granted_scopes'] = _grantedScopes;
    seen = [];
  });

  /// A Graph whose mail calls are answered by [respond], recording each one.
  GraphMail mailWith(http.Response Function(_SeenRequest request) respond) {
    final client = MockClient((request) async {
      if (request.url.host == 'login.microsoftonline.com') {
        return http.Response(
          jsonEncode({
            'access_token': 'at-1',
            'refresh_token': 'rt-1',
            'expires_in': 3600,
            'scope': _grantedScopes,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      final entry = _SeenRequest(request.method, request.url, request.body);
      seen.add(entry);
      return respond(entry);
    });
    return GraphMail(
      GraphAuth(httpClient: client, store: tokens),
      httpClient: client,
    );
  }

  http.Response jsonOk(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: const {'content-type': 'application/json'},
      );

  group('the PATCH body', () {
    test('reads the draft, then sends the merged Cc line and nothing else',
        () async {
      final mail = mailWith(
        (request) => request.method == 'GET'
            ? jsonOk(_replyAsBuilt)
            : jsonOk({'id': 'draft-1'}),
      );

      await mail.updateDraftRecipients(
        'draft-1',
        cc: ['dana@example.com', 'rafi@example.net'],
      );

      expect(seen, hasLength(2));
      final read = seen.first;
      expect(read.method, 'GET');
      expect(read.url.path, '/v1.0/me/messages/draft-1');
      expect(read.url.queryParameters[r'$select'], 'toRecipients,ccRecipients');

      final patch = seen.last;
      expect(patch.method, 'PATCH');
      expect(patch.url.toString(), endsWith('/me/messages/draft-1'));
      // The To line is NOT in the body: nobody was added to it, and a PATCH of
      // a recipients line replaces it outright.
      expect(patch.json.keys, ['ccRecipients']);
      expect(patch.json['ccRecipients'], [
        {
          'emailAddress': {'address': 'dana@example.com'}
        },
        {
          'emailAddress': {'address': 'rafi@example.net'}
        },
      ]);
    });

    test('keeps whoever the server already put on a line it is adding to',
        () async {
      final mail = mailWith(
        (request) => request.method == 'GET'
            ? jsonOk(_replyAsBuilt)
            : jsonOk({'id': 'draft-1'}),
      );

      await mail.updateDraftRecipients('draft-1', to: ['dana@example.com']);

      // The person being answered survives, with the server's own spelling of
      // their name, and the addition lands after them.
      expect(seen.last.json['toRecipients'], [
        {
          'emailAddress': {
            'name': 'Sarah Whitfield',
            'address': 'sarah@example.org',
          }
        },
        {
          'emailAddress': {'address': 'dana@example.com'}
        },
      ]);
      expect(seen.last.json.containsKey('ccRecipients'), isFalse);
    });

    test('never sends an empty array for a line nobody added to', () async {
      final mail = mailWith(
        (request) => request.method == 'GET'
            ? jsonOk({
                'toRecipients': [
                  {
                    'emailAddress': {'address': 'sarah@example.org'}
                  },
                ],
              })
            : jsonOk({'id': 'draft-1'}),
      );

      await mail.updateDraftRecipients('draft-1', cc: ['dana@example.com']);

      final body = seen.last.json;
      expect(body.containsKey('toRecipients'), isFalse);
      expect(body['ccRecipients'], hasLength(1));
    });

    test('drops an address the draft already carries', () async {
      final mail = mailWith(
        (request) => request.method == 'GET'
            ? jsonOk(_replyAsBuilt)
            : jsonOk({'id': 'draft-1'}),
      );

      await mail.updateDraftRecipients(
        'draft-1',
        to: ['SARAH@example.org', 'dana@example.com'],
      );

      expect(seen.last.json['toRecipients'], [
        {
          'emailAddress': {
            'name': 'Sarah Whitfield',
            'address': 'sarah@example.org',
          }
        },
        {
          'emailAddress': {'address': 'dana@example.com'}
        },
      ]);
    });

    test('asks nothing at all when there is nobody to add', () async {
      final mail = mailWith((_) => jsonOk({'id': 'draft-1'}));

      await mail.updateDraftRecipients('draft-1');

      expect(seen, isEmpty);
    });

    test('a refused read is reported as a mail failure, before any PATCH',
        () async {
      final mail = mailWith(
        (request) => request.method == 'GET'
            ? jsonOk({'error': {'code': 'ErrorItemNotFound'}}, 404)
            : jsonOk({'id': 'draft-1'}),
      );

      await expectLater(
        mail.updateDraftRecipients('draft-1', cc: ['dana@example.com']),
        throwsA(isA<GraphMailException>()),
      );
      expect(seen.single.method, 'GET');
    });
  });

  group('the capability', () {
    test('a Graph connection can amend a reply', () {
      final MailBackend mail = mailWith((_) => jsonOk({'id': 'draft-1'}));

      expect(mail.canEditDraftRecipients, isTrue);
    });

    test('the MCP server cannot: `manage_draft` takes recipients on create only',
        () {
      final MailBackend mail = McpMailBackend(_SilentMcp());

      expect(mail.canEditDraftRecipients, isFalse);
    });

    test('and a call through the seam there throws rather than dropping people',
        () async {
      final MailBackend mail = McpMailBackend(_SilentMcp());

      await expectLater(
        mail.updateDraftRecipients('draft-1', cc: ['dana@example.com']),
        throwsA(isA<StateError>()),
      );
    });

    test('the seam forwards exactly once to a backend that can', () async {
      // The regression this test is for compiles clean and overflows the stack:
      // without the cast in `MailBackendRecipients.updateDraftRecipients`, the
      // forward resolves back to the extension member and calls itself.
      final editor = _RecordingEditor();
      final MailBackend mail = editor;

      await mail.updateDraftRecipients('draft-1', cc: ['dana@example.com']);

      expect(editor.calls, hasLength(1));
      expect(editor.calls.single.draftId, 'draft-1');
      expect(editor.calls.single.cc, ['dana@example.com']);
      expect(editor.calls.single.to, isEmpty);
    });
  });

  group('the composer', () {
    Future<_HostState> pumpHost(
      WidgetTester tester, {
      Future<RecipientResults> Function(String) search = _findsDana,
      bool canEditRecipients = true,
      List<Person> initial = const [],
      List<List<Person>>? changes,
    }) async {
      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: _Host(
            search: search,
            changes: changes ?? <List<Person>>[],
            canEditRecipients: canEditRecipients,
            initial: initial,
          ),
        ),
      ));
      await tester.pump();
      return tester.state<_HostState>(find.byType(_Host));
    }

    /// The body field is the last one in the tree; the picker's is the first,
    /// because the recipients row sits above the box.
    Finder bodyField() => find.byType(TextField).last;
    Finder pickerField() => find.byType(TextField).first;

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a reply box says nothing about recipients until it is asked',
        (tester) async {
      await pumpHost(tester);

      expect(find.byKey(Composer.addPeopleKey), findsOneWidget);
      expect(find.byKey(Composer.recipientsKey), findsNothing);
      expect(find.byKey(Composer.recipientsRefusedKey), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('an @ in the body opens the picker and says who this goes to',
        (tester) async {
      await pumpHost(tester);

      await tester.enterText(bodyField(), 'Looping in @');
      await tester.pump();

      expect(find.byKey(Composer.recipientsKey), findsOneWidget);
      expect(find.text('Reply to the sender only'), findsOneWidget);
      // The @ is left in the text: swallowing it would read as a keystroke the
      // box refused.
      expect(find.text('Looping in @'), findsOneWidget);
    });

    testWidgets('an address in the body is not a request for a picker',
        (tester) async {
      await pumpHost(tester);

      await tester.enterText(bodyField(), 'write to dana@');
      await tester.pump();

      expect(find.byKey(Composer.recipientsKey), findsNothing);
    });

    testWidgets('picking a person chips them, counts them, and names them in '
        'the sentence', (tester) async {
      final changes = <List<Person>>[];
      await pumpHost(tester, changes: changes);

      await tester.enterText(bodyField(), 'Copying in @');
      await tester.pump();
      await tester.enterText(pickerField(), 'dana');
      await settle(tester);
      await tester.tap(find.byKey(const Key('recipient-option-user-dana')));
      await tester.pump();

      expect(changes.single.single.id, 'user-dana');
      // Cc by default, which is what the line says out loud.
      expect(find.text('Reply to the sender, plus 1 person in Cc'),
          findsOneWidget);
      // And the name went into the sentence somebody was writing.
      expect(find.text('Copying in @Dana Okoye '), findsOneWidget);
    });

    testWidgets('a pick from the button writes nothing into the body',
        (tester) async {
      await pumpHost(tester);

      await tester.enterText(bodyField(), 'Thanks — sending Friday.');
      await tester.pump();
      await tester.tap(find.byKey(Composer.addPeopleKey));
      await tester.pump();
      await tester.enterText(pickerField(), 'dana');
      await settle(tester);
      await tester.tap(find.byKey(const Key('recipient-option-user-dana')));
      await tester.pump();

      expect(find.text('Thanks — sending Friday.'), findsOneWidget);
      expect(find.textContaining('Dana Okoye '), findsNothing);
    });

    testWidgets('people already added put the row on screen unasked',
        (tester) async {
      await pumpHost(tester, initial: const [dana, rafi]);

      expect(find.byKey(Composer.recipientsKey), findsOneWidget);
      expect(find.byKey(Composer.addPeopleKey), findsNothing);
      expect(
        find.text('Reply to the sender, plus 2 people in Cc'),
        findsOneWidget,
      );
    });

    testWidgets('a chip can be taken off again', (tester) async {
      final changes = <List<Person>>[];
      await pumpHost(tester, initial: const [dana], changes: changes);

      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pump();

      expect(changes.single, isEmpty);
    });

    testWidgets('a directory that cannot be searched says so under the field',
        (tester) async {
      await pumpHost(tester, search: _directoryDown);

      await tester.tap(find.byKey(Composer.addPeopleKey));
      await tester.pump();
      await tester.enterText(pickerField(), 'dana');
      await settle(tester);

      expect(find.byKey(const Key('recipients-footer')), findsOneWidget);
      expect(
        find.text('Directory search is not enabled for this account.'),
        findsOneWidget,
      );
    });

    testWidgets('a connection that cannot apply people draws no control at all',
        (tester) async {
      await pumpHost(tester, canEditRecipients: false);

      expect(find.byKey(Composer.addPeopleKey), findsNothing);
      expect(find.byKey(Composer.recipientsKey), findsNothing);
      expect(find.byKey(Composer.recipientsRefusedKey), findsNothing);
    });

    testWidgets('and answers the reach for it with a sentence, not a dead field',
        (tester) async {
      await pumpHost(tester, canEditRecipients: false);

      await tester.enterText(bodyField(), 'Looping in @');
      await tester.pump();

      expect(find.byKey(Composer.recipientsRefusedKey), findsOneWidget);
      expect(
        find.textContaining('cannot add people to a reply'),
        findsOneWidget,
      );
      // No picker appeared, and no chip: nobody was taken on and then dropped.
      expect(find.byKey(Composer.recipientsKey), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
    });
  });
}
