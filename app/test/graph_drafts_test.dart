import 'dart:convert';

import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The three Graph calls behind the Send button: create the reply shell, fill
/// in its body, send it.
///
/// The stubs are duplicated from the other Graph tests rather than shared, so
/// neither file can break the other by editing it.
class InMemoryTokenStore implements TokenStore {
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

/// One request as the stub saw it.
class SeenRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;

  SeenRequest(this.method, this.url, this.headers, this.body);

  Map<String, dynamic> get json =>
      jsonDecode(body) as Map<String, dynamic>;
}

void main() {
  late InMemoryTokenStore tokens;
  late List<SeenRequest> seen;

  setUp(() {
    tokens = InMemoryTokenStore();
    tokens.values['refresh_token'] = 'rt';
    tokens.values['granted_scopes'] = _grantedScopes;
    seen = [];
  });

  /// A Graph whose mail calls are answered by [respond] and whose token POSTs
  /// always succeed.
  GraphMail mailWith(http.Response Function(SeenRequest request) respond) {
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
      final entry = SeenRequest(
        request.method,
        request.url,
        request.headers,
        request.body,
      );
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

  group('createReplyDraft', () {
    test('POSTs to /createReply with the local time zone preferred', () async {
      final mail = mailWith(
        (_) => jsonOk({'id': 'draft-1', 'webLink': 'https://outlook/draft-1'}),
      );

      final draft = await mail.createReplyDraft('msg-1');

      expect(draft['id'], 'draft-1');
      expect(draft['webLink'], 'https://outlook/draft-1');
      final request = seen.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://graph.microsoft.com/v1.0/me/messages/msg-1/createReply',
      );
      expect(request.headers['prefer'], startsWith('outlook.timezone='));
      expect(request.headers['authorization'], 'Bearer at-1');
    });

    test('encodes a message id that is not URL-safe', () async {
      // Graph ids are base64url-ish but not guaranteed to be; an unencoded one
      // would silently address a different message.
      final mail = mailWith((_) => jsonOk({'id': 'd', 'webLink': 'w'}));

      await mail.createReplyDraft('a/b+c=');

      expect(seen.single.url.path, endsWith('/messages/a%2Fb%2Bc%3D/createReply'));
    });

    test('a 400 on the Prefer header is retried once without it', () async {
      // A zone name Graph will not parse must not cost the LO the draft.
      final mail = mailWith((request) {
        if (request.headers.containsKey('prefer')) {
          return jsonOk({'error': 'bad timezone'}, 400);
        }
        return jsonOk({'id': 'draft-2', 'webLink': 'https://outlook/2'});
      });

      final draft = await mail.createReplyDraft('msg-1');

      expect(draft['id'], 'draft-2');
      expect(seen, hasLength(2));
      expect(seen.first.headers.containsKey('prefer'), isTrue);
      expect(seen.last.headers.containsKey('prefer'), isFalse);
    });

    test('a 400 that is not about the header still fails, once retried',
        () async {
      final mail = mailWith((_) => jsonOk({'error': 'no such message'}, 400));

      await expectLater(
        mail.createReplyDraft('msg-1'),
        throwsA(isA<GraphMailException>()),
      );
      expect(seen, hasLength(2),
          reason: 'the retry-without-header is unconditional on a 400');
    });

    test('accepts a 201 as readily as a 200', () async {
      final mail = mailWith((_) => jsonOk({'id': 'draft-3'}, 201));

      expect((await mail.createReplyDraft('m'))['id'], 'draft-3');
    });

    test('a 401 is retried once, like every other call', () async {
      var calls = 0;
      final mail = mailWith((_) {
        calls++;
        return calls == 1
            ? jsonOk({'error': 'expired'}, 401)
            : jsonOk({'id': 'draft-4'});
      });

      expect((await mail.createReplyDraft('m'))['id'], 'draft-4');
      expect(seen, hasLength(2));
    });
  });

  group('updateDraftBody', () {
    test('PATCHes a plain-text body onto the draft', () async {
      final mail = mailWith((_) => jsonOk({'id': 'draft-1'}));

      await mail.updateDraftBody('draft-1', 'Hi Sarah — Friday works.');

      final request = seen.single;
      expect(request.method, 'PATCH');
      expect(
        request.url.toString(),
        'https://graph.microsoft.com/v1.0/me/messages/draft-1',
      );
      expect(request.json, {
        'body': {
          'contentType': 'text',
          'content': 'Hi Sarah — Friday works.',
        },
      });
      expect(request.headers['content-type'], contains('application/json'));
    });

    test('a rejected PATCH surfaces as a GraphMailException', () async {
      final mail = mailWith((_) => jsonOk({'error': 'not a draft'}, 403));

      await expectLater(
        mail.updateDraftBody('draft-1', 'text'),
        throwsA(isA<GraphMailException>()),
      );
    });
  });

  group('sendDraft', () {
    test('POSTs to /send and accepts the 202', () async {
      final mail = mailWith((_) => http.Response('', 202));

      await mail.sendDraft('draft-1');

      final request = seen.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://graph.microsoft.com/v1.0/me/messages/draft-1/send',
      );
      expect(request.body, isEmpty, reason: '/send takes no body');
    });

    test('anything but a 202 is a failure the caller must see', () async {
      final mail = mailWith((_) => jsonOk({'error': 'quota'}, 429));

      await expectLater(
        mail.sendDraft('draft-1'),
        throwsA(isA<GraphMailException>()),
      );
    });

    test('an auth failure passes through UNWRAPPED', () async {
      // The UI routes NotSignedIn and ReconsentRequired to sign-in; wrapping
      // them in a GraphMailException here would erase that.
      tokens.values.remove('refresh_token');
      final mail = mailWith((_) => http.Response('', 202));

      await expectLater(mail.sendDraft('draft-1'), throwsA(isA<NotSignedIn>()));
      expect(seen, isEmpty);
    });
  });
}
